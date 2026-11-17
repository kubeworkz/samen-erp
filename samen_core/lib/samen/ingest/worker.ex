defmodule Samen.Ingest.Worker do
  @moduledoc """
  The provider-ingestion processing worker (bounded retries).

  The ingress fast-acks a provider after persisting an envelope, then enqueues
  THIS worker with token-only args (the envelope row id, never the payload). The
  worker runs on the existing `:webhooks_in` queue — no new queue topology for a
  host to configure.

  ## Bounded retries

  The attempt budget is stored ON THE ENVELOPE (`max_attempts`, clamped by
  `Samen.Ingest.clamp_attempts/1`), not left to an unbounded retry loop:

    * `mark_processing/2` increments `attempt_count` before the handler runs;
    * a transient `{:error, reason}` retries while `attempt_count < max_attempts`;
    * the attempt that reaches the budget marks the envelope `:dead` and returns
      `{:discard, reason}` so Oban also stops retrying;
    * a permanent `{:discard, reason}` dead-letters immediately.

  An operator replay (`Samen.Ingest.Event.reset_for_replay/2`) resets the budget,
  so a fixed handler can be re-run without resurrecting an exhausted job.

  ## Adapter resolution

  The adapter and its config come from the SAME `Samen.Ingest` registry the
  ingress used. A provider removed from config after ingestion dead-letters the
  envelope loudly (`:provider_not_configured`) instead of silently dropping it.
  """

  use Oban.Worker, queue: :webhooks_in

  alias Samen.Ingest
  alias Samen.Ingest.{Contract, Event}

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    repo = resolve_repo(args)
    event_id = Map.get(args, "event_id")

    with true <- is_atom(repo) and not is_nil(repo),
         %Event{} = event <- Event.get(repo, event_id) do
      process(repo, event)
    else
      _ -> :ok
    end
  end

  @doc """
  Enqueue an envelope for processing. Token-only args: the row id plus the repo
  module (so a multi-repo host/test can resolve its own repo). The job's Oban
  `max_attempts` mirrors the stored budget.
  """
  @spec enqueue(Event.t(), keyword()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(%Event{} = event, opts \\ []) do
    args = %{"event_id" => event.id}

    args =
      case Keyword.get(opts, :repo) do
        nil -> args
        repo -> Map.put(args, "repo", to_string(repo))
      end

    budget = Ingest.clamp_attempts(event.max_attempts)

    args
    |> new(max_attempts: budget)
    |> Oban.insert()
  end

  # ---------------------------------------------------------------------------

  defp process(_repo, %Event{status: status}) when status in ["processed", "dead"], do: :ok

  defp process(repo, %Event{} = event) do
    if (event.attempt_count || 0) >= (event.max_attempts || Ingest.default_max_attempts()) do
      {:ok, _dead} = Event.mark_dead(repo, event, :retry_budget_exhausted)
      {:discard, :retry_budget_exhausted}
    else
      {:ok, processing} = Event.mark_processing(repo, event)

      case Ingest.provider(processing.provider) do
        {:ok, module, config} ->
          run_handler(repo, processing, module, config)

        :error ->
          {:ok, _dead} = Event.mark_dead(repo, processing, :provider_not_configured)
          {:discard, :provider_not_configured}
      end
    end
  end

  defp run_handler(repo, %Event{} = event, module, config) do
    envelope = envelope(event)
    opts = [config: config, repo: repo, provider: event.provider, event_id: event.id]

    case safe_handle(module, envelope, opts) do
      :ok ->
        {:ok, _processed} = Event.mark_processed(repo, event)
        :ok

      {:discard, reason} ->
        dead_letter(repo, event, reason)

      {:error, reason} ->
        retry_or_dead(repo, event, reason)

      other ->
        retry_or_dead(repo, event, {:invalid_handler_result, other_class(other)})
    end
  end

  defp safe_handle(module, envelope, opts) do
    module.handle(envelope, opts)
  rescue
    error -> {:error, {:handler_raised, error.__struct__}}
  catch
    kind, _reason -> {:error, {:handler_caught, kind}}
  end

  defp retry_or_dead(repo, %Event{} = event, reason) do
    if (event.attempt_count || 0) >= (event.max_attempts || Ingest.default_max_attempts()) do
      dead_letter(repo, event, reason)
    else
      {:error, reason}
    end
  end

  defp dead_letter(repo, event, reason) do
    {:ok, _dead} = Event.mark_dead(repo, event, reason)
    {:discard, reason}
  end

  # Never let an arbitrary handler return value reach the error store; a
  # non-standard return is classified by term type only.
  defp other_class(value) when is_map(value), do: :map
  defp other_class(value) when is_list(value), do: :list
  defp other_class(value) when is_binary(value), do: :binary
  defp other_class(value) when is_atom(value), do: value
  defp other_class(_), do: :term

  defp envelope(%Event{} = event) do
    %Contract.Envelope{
      schema_version: event.schema_version,
      event_id: event.event_id,
      event_type: event.event_type,
      occurred_at: event.occurred_at,
      payload: event.payload || %{},
      idempotency_key: event.idempotency_key
    }
  end

  defp resolve_repo(args) do
    case Map.get(args, "repo") || Map.get(args, :repo) do
      nil -> Ingest.repo()
      module when is_atom(module) -> module
      module when is_binary(module) -> safe_module(module)
    end
  end

  defp safe_module(name) do
    String.to_existing_atom(name)
  rescue
    _ ->
      try do
        Module.concat([name])
      rescue
        _ -> nil
      end
  end
end
