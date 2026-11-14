defmodule Samen.Scopes.Finance.AssetSchedule do
  @moduledoc """
  The DERIVED amortization/depreciation schedule (WS-ACCT Phase 8; ADR-054 D9).

  Pure functions over an `Asset`'s contract — `{cost_cents, salvage_cents,
  life_months, acquired_on}` — never over a stored schedule table. The one
  persisted fact is `AssetPosting` (what actually posted); everything here can
  be re-derived by a reviewer from the register row alone.

  ## The arithmetic

  `amortizable = cost_cents - salvage_cents`. The life is split into
  `life_months` integer cent slices:

      base = div(amortizable, life_months)
      last = amortizable - base * (life_months - 1)

  The LAST month absorbs the division remainder, so the schedule sums to
  `amortizable` EXACTLY. For the PDK licence (600 000.00 over 36 months):
  35 slices of 16 666.66 and a final 16 666.90, which is the manual's JE-004
  arithmetic rendered in whole cents — the headline 16 666.67/month exists only
  as an average, and no single month can be that number without losing cents.

  ## Which month is which

  `in_service_on`'s MONTH is period 1 (the in-service month amortizes); for an
  ordinary asset that date defaults to `acquired_on`. The schedule runs for
  `life_months` consecutive calendar months and the period key is `"YYYY-MM"`.
  Only the month matters — the day is retained for the register and disposal
  comparison, not for the schedule. A construction-in-progress asset has no
  `in_service_on` yet and therefore no schedule.

  ## Disposal

  `stopped?/2` answers whether a period is at or after a disposal's month. The
  RUN consults it; the contractual schedule does not, because the schedule is
  the asset's life, not its policy. A disposal therefore stops future slices
  and leaves the already-posted ones exactly where they are — there is no
  catch-up write-off and no retroactive erasure.

  ## Not a period helper

  `period_key/1`, `period_end/1` and `previous_month/1` are local because a
  schedule speaks months; they mirror `RecognitionRun`'s private helpers rather
  than coupling the asset engine to the revenue engine.
  """

  @doc """
  The full contractual schedule, in order:

      [%{index: 0, period: {2026, 1}, period_key: "2026-01",
         amount_cents: 1_666_666, cumulative_cents: 1_666_666}, ...]

  `index` is 0-based. An asset with a non-positive life yields `[]` (the create
  action refuses that shape; the guard keeps the function total).
  """
  def slices(%{life_months: life} = asset) when is_integer(life) and life > 0 do
    case start_on(asset) do
      %Date{} = start_date ->
        start = {start_date.year, start_date.month}

        Enum.map(0..(life - 1), fn index ->
          period = add_months(start, index)

          %{
            index: index,
            period: period,
            period_key: period_key(period),
            amount_cents: amount_at(asset, index)
          }
        end)
        |> put_cumulative()

      nil ->
        []
    end
  end

  def slices(_asset), do: []

  @doc """
  The slice for one period key: `{:ok, cents}` when the period is inside the
  term, `:outside_term` when it is before the acquisition or after the life,
  `{:error, :bad_period}` for a key that is not `"YYYY-MM"`.
  """
  def slice(asset, period_key) do
    with %Date{} <- start_on(asset),
         {:ok, period} <- parse_period(period_key),
         true <- in_term?(asset, period) do
      {:ok, slice_amount(asset, period)}
    else
      nil -> :outside_term
      false -> :outside_term
      :error -> {:error, :bad_period}
    end
  end

  @doc "The cents this asset amortizes in `period` (callers check `in_term?/2` first)."
  def slice_amount(asset, period) do
    case start_on(asset) do
      %Date{} = start -> amount_at(asset, month_index(start, period))
      nil -> 0
    end
  end

  @doc "Is the period inside the asset's term (in-service month through month `life_months`)?"
  def in_term?(%{life_months: life} = asset, {_year, _month} = period) do
    case start_on(asset) do
      %Date{} = start ->
        index = month_index(start, period)
        index >= 0 and index < life

      nil ->
        false
    end
  end

  def in_term?(_asset, _period), do: false

  @doc "Is the period before the asset's first in-service month?"
  def before_start?(asset, period) do
    case start_on(asset) do
      %Date{} = start -> month_index(start, period) < 0
      nil -> false
    end
  end

  @doc """
  The date the schedule starts: `in_service_on` when present, otherwise
  `acquired_on` for a legacy/active row. A CIP (and a disposed CIP) has no
  schedule start yet, so this returns `nil`.
  """
  def start_on(%{in_service_on: %Date{} = on}), do: on
  def start_on(%{status: :active, acquired_on: %Date{} = on}), do: on
  def start_on(_asset), do: nil

  @doc """
  Has a disposal stopped this period? True for the disposal's month and every
  month after it; an active (or undated) asset is never stopped.
  """
  def stopped?(%{status: :disposed, disposed_on: %Date{} = on}, period) do
    {year, month} = period
    year * 12 + month >= on.year * 12 + on.month
  end

  def stopped?(_asset, _period), do: false

  @doc "Cost minus salvage: the amount the life must release in full."
  def amortizable(%{cost_cents: cost, salvage_cents: salvage})
      when is_integer(cost) and is_integer(salvage),
      do: cost - salvage

  def amortizable(_asset), do: 0

  @doc ~s(The period's stable key, "YYYY-MM".)
  def period_key({year, month}) do
    "#{year}-#{month |> Integer.to_string() |> String.pad_leading(2, "0")}"
  end

  @doc "Parse a `\"YYYY-MM\"` key; `:error` for anything else."
  def parse_period(key) when is_binary(key) do
    with [year, month] <- String.split(key, "-"),
         {year, ""} <- Integer.parse(year),
         {month, ""} <- Integer.parse(month),
         true <- month in 1..12 do
      {:ok, {year, month}}
    else
      _ -> :error
    end
  end

  def parse_period(_key), do: :error

  @doc "The last day of the period (the posting entry's date)."
  def period_end({year, month}) do
    Date.new!(year, month, 1) |> Date.end_of_month()
  end

  @doc "The fiscal month BEFORE `%Date{}` — the cron's default (last month)."
  def previous_month(%Date{year: year, month: 1}), do: {year - 1, 12}
  def previous_month(%Date{year: year, month: month}), do: {year, month - 1}

  @doc "How many months after the asset's acquisition month the period is (0 = the first)."
  def month_index(%Date{} = acquired, {year, month}) do
    year * 12 + month - (acquired.year * 12 + acquired.month)
  end

  # ── internals ──────────────────────────────────────────────────────────────

  defp amount_at(asset, index) do
    life = asset.life_months
    total = amortizable(asset)
    base = div(total, life)
    last = total - base * (life - 1)

    if index == life - 1, do: last, else: base
  end

  defp add_months({year, month}, 0), do: {year, month}

  defp add_months({year, month}, count) do
    total = year * 12 + (month - 1) + count
    {div(total, 12), rem(total, 12) + 1}
  end

  defp put_cumulative(slices) do
    {with_cumulative, _} =
      Enum.map_reduce(slices, 0, fn slice, running ->
        cumulative = running + slice.amount_cents
        {Map.put(slice, :cumulative_cents, cumulative), cumulative}
      end)

    with_cumulative
  end
end
