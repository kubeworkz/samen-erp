defmodule Samen.Scopes.Finance.RecognitionRun do
  @moduledoc """
  The revenue recognition RUN (WS-ACCT Phase 6; ADR-054 D5): for one fiscal
  month, post every active schedule's slice — through the ordinary governed
  `:recognize` action, which posts the deferred→income entry in the same
  transaction.

  ## What "a slice" means

  * `:straight_line` — `div(total, months)` per period, with the LAST period
    taking the division remainder, so a term releases the total EXACTLY rather
    than leaving stray cents stranded in deferred revenue forever.
  * `:cost_incurred` — the period's incurred allowable cost
    (`Samen.Scopes.Finance.IncurredCost`, the read Phase 11's R11 reuses),
    capped by what is left. A period with no incurred cost recognizes ZERO and
    posts NOTHING: recognizing ahead of cost is the accounting error the method
    exists to prevent, and a zero-amount journal entry would be a lie with a
    date on it.

  Every amount is also capped at `remaining` (`total − Σ recognized`), so no
  arithmetic path can release more than the contract holds.

  ## Exactly once, in two layers

  * **The read (`already_recognized?`)** makes a repeated sweep a clean no-op:
    the second run sees the period's row and skips it. This is what the cron
    relies on when a retry fires twice, and it is the contract the suite pins.
  * **The table's unique index on `{org, schedule, period}`** is the belt. If
    the read is ever dropped by a regression, the database still refuses the
    duplicate row — the sweep then fails loudly (and retries into the
    dead-letter bucket) rather than double-recognizing revenue.

  The split matters: the belt alone would make a retry a hard error; the read
  makes the normal case silent. Neither can produce two recognitions for one
  period, which is R9's exactly-once leg.

  ## What it refuses to do

  * It does not recognize a period OUTSIDE a schedule's term (`start_on` for
    `months`), so a late cron run cannot extend a contract's life.
  * It does not backfill missed periods. A period that was never run stays
    unrecognized and is visible as `remaining` — an honest gap, not a silent
    catch-up posting dated into a month nobody reviewed (the P2 carry).
  * A posting that cannot land (unmapped account, closed period) is REPORTED —
    the run returns `{:error, ...}` so the worker retries and dead-letters,
    rather than counting a skipped schedule as done.

  ## The host seam

      config :samen_core, Samen.Scopes.Finance.RecognitionRun,
        modules: [
          schedule: Samenerp.Erp.RevenueSchedule,
          recognition: Samenerp.Erp.RevenueRecognition,
          entry: Samenerp.Erp.JournalEntry,
          line: Samenerp.Erp.JournalLine,
          account: Samenerp.Erp.Account
        ]

  An unconfigured host is a NO-OP that names itself (`:not_configured`), not a
  silent success: there are no books to recognize into.

  ## Testability

  `run/1` takes `period: {year, month}` so a suite states its own month instead
  of waiting for the calendar.
  """

  require Ash.Query

  alias Samen.Scopes.Finance.IncurredCost

  @config_key __MODULE__

  @doc "The host's wired finance modules, or nil when the host has not wired them."
  def modules do
    case :samen_core |> Application.get_env(@config_key, []) |> Keyword.get(:modules) do
      nil -> nil
      modules -> Map.new(modules)
    end
  end

  @doc """
  Run the recognition sweep for one month. Returns
  `{:ok, %{period: "YYYY-MM", posted: [...], skipped: [{schedule_id, reason}]}}`,
  or `{:error, {:recognition_failed, [...]}}` naming every schedule whose
  posting refused.
  """
  def run(opts \\ []) do
    period = Keyword.get_lazy(opts, :period, fn -> previous_month(Date.utc_today()) end)
    key = period_key(period)

    case modules() do
      nil ->
        {:ok, %{period: key, posted: [], skipped: [], state: :not_configured}}

      mods ->
        sweep(mods, period, key)
    end
  end

  defp sweep(mods, period, key) do
    repo = AshPostgres.DataLayer.Info.repo(mods.schedule, :read)

    schedules =
      mods.schedule
      |> Ash.Query.ensure_selected([:org_id])
      |> Ash.Query.load(:recognized_cents)
      |> Ash.Query.sort(start_on: :asc)
      # authz-scope: system sweep — the run recognizes EVERY org's due slice,
      # and each row's own governed `:recognize` action (OrgScope, PeriodGuard,
      # PostBalance on the schedule's org) decides whether it may land. Pinning
      # this read to one org would leave every other tenant's month unrecognized.
      |> Ash.read!(authorize?: false)

    results =
      Enum.map(schedules, fn schedule ->
        case plan(schedule, period, mods, repo) do
          {:post, amount} -> post(mods, schedule, key, period, amount)
          {:skip, reason} -> {:skip, {schedule.id, reason}}
          {:error, reason} -> {:error, {schedule.id, reason}}
        end
      end)

    posted = for {:posted, id} <- results, do: id
    skipped = for {:skip, entry} <- results, do: entry
    failed = for {:error, failure} <- results, do: failure

    if failed == [] do
      {:ok, %{period: key, posted: posted, skipped: skipped}}
    else
      {:error, {:recognition_failed, failed}}
    end
  end

  # ── the plan ───────────────────────────────────────────────────────────────

  defp plan(schedule, period, mods, repo) do
    recognized = schedule.recognized_cents || 0
    remaining = schedule.total_cents - recognized

    cond do
      remaining <= 0 ->
        {:skip, :fully_recognized}

      not in_term?(schedule, period) ->
        {:skip, :outside_term}

      true ->
        case amount(schedule, period, remaining, mods, repo) do
          {:ok, 0} -> {:skip, :nothing_due}
          {:ok, amount} -> {:post, amount}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp amount(%{method: :straight_line} = schedule, period, remaining, _mods, _repo) do
    index = month_index(schedule.start_on, period)
    base = div(schedule.total_cents, schedule.months)
    last = schedule.total_cents - base * (schedule.months - 1)
    slice = if index == schedule.months - 1, do: last, else: base

    {:ok, min(slice, remaining)}
  end

  defp amount(%{method: :cost_incurred} = schedule, period, remaining, mods, repo) do
    case IncurredCost.for_period(
           schedule.org_id,
           period,
           schedule.cost_object_id,
           repo,
           entry_resource: mods.entry,
           line_resource: mods.line,
           account_resource: mods.account
         ) do
      {:ok, incurred} -> {:ok, min(incurred, remaining)}
      {:error, reason} -> {:error, reason}
    end
  end

  # ── posting ────────────────────────────────────────────────────────────────

  defp post(mods, schedule, key, period, amount) do
    if already_recognized?(mods.recognition, schedule, key) do
      {:skip, {schedule.id, :already_recognized}}
    else
      mods.recognition
      |> Ash.Changeset.for_create(
        :recognize,
        %{
          org_id: schedule.org_id,
          schedule_id: schedule.id,
          period_key: key,
          amount_cents: amount,
          recognized_on: period_end(period)
        },
        authorize?: false
      )
      |> Ash.create(authorize?: false)
      |> case do
        {:ok, recognition} -> {:posted, recognition.id}
        {:error, reason} -> {:error, {schedule.id, reason}}
      end
    end
  end

  # Org-pinned and period-pinned: this is the no-op read that makes a repeated
  # sweep silent (the unique index behind it is the belt).
  defp already_recognized?(recognition_mod, schedule, key) do
    recognition_mod
    |> Ash.Query.filter(
      org_id == ^schedule.org_id and schedule_id == ^schedule.id and period_key == ^key
    )
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, nil} -> false
      {:ok, _row} -> true
      {:error, _reason} -> false
    end
  end

  # ── period math ────────────────────────────────────────────────────────────

  @doc "The fiscal month BEFORE `%Date{}` — the cron's default (last month)."
  def previous_month(%Date{year: year, month: 1}), do: {year - 1, 12}
  def previous_month(%Date{year: year, month: month}), do: {year, month - 1}

  @doc ~s(The period's stable key, "YYYY-MM".)
  def period_key({year, month}) do
    "#{year}-#{month |> Integer.to_string() |> String.pad_leading(2, "0")}"
  end

  @doc "The last day of the period (the recognition entry's date)."
  def period_end({year, month}) do
    Date.new!(year, month, 1) |> Date.end_of_month()
  end

  @doc "How many months after the schedule's start the period is (0 = the first)."
  def month_index(start_on, {year, month}) do
    year * 12 + month - (start_on.year * 12 + start_on.month)
  end

  defp in_term?(schedule, period) do
    index = month_index(schedule.start_on, period)
    index >= 0 and index < schedule.months
  end
end
