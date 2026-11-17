defmodule Samen.Ingest.Event do
  @moduledoc """
  The durable `ing_event` envelope for signed provider ingestion.

  Like `Samen.Webhook.Event`, this is kernel infrastructure backed by a plain
  `Ecto.Schema` (not a per-tenant Ash blueprint) because ingestion happens before
  any org is attributed. Unlike the webhook store, this table carries the
  explicit provider-ingestion contract fields:

    * `provider` + `idempotency_key` — UNIQUE. A retry of the same delivery is a
      safe no-op; the DB is the arbiter under concurrency.
    * `provider` + `event_id` — UNIQUE. A replay of the same provider event (even
      under a fresh idempotency key) is also a safe no-op.
    * `schema_version` — the signed envelope version the sender used.
    * `payload_digest` — SHA-256 of the ALREADY-REDACTED payload. The same
      idempotency key with a different digest is a conflict (409), never a silent
      overwrite. The same event id with a different digest is likewise refused.
    * `payload` — the adapter's redacted map only. Raw PII must never reach this
      row.
    * `attempt_count` / `max_attempts` — the BOUNDED retry budget. The worker
      stops at `max_attempts` and dead-letters the envelope.
    * `last_error` — a bounded machine token, never a payload echo.

  ## Status machine

  `received -> processing -> processed` on success, or `received -> processing ->
  dead` on a permanent failure / exhausted retry budget. `reset_for_replay/2`
  grants an operator replay a fresh bounded budget.

  ## Write path

  `insert_received/2` returns:

    * `{:ok, :inserted, row}` — first delivery
    * `{:ok, :duplicate, existing}` — same idempotency key/digest or event id/digest
    * `{:error, :idempotency_conflict, existing}` — key reused with different content
    * `{:error, :event_conflict, existing}` — event id reused with different content
    * `{:error, changeset}` — malformed envelope
  """

  use Ecto.Schema

  import Ecto.Query, only: [from: 2]

  @type t :: %__MODULE__{}

  @statuses ~w(received processing processed dead)
  @unique_idempotency_index "ing_event_provider_idempotency_key_index"
  @unique_event_index "ing_event_provider_event_id_index"

  @primary_key {:id, :binary_id, autogenerate: true, source: :ing_id}
  schema "ing_event" do
    field(:provider, :string, source: :ing_provider)
    field(:idempotency_key, :string, source: :ing_idempotency_key)
    field(:schema_version, :integer, source: :ing_schema_version)
    field(:event_id, :string, source: :ing_event_id)
    field(:event_type, :string, source: :ing_event_type)
    field(:occurred_at, :utc_datetime_usec, source: :ing_occurred_at)
    field(:payload, :map, source: :ing_payload, default: %{})
    field(:payload_digest, :string, source: :ing_payload_digest)
    field(:status, :string, source: :ing_status, default: "received")
    field(:attempt_count, :integer, source: :ing_attempt_count, default: 0)
    field(:max_attempts, :integer, source: :ing_max_attempts, default: 8)
    field(:last_error, :string, source: :ing_last_error)
    field(:processed_at, :utc_datetime_usec, source: :ing_processed_at)

    field(:inserted_at, :utc_datetime_usec,
      source: :ing_inserted_at,
      autogenerate: {__MODULE__, :now, []}
    )
  end

  @doc false
  def now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  @doc "The bounded envelope statuses."
  def statuses, do: @statuses

  # ---------------------------------------------------------------------------
  # Write path
  # ---------------------------------------------------------------------------

  @doc """
  Insert a received envelope. `attrs` MUST carry an already-redacted `:payload`
  and the `:payload_digest` computed from it; this function never redacts.

  Race-safe: the two unique indexes are the arbitration points. If the insert
  loses a race, the winner is re-read and compared by digest.
  """
  @spec insert_received(module(), map() | keyword()) ::
          {:ok, :inserted | :duplicate, t()}
          | {:error, :idempotency_conflict | :event_conflict, t()}
          | {:error, Ecto.Changeset.t()}
  def insert_received(repo, attrs) when is_atom(repo) do
    attrs = normalize(attrs)

    changeset =
      %__MODULE__{}
      |> Ecto.Changeset.cast(
        attrs,
        [
          :provider,
          :idempotency_key,
          :schema_version,
          :event_id,
          :event_type,
          :occurred_at,
          :payload,
          :payload_digest,
          :max_attempts
        ]
      )
      |> Ecto.Changeset.put_change(:status, "received")
      |> Ecto.Changeset.put_change(:attempt_count, 0)
      |> Ecto.Changeset.validate_required([
        :provider,
        :idempotency_key,
        :schema_version,
        :event_id,
        :event_type,
        :occurred_at,
        :payload_digest
      ])
      |> Ecto.Changeset.validate_number(:schema_version, greater_than: 0)
      |> Ecto.Changeset.validate_number(:max_attempts,
        greater_than: 0,
        less_than_or_equal_to: Samen.Ingest.hard_max_attempts()
      )
      |> Ecto.Changeset.validate_length(:idempotency_key, max: 255)
      |> Ecto.Changeset.validate_length(:event_id, max: 200)
      |> Ecto.Changeset.validate_length(:event_type, max: 120)
      |> Ecto.Changeset.unique_constraint([:provider, :idempotency_key],
        name: @unique_idempotency_index
      )
      |> Ecto.Changeset.unique_constraint([:provider, :event_id], name: @unique_event_index)

    case repo.insert(changeset) do
      {:ok, row} ->
        {:ok, :inserted, row}

      {:error, %Ecto.Changeset{errors: errors} = changeset} ->
        if unique_violation?(errors) do
          resolve_conflict(repo, attrs, changeset)
        else
          {:error, changeset}
        end
    end
  end

  defp resolve_conflict(repo, attrs, changeset) do
    by_key = get_by_idempotency_key(repo, attrs.provider, attrs.idempotency_key)
    by_event = get_by_event(repo, attrs.provider, attrs.event_id)

    cond do
      by_key && by_key.payload_digest == attrs.payload_digest ->
        {:ok, :duplicate, by_key}

      by_key ->
        {:error, :idempotency_conflict, by_key}

      by_event && by_event.payload_digest == attrs.payload_digest ->
        {:ok, :duplicate, by_event}

      by_event ->
        {:error, :event_conflict, by_event}

      true ->
        {:error, changeset}
    end
  end

  @doc "Transition an envelope to `:processing` and increment its attempt count."
  @spec mark_processing(module(), t()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def mark_processing(repo, %__MODULE__{} = row) do
    row
    |> Ecto.Changeset.change(
      status: "processing",
      attempt_count: (row.attempt_count || 0) + 1
    )
    |> repo.update()
  end

  @doc "Transition an envelope to its terminal success state."
  @spec mark_processed(module(), t()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def mark_processed(repo, %__MODULE__{} = row) do
    row
    |> Ecto.Changeset.change(status: "processed", processed_at: now(), last_error: nil)
    |> repo.update()
  end

  @doc """
  Transition an envelope to the dead-letter terminal. `error` is reduced to a
  bounded machine token — never an arbitrary payload echo.
  """
  @spec mark_dead(module(), t(), term()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def mark_dead(repo, %__MODULE__{} = row, error) do
    row
    |> Ecto.Changeset.change(
      status: "dead",
      processed_at: now(),
      last_error: summarize_error(error)
    )
    |> repo.update()
  end

  @doc """
  Reset an envelope for an operator replay: `received`, a FRESH bounded attempt
  budget and no terminal timestamp. Safe because provider handlers must be
  idempotent (the contract's replay store is what makes retries safe).
  """
  @spec reset_for_replay(module(), t()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def reset_for_replay(repo, %__MODULE__{} = row) do
    row
    |> Ecto.Changeset.change(
      status: "received",
      attempt_count: 0,
      last_error: nil,
      processed_at: nil
    )
    |> repo.update()
  end

  # ---------------------------------------------------------------------------
  # Read path
  # ---------------------------------------------------------------------------

  @doc "Fetch one envelope by id (nil if absent)."
  @spec get(module(), String.t()) :: t() | nil
  def get(repo, id) when is_atom(repo), do: repo.get(__MODULE__, id)

  @doc "Fetch one envelope by its `{provider, idempotency_key}` natural key."
  @spec get_by_idempotency_key(module(), String.t(), String.t()) :: t() | nil
  def get_by_idempotency_key(repo, provider, key) when is_atom(repo) do
    repo.one(
      from(e in __MODULE__,
        where: e.provider == ^provider and e.idempotency_key == ^key,
        limit: 1
      )
    )
  end

  @doc "Fetch one envelope by its `{provider, event_id}` natural key."
  @spec get_by_event(module(), String.t(), String.t()) :: t() | nil
  def get_by_event(repo, provider, event_id) when is_atom(repo) do
    repo.one(
      from(e in __MODULE__,
        where: e.provider == ^provider and e.event_id == ^event_id,
        limit: 1
      )
    )
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp normalize(attrs) do
    attrs
    |> Map.new(fn {key, value} -> {to_atom(key), value} end)
    |> Map.put_new(:status, "received")
    |> Map.put_new(:attempt_count, 0)
    |> Map.put_new(:payload, %{})
  end

  defp to_atom(key) when is_atom(key), do: key

  defp to_atom(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    _ -> key
  end

  defp unique_violation?(errors) do
    Enum.any?(errors, fn
      {_field, {_message, opts}} -> Keyword.get(opts, :constraint) == :unique
      _ -> false
    end)
  end

  # Bounded machine tokens only. An error string is accepted when it is a plain
  # token; anything else (a payload echo, an inspect of a map, a handler message
  # with PII) collapses to `"error"`.
  @safe_error ~r/^[A-Za-z0-9_.:-]{1,200}$/

  defp summarize_error(error) when is_atom(error), do: summarize_error(Atom.to_string(error))

  defp summarize_error(error) when is_binary(error) do
    if Regex.match?(@safe_error, error), do: error, else: "error"
  end

  defp summarize_error(%{__struct__: module}), do: summarize_error(inspect(module))
  defp summarize_error(_), do: "error"
end
