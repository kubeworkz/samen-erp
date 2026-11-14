defmodule Samen.Scopes.Finance.PrepaidReleaseWorker do
  @moduledoc """
  The monthly prepaid release cron (WS-ACCT prepaid expense slice).

  Thin Oban shell over `Samen.Scopes.Finance.PrepaidReleaseRun.run/1`: the run
  derives and posts the due slices, this module only puts it on the canonical
  crontab and turns its verdict into an Oban verdict.

  Queue `:automation_timers` — the same timer-driven ledger lane as the
  accrual reversal and revenue recognition. The run defaults to the month BEFORE
  the wall clock, so January releases post on 1 February.

  A failed release returns `{:error, _}` on purpose: Oban retries it and then
  dead-letters it, so a month that could not be released is visible rather than
  silently counted as done.
  """

  use Oban.Worker,
    queue: :automation_timers,
    max_attempts: 3,
    unique: [period: 3_600, states: Oban.Job.states()]

  require Logger

  alias Samen.Scopes.Finance.PrepaidReleaseRun

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case PrepaidReleaseRun.run() do
      {:ok, %{posted: []}} ->
        :ok

      {:ok, %{posted: posted, period: period}} ->
        Logger.info("[Finance.PrepaidRelease] #{period}: posted #{length(posted)} release(s)")

        :ok

      {:error, reason} ->
        Logger.error("[Finance.PrepaidRelease] a release refused to post: #{inspect(reason)}")

        {:error, reason}
    end
  end
end
