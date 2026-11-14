defmodule Samen.Scopes.Finance.PrepaidSchedule do
  @moduledoc """
  The DERIVED straight-line release schedule for a prepaid expense
  (`PrepaidSchedule`; WS-ACCT prepaid expense slice).

  A prepaid contract has one total — `total_cents` — and one term —
  `months` from the month of `start_on`. There is no schedule table: every
  slice is derived from those three values, and the only persisted fact is the
  `PrepaidRelease` that actually posted.

  The arithmetic matches the asset/revenue straight-line schedules: the last
  month absorbs the division remainder, so a term releases the total EXACTLY.
  For 10,000 cents over 3 months the slices are 3,333, 3,333 and 3,334.

  Only the MONTH of `start_on` participates in the schedule. The day is kept
  for the register and for the release entry's period-end date.
  """

  @doc """
  The full contractual schedule, in order:

      [%{index: 0, period: {2026, 1}, period_key: "2026-01",
         amount_cents: 3_333, cumulative_cents: 3_333}, ...]
  """
  def slices(%{total_cents: total, months: months, start_on: %Date{} = start})
      when is_integer(total) and is_integer(months) and months > 0 do
    start_period = {start.year, start.month}

    Enum.map(0..(months - 1), fn index ->
      period = add_months(start_period, index)

      %{
        index: index,
        period: period,
        period_key: period_key(period),
        amount_cents: amount_at(total, months, index)
      }
    end)
    |> put_cumulative()
  end

  def slices(_schedule), do: []

  @doc """
  The slice for one `"YYYY-MM"` key: `{:ok, cents}` inside the term,
  `:outside_term` before the start or after the last month, and
  `{:error, :bad_period}` for a malformed key.
  """
  def slice(schedule, period_key) do
    with %Date{} <- schedule.start_on,
         {:ok, period} <- parse_period(period_key),
         true <- in_term?(schedule, period) do
      {:ok, slice_amount(schedule, period)}
    else
      nil -> :outside_term
      false -> :outside_term
      :error -> {:error, :bad_period}
    end
  end

  @doc "The cents this contract releases in `period` (callers check `in_term?/2` first)."
  def slice_amount(%{total_cents: total, months: months, start_on: %Date{} = start}, period) do
    amount_at(total, months, month_index(start, period))
  end

  def slice_amount(_schedule, _period), do: 0

  @doc "Is the period inside the contract's term (start month through `months`)?"
  def in_term?(%{months: months, start_on: %Date{} = start}, {_year, _month} = period)
      when is_integer(months) and months > 0 do
    index = month_index(start, period)
    index >= 0 and index < months
  end

  def in_term?(_schedule, _period), do: false

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

  @doc "The last day of the period (the release entry's date)."
  def period_end({year, month}) do
    Date.new!(year, month, 1) |> Date.end_of_month()
  end

  @doc "The fiscal month BEFORE `%Date{}` — the cron's default (last month)."
  def previous_month(%Date{year: year, month: 1}), do: {year - 1, 12}
  def previous_month(%Date{year: year, month: month}), do: {year, month - 1}

  @doc "How many months after the schedule's start month the period is (0 = the first)."
  def month_index(%Date{} = start, {year, month}) do
    year * 12 + month - (start.year * 12 + start.month)
  end

  # ── internals ──────────────────────────────────────────────────────────────

  defp amount_at(total, months, index) do
    base = div(total, months)
    last = total - base * (months - 1)

    if index == months - 1, do: last, else: base
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
