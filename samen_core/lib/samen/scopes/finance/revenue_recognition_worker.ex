defmodule Samen.Scopes.Finance.RevenueRecognitionWorker do
  @moduledoc """
  The monthly recognition cron (WS-ACCT Phase 6; ADR-054 D5).

  Thin Oban shell over `Samen.Scopes.Finance.RecognitionRun.run/1`: the run
  reads the schedules and posts their slices, this module only puts it on the
  canonical crontab and turns its verdict into an Oban verdict.

  Queue `:automation_timers` — the timer-driven ACTION lane (the accrual
  reversal's lane); `:maintenance` is for infrastructure sweeps and is
  deliberately not used for ledger writes. `unique: [period: 3600, states:
  Oban.Job.states()]` so a retry or a double-schedule cannot run two sweeps
  concurrently; the per-period recognition guard is the real exactly-once
  guarantee, and this is the scheduling hygiene on top of it.

  The run's default period is the month BEFORE the wall clock (`30 0 1 * *`),
  so February's revenue is recognized on the 1st of March, once February's
  activity is complete.

  A failed posting returns `{:error, _}` on purpose: Oban retries it and then
  moves it to the dead-letter bucket. A month that could not be recognized must
  be visible, never silently counted as done.
  """

  use Oban.Worker,
    queue: :automation_timers,
    max_attempts: 3,
    unique: [period: 3_600, states: Oban.Job.states()]

  require Logger

  alias Samen.Scopes.Finance.RecognitionRun

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case RecognitionRun.run() do
      {:ok, %{posted: []}} ->
        :ok

      {:ok, %{posted: posted, period: period}} ->
        Logger.info("[Finance.Recognition] #{period}: posted #{length(posted)} recognition(s)")

        :ok

      {:error, reason} ->
        Logger.error("[Finance.Recognition] a recognition refused to post: #{inspect(reason)}")

        {:error, reason}
    end
  end
end
