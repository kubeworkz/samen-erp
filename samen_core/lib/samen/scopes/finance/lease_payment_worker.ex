defmodule Samen.Scopes.Finance.LeasePaymentWorker do
  @moduledoc """
  The monthly lease payment cron.

  Thin Oban shell over `Samen.Scopes.Finance.LeasePaymentRun.run/1`: the run
  derives and posts the month's payments, this module puts it on the canonical
  crontab and turns its verdict into an Oban verdict.

  Queue `:automation_timers` — the same timer-driven ledger lane as the
  accrual reversal, revenue recognition and prepaid releases. The run defaults
  to the month BEFORE the wall clock, so January payments post on 1 February.

  A failed payment returns `{:error, _}` on purpose: Oban retries it and then
  dead-letters it, so a month that could not be posted is visible rather than
  silently counted as done.
  """

  use Oban.Worker,
    queue: :automation_timers,
    max_attempts: 3,
    unique: [period: 3_600, states: Oban.Job.states()]

  require Logger

  alias Samen.Scopes.Finance.LeasePaymentRun

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case LeasePaymentRun.run() do
      {:ok, %{posted: []}} ->
        :ok

      {:ok, %{posted: posted, period: period}} ->
        Logger.info("[Finance.LeasePayment] #{period}: posted #{length(posted)} payment(s)")

        :ok

      {:error, reason} ->
        Logger.error("[Finance.LeasePayment] a payment refused to post: #{inspect(reason)}")

        {:error, reason}
    end
  end
end
