defmodule Samen.Scopes.Finance.RecurringJournalWorker do
  @moduledoc """
  The daily recurring-journal cron.

  Thin Oban shell over `Samen.Scopes.Finance.RecurringJournalRun.run/1`: the
  run reads due templates and asks each to generate a draft. This module only
  puts the sweep on the canonical crontab and turns the run's verdict into an
  Oban verdict.

  Queue `:automation_timers` — the timer-driven ACTION lane, like the accrual
  and recognition runs. A failed generation is returned as `{:error, _}` so
  Oban retries and eventually dead-letters it; a due draft that could not be
  created must be visible, never silently skipped.
  """

  use Oban.Worker,
    queue: :automation_timers,
    max_attempts: 3,
    unique: [period: 3_600, states: Oban.Job.states()]

  require Logger

  alias Samen.Scopes.Finance.RecurringJournalRun

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case RecurringJournalRun.run() do
      {:ok, %{generated: []}} ->
        :ok

      {:ok, %{generated: generated}} ->
        Logger.info("[Finance.RecurringJournal] generated #{length(generated)} draft journal(s)")

        :ok

      {:error, reason} ->
        Logger.error(
          "[Finance.RecurringJournal] a due template refused to generate: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end
end
