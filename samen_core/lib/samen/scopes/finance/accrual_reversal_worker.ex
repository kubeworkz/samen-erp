defmodule Samen.Scopes.Finance.AccrualReversalWorker do
  @moduledoc """
  The daily scheduled-reversal cron (WS-ACCT Phase 5; ADR-054 D6).

  Thin Oban shell over `Samen.Scopes.Finance.AccrualReversal.run/1`: the run
  does the reading and posting, this module only puts it on the canonical
  crontab and turns its verdict into an Oban verdict.

  Queue `:automation_timers` — the timer-driven ACTION lane (`:maintenance` is
  for infrastructure sweeps and is deliberately not used for ledger writes).
  `unique: [period: 3600, states: Oban.Job.states()]` so a retry or a
  double-schedule cannot run two reversals sweeps concurrently; the one-way
  `:draft -> :posted` transition is the real exactly-once guarantee, and this is
  the scheduling hygiene on top of it.

  A failed posting returns `{:error, _}` on purpose: Oban retries it and then
  moves it to the dead-letter bucket. A month-end reversal that could not post
  must be visible, never silently counted as done.
  """

  use Oban.Worker,
    queue: :automation_timers,
    max_attempts: 3,
    unique: [period: 3_600, states: Oban.Job.states()]

  require Logger

  alias Samen.Scopes.Finance.AccrualReversal

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case AccrualReversal.run() do
      {:ok, %{posted: []}} ->
        :ok

      {:ok, %{posted: posted}} ->
        Logger.info("[Finance.AccrualReversal] posted #{length(posted)} scheduled reversal(s)")
        :ok

      {:error, reason} ->
        Logger.error(
          "[Finance.AccrualReversal] a scheduled reversal refused to post: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end
end
