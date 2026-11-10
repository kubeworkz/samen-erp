defmodule Samen.Scopes.Finance.ArCollections do
  @moduledoc """
  Manual AR collections over the ledger's aging read.

  A `CollectionCase` is a workflow record, never a second ledger: opening a
  case snapshots the customer/currency outstanding from `ArAging`, and every
  action only appends to its timeline. Cash and credits keep moving through
  receipts, allocations and credit notes — this module posts nothing.

  ## Stages and statuses

  Stages are advisory dunning steps (`:reminder`, `:notice`, `:final_notice`,
  `:collections`). Status is the case lifecycle (`:open`, `:paused`,
  `:resolved`). A resolved case is terminal; a paused case can be resumed.

  `Samen.Scopes.Finance.CollectionDunning` advances due cases on the canonical
  Oban cron. It uses the same `record_action/1` transition and timeline path as
  the desk, so a scheduled step and a manual step cannot diverge.
  """

  require Ash.Query

  alias Samen.Scopes.Finance.ArAging

  @kinds [
    :note,
    :reminder,
    :notice,
    :final_notice,
    :collections,
    :promise,
    :pause,
    :resume,
    :resolve
  ]

  @stage_kinds [:reminder, :notice, :final_notice, :collections]
  @max_actions 200

  @doc "The bounded set of collection action kinds the kernel accepts."
  @spec kinds() :: [atom()]
  def kinds, do: @kinds

  @doc """
  The next step in the dunning ladder. `:collections` is the final rung and
  repeats its follow-up cadence until a person resolves the case.
  """
  @spec next_stage(atom()) :: atom()
  def next_stage(:reminder), do: :notice
  def next_stage(:notice), do: :final_notice
  def next_stage(:final_notice), do: :collections
  def next_stage(:collections), do: :collections

  @doc "The default next contact date after `stage`, counted from `today`."
  @spec next_action_on(atom(), Date.t()) :: Date.t()
  def next_action_on(stage, %Date{} = today), do: Date.add(today, stage_days(stage))

  @doc """
  Open a case for one customer/currency with positive ledger AR.

  Required options: `:collection_case`, `:invoice`, `:receipt`, `:org_id`,
  `:scope`, `:customer_id` and `:as_of`. Optional: `:receipt_allocation`,
  `:credit_note`, `:currency`, `:opened_on`, `:opened_at`, `:next_action_on`
  and `:notes`. `:opened_at` is the recorded timestamp on the opening event;
  it defaults to now.

  Refuses `:active_case_exists` when a non-resolved case already covers the
  same customer/currency, and `:nothing_outstanding` when the ledger read has
  no positive outstanding balance.
  """
  @spec open_case(keyword()) :: {:ok, struct()} | {:error, term()}
  def open_case(opts) do
    resource = Keyword.fetch!(opts, :collection_case)

    with {:ok, statement} <- load_statement(opts),
         {:ok, currency, totals} <- pick_currency(statement, Keyword.get(opts, :currency)),
         :ok <- ensure_outstanding(totals),
         :ok <- ensure_no_active_case(resource, opts, currency) do
      org_id = Keyword.fetch!(opts, :org_id)
      scope = Keyword.fetch!(opts, :scope)
      customer_id = Keyword.fetch!(opts, :customer_id)
      as_of = Keyword.fetch!(opts, :as_of)
      now = Keyword.get(opts, :opened_at) || DateTime.utc_now()

      attrs = %{
        org_id: org_id,
        customer_id: customer_id,
        opened_on: Keyword.get(opts, :opened_on, as_of),
        currency: currency,
        next_action_on: Keyword.get(opts, :next_action_on, Date.add(as_of, 7)),
        outstanding_cents: totals.outstanding_cents,
        invoice_count: invoice_count(statement, currency),
        notes: normalize_note(Keyword.get(opts, :notes)),
        actions: %{
          "events" => [
            compact(%{
              "kind" => "opened",
              "at" => DateTime.to_iso8601(now),
              "note" => normalize_note(Keyword.get(opts, :notes)),
              "actor_id" => actor_id(scope)
            })
          ]
        }
      }

      resource
      |> Ash.Changeset.for_create(:open, attrs, scope: scope)
      |> Ash.create()
    end
  end

  @doc """
  Append one action to a case's timeline and apply its state transition.

  Required options: `:collection_case`, `:case_id`, `:kind` and `:org_id`.
  Required for tenant callers: `:scope`. The scheduler passes `system?: true`
  and no scope; that path bypasses policy but stays pinned to the case's org id.
  Optional: `:note`, `:next_action_on`, `:promise_to_pay_on`, `:promised_cents`,
  `:idempotency_key` and `:at` (the recorded event timestamp; defaults to now).

  A supplied `:idempotency_key` is stored on the appended event. Repeating a
  call with the same key returns the existing case without appending, so an
  Oban retry cannot duplicate a dunning step.

  Returns `{:ok, case}` with the updated row, or a fail-honest error. No ledger
  entry is ever created here.
  """
  @spec record_action(keyword()) :: {:ok, struct()} | {:error, term()}
  def record_action(opts) do
    resource = Keyword.fetch!(opts, :collection_case)
    org_id = Keyword.fetch!(opts, :org_id)
    case_id = Keyword.fetch!(opts, :case_id)
    scope = Keyword.get(opts, :scope)
    system? = Keyword.get(opts, :system?, false)

    with {:ok, kind} <- normalize_kind(Keyword.get(opts, :kind)),
         {:ok, note} <- validate_note(Keyword.get(opts, :note)),
         {:ok, idempotency_key} <-
           normalize_idempotency_key(Keyword.get(opts, :idempotency_key)),
         {:ok, collection_case} <- get_case(resource, case_id, org_id, scope, system?) do
      if recorded?(collection_case, idempotency_key) do
        {:ok, collection_case}
      else
        do_record_action(collection_case, kind, note, idempotency_key, opts, scope, system?)
      end
    end
  end

  defp do_record_action(collection_case, kind, note, idempotency_key, opts, scope, system?) do
    with :ok <- ensure_mutable(collection_case, kind),
         {:ok, event, attrs} <- action(collection_case, kind, note, opts) do
      events = timeline(collection_case)

      if length(events) >= @max_actions do
        {:error, :timeline_full}
      else
        event =
          if idempotency_key,
            do: Map.put(event, "idempotency_key", idempotency_key),
            else: event

        attrs =
          attrs
          |> Map.put(:notes, note || collection_case.notes)
          |> Map.put(:event, event)

        changeset =
          Ash.Changeset.for_update(collection_case, :record, attrs,
            scope: scope,
            authorize?: not system?
          )

        if system?, do: Ash.update(changeset, authorize?: false), else: Ash.update(changeset)
      end
    end
  end

  defp load_statement(opts) do
    ArAging.statement_for_customer(
      invoice: Keyword.fetch!(opts, :invoice),
      receipt: Keyword.fetch!(opts, :receipt),
      receipt_allocation: Keyword.get(opts, :receipt_allocation),
      credit_note: Keyword.get(opts, :credit_note),
      org_id: Keyword.fetch!(opts, :org_id),
      scope: Keyword.fetch!(opts, :scope),
      customer_id: Keyword.fetch!(opts, :customer_id),
      as_of: Keyword.fetch!(opts, :as_of)
    )
  end

  defp pick_currency(%{by_currency: by_currency}, nil) when map_size(by_currency) == 0 do
    {:error, :nothing_outstanding}
  end

  defp pick_currency(%{by_currency: by_currency} = statement, nil) do
    case Map.keys(by_currency) do
      [currency] -> {:ok, currency, statement.by_currency[currency]}
      _many -> {:error, :currency_required}
    end
  end

  defp pick_currency(%{by_currency: by_currency}, requested) do
    currency = requested |> to_string() |> String.trim() |> String.upcase()

    case Map.fetch(by_currency, currency) do
      {:ok, totals} -> {:ok, currency, totals}
      :error -> {:error, :nothing_outstanding}
    end
  end

  defp ensure_outstanding(%{outstanding_cents: cents}) when cents > 0, do: :ok
  defp ensure_outstanding(_totals), do: {:error, :nothing_outstanding}

  defp ensure_no_active_case(resource, opts, currency) do
    org_id = Keyword.fetch!(opts, :org_id)
    scope = Keyword.fetch!(opts, :scope)
    customer_id = Keyword.fetch!(opts, :customer_id)

    resource
    |> Ash.Query.filter(
      org_id == ^org_id and customer_id == ^customer_id and currency == ^currency and
        status != :resolved
    )
    |> Ash.read(scope: scope)
    |> case do
      {:ok, []} -> :ok
      {:ok, [_ | _]} -> {:error, :active_case_exists}
      {:error, reason} -> {:error, reason}
    end
  end

  defp invoice_count(statement, currency) do
    Enum.count(statement.invoices, fn invoice ->
      invoice.currency == currency and invoice.outstanding_cents > 0
    end)
  end

  defp normalize_kind(kind) when kind in @kinds, do: {:ok, kind}

  defp normalize_kind(kind) when is_binary(kind) do
    Enum.find_value(@kinds, {:error, :unknown_action}, fn candidate ->
      if Atom.to_string(candidate) == kind, do: {:ok, candidate}
    end)
  end

  defp normalize_kind(_kind), do: {:error, :unknown_action}

  defp validate_note(nil), do: {:ok, nil}

  defp validate_note(note) when is_binary(note) do
    note = String.trim(note)

    cond do
      note == "" -> {:ok, nil}
      String.length(note) > 2_000 -> {:error, :note_too_long}
      true -> {:ok, note}
    end
  end

  defp validate_note(_note), do: {:error, :invalid_note}

  defp normalize_idempotency_key(nil), do: {:ok, nil}

  defp normalize_idempotency_key(key) when is_binary(key) do
    case String.trim(key) do
      "" -> {:ok, nil}
      key when byte_size(key) <= 200 -> {:ok, key}
      _too_long -> {:error, :idempotency_key_too_long}
    end
  end

  defp normalize_idempotency_key(_key), do: {:error, :invalid_idempotency_key}

  defp get_case(resource, id, org_id, scope, system?) do
    query =
      resource
      |> Ash.Query.filter(id == ^id and org_id == ^org_id)
      |> Ash.Query.ensure_selected([:org_id])

    result =
      if system?,
        do: Ash.read_one(query, authorize?: false),
        else: Ash.read_one(query, scope: scope)

    case result do
      {:ok, %{} = collection_case} -> {:ok, collection_case}
      {:ok, nil} -> {:error, :case_not_found}
      {:error, _reason} -> {:error, :case_not_found}
    end
  end

  defp recorded?(_collection_case, nil), do: false

  defp recorded?(collection_case, key) do
    Enum.any?(timeline(collection_case), fn
      event when is_map(event) ->
        Map.get(event, "idempotency_key") == key or Map.get(event, :idempotency_key) == key

      _event ->
        false
    end)
  end

  defp ensure_mutable(%{status: :resolved}, :note), do: :ok
  defp ensure_mutable(%{status: :resolved}, :resolve), do: :ok
  defp ensure_mutable(%{status: :resolved}, _kind), do: {:error, :case_resolved}
  defp ensure_mutable(_collection_case, _kind), do: :ok

  defp action(collection_case, kind, note, opts) when kind in @stage_kinds do
    now = event_time(opts)

    next_action_on =
      Keyword.get(opts, :next_action_on, next_action_on(kind, Date.utc_today()))

    event =
      compact(%{
        "kind" => Atom.to_string(kind),
        "at" => DateTime.to_iso8601(now),
        "note" => note,
        "actor_id" => actor_id(opts[:scope]),
        "next_action_on" => date_text(next_action_on)
      })

    {:ok, event,
     %{
       stage: kind,
       status: :open,
       last_contacted_at: now,
       next_action_on: next_action_on,
       promised_cents: collection_case.promised_cents,
       promise_to_pay_on: collection_case.promise_to_pay_on
     }}
  end

  defp action(collection_case, :promise, note, opts) do
    promise_on = Keyword.get(opts, :promise_to_pay_on)
    promised_cents = Keyword.get(opts, :promised_cents)

    cond do
      is_nil(promise_on) and is_nil(promised_cents) ->
        {:error, :promise_required}

      promised_cents != nil and (not is_integer(promised_cents) or promised_cents <= 0) ->
        {:error, :invalid_promised_cents}

      true ->
        now = event_time(opts)

        event =
          compact(%{
            "kind" => "promise",
            "at" => DateTime.to_iso8601(now),
            "note" => note,
            "actor_id" => actor_id(opts[:scope]),
            "promise_to_pay_on" => date_text(promise_on),
            "promised_cents" => promised_cents
          })

        {:ok, event,
         %{
           status: :open,
           next_action_on: promise_on || collection_case.next_action_on,
           promise_to_pay_on: promise_on || collection_case.promise_to_pay_on,
           promised_cents: promised_cents || collection_case.promised_cents
         }}
    end
  end

  defp action(_collection_case, :pause, note, opts) do
    now = event_time(opts)

    event =
      compact(%{
        "kind" => "pause",
        "at" => DateTime.to_iso8601(now),
        "note" => note,
        "actor_id" => actor_id(opts[:scope])
      })

    {:ok, event, %{status: :paused, next_action_on: nil}}
  end

  defp action(_collection_case, :resume, note, opts) do
    now = event_time(opts)
    next_action_on = Keyword.get(opts, :next_action_on, Date.add(Date.utc_today(), 7))

    event =
      compact(%{
        "kind" => "resume",
        "at" => DateTime.to_iso8601(now),
        "note" => note,
        "actor_id" => actor_id(opts[:scope]),
        "next_action_on" => date_text(next_action_on)
      })

    {:ok, event, %{status: :open, next_action_on: next_action_on}}
  end

  defp action(_collection_case, :resolve, note, opts) do
    now = event_time(opts)

    event =
      compact(%{
        "kind" => "resolve",
        "at" => DateTime.to_iso8601(now),
        "note" => note,
        "actor_id" => actor_id(opts[:scope])
      })

    {:ok, event, %{status: :resolved, next_action_on: nil}}
  end

  defp action(collection_case, :note, note, opts) do
    if is_nil(note) do
      {:error, :note_required}
    else
      now = event_time(opts)

      event =
        compact(%{
          "kind" => "note",
          "at" => DateTime.to_iso8601(now),
          "note" => note,
          "actor_id" => actor_id(opts[:scope])
        })

      {:ok, event, %{next_action_on: collection_case.next_action_on}}
    end
  end

  defp timeline(%{actions: actions}) when is_map(actions) do
    case Map.get(actions, "events") || Map.get(actions, :events) do
      events when is_list(events) -> events
      _other -> []
    end
  end

  defp timeline(_collection_case), do: []

  defp stage_days(:reminder), do: 7
  defp stage_days(:notice), do: 14
  defp stage_days(:final_notice), do: 21
  defp stage_days(:collections), do: 30

  defp actor_id(%{actor: %{id: id}}) when is_binary(id), do: id
  defp actor_id(_scope), do: nil

  defp compact(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)

  defp date_text(%Date{} = date), do: Date.to_iso8601(date)
  defp date_text(_date), do: nil

  defp event_time(opts), do: Keyword.get(opts, :at) || DateTime.utc_now()

  defp normalize_note(note) when is_binary(note) do
    case String.trim(note) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_note(_note), do: nil
end
