defmodule Samen.Scopes.Finance.CollectionDunningWorker do
  @moduledoc """
  The daily AR collection dunning cron.

  Thin Oban shell over `Samen.Scopes.Finance.CollectionDunning.run/1`: the
  run selects the open cases whose `next_action_on` is due and appends the
  next ladder step, this module only puts it on the canonical crontab and
  turns its verdict into an Oban verdict.

  Queue `:automation_timers` — the timer-driven ACTION lane; `:maintenance` is
  for infrastructure sweeps. `unique: [period: 3600, states:
  Oban.Job.states()]` keeps a retry or double-schedule from running two sweeps
  at once; the event's case-id/due-date idempotency key is the real exactly-once
  guarantee, and this is scheduling hygiene on top of it.

  A case whose action refuses is REPORTED, not counted as done: the run returns
  `{:error, {:dunning_failed, failures}}` so Oban retries and then dead-letters
  it. A host with no CollectionCase wired is a named no-op.
  """

  use Oban.Worker,
    queue: :automation_timers,
    max_attempts: 3,
    unique: [period: 3_600, states: Oban.Job.states()]

  require Logger

  alias Samen.Scopes.Finance.CollectionDunning

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case CollectionDunning.run() do
      {:ok, %{state: :not_configured}} ->
        :ok

      {:ok, %{recorded: [], skipped: []}} ->
        :ok

      {:ok, %{recorded: recorded, skipped: skipped}} ->
        Logger.info(
          "[Finance.CollectionDunning] advanced #{length(recorded)} case(s), " <>
            "skipped #{length(skipped)} case(s)"
        )

        :ok

      {:error, reason} ->
        Logger.error("[Finance.CollectionDunning] a case refused to advance: #{inspect(reason)}")

        {:error, reason}
    end
  end
end
