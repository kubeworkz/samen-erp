defmodule Samen.Scopes.Finance.DepreciationWorker do
  @moduledoc """
  The monthly depreciation cron (WS-ACCT Phase 8; ADR-054 D9).

  Thin Oban shell over `Samen.Scopes.Finance.DepreciationRun.run/1`: the run
  reads the register and posts the due slices, this module only puts it on the
  canonical crontab and turns its verdict into an Oban verdict.

  Queue `:automation_timers` — the timer-driven ACTION lane (the accrual
  reversal's and the recognition run's lane); `:maintenance` is for
  infrastructure sweeps and is deliberately not used for ledger writes.
  `unique: [period: 3600, states: Oban.Job.states()]` so a retry or a
  double-schedule cannot run two sweeps concurrently; the per-period posting
  guard is the real exactly-once guarantee, and this is the scheduling hygiene
  on top of it.

  The run's default period is the month BEFORE the wall clock (`45 0 1 * *`),
  so January's slice posts on 1 February once January's activity is complete.

  A failed posting returns `{:error, _}` on purpose: Oban retries it and then
  moves it to the dead-letter bucket. A month that could not be depreciated
  must be visible, never silently counted as done.
  """

  use Oban.Worker,
    queue: :automation_timers,
    max_attempts: 3,
    unique: [period: 3_600, states: Oban.Job.states()]

  require Logger

  alias Samen.Scopes.Finance.DepreciationRun

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case DepreciationRun.run() do
      {:ok, %{posted: []}} ->
        :ok

      {:ok, %{posted: posted, period: period}} ->
        Logger.info("[Finance.Depreciation] #{period}: posted #{length(posted)} slice(s)")

        :ok

      {:error, reason} ->
        Logger.error("[Finance.Depreciation] a slice refused to post: #{inspect(reason)}")

        {:error, reason}
    end
  end
end
