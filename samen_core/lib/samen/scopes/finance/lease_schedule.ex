defmodule Samen.Scopes.Finance.LeaseSchedule do
  @moduledoc """
  The DERIVED IFRS 16 lease schedule for one `Lease` contract.

  There is no schedule table. Every row is rebuilt from the contract:

    * `payment_cents` — the fixed monthly lease payment;
    * `months` — the lease term in whole months;
    * `start_on` — the commencement month;
    * `annual_rate_bps` — the incremental borrowing rate in basis points
      (`500` = 5.00% a year).

  The initial lease liability is the present value of the fixed monthly
  payment stream, paid at each month end, at the monthly rate. The right-of-use
  asset is initially the same amount (this slice deliberately excludes initial
  direct costs, incentives and restoration obligations). Each month then derives:

    * interest on the liability and the principal repaid by the payment;
    * straight-line ROU amortization, with the final month absorbing the
      division remainder so the asset amortizes to exactly zero.

  ## Rounding

  Cents cannot represent a fractional present value. The initial liability is
  rounded half-up to whole cents; interest is rounded per month; the final
  payment/interest row absorbs any cent difference so the liability closes at
  zero. The final ROU amortization slice absorbs the division remainder the same
  way. A reviewer can therefore rebuild every row from the contract alone.

  ## Scope

  This is a fixed-payment, month-end, single-currency lease calculator. Advance
  rent, variable payments, escalations, renewal/termination options, purchase
  options and currency translation are not invented here; they belong to the
  contract's data model when a host actually needs them.
  """

  @type slice :: %{
          index: non_neg_integer(),
          period: {pos_integer(), 1..12},
          period_key: String.t(),
          payment_cents: integer(),
          interest_cents: integer(),
          principal_cents: integer(),
          liability_opening_cents: integer(),
          liability_closing_cents: integer(),
          amortization_cents: integer(),
          rou_opening_cents: integer(),
          rou_closing_cents: integer()
        }

  @doc """
  Initial lease liability: the present value of the fixed payment stream.

  Payments are modeled at each month end, so this is the ordinary annuity
  present value.
  """
  @spec initial_liability(map()) :: non_neg_integer()
  def initial_liability(%{payment_cents: payment, months: months} = lease)
      when is_integer(payment) and payment > 0 and is_integer(months) and months > 0 do
    rate = monthly_rate(lease)

    Decimal.new(payment)
    |> Decimal.mult(annuity(months, rate))
    |> Decimal.round(0, :half_up)
    |> Decimal.to_integer()
  end

  def initial_liability(_lease), do: 0

  @doc """
  The full schedule, in order. The last month absorbs the payment/interest and
  ROU-amortization rounding remainders.
  """
  @spec slices(map()) :: [slice()]
  def slices(%{payment_cents: payment, months: months, start_on: %Date{} = start} = lease)
      when is_integer(payment) and payment > 0 and is_integer(months) and months > 0 do
    initial = initial_liability(lease)
    rate = monthly_rate(lease)
    start_period = {start.year, start.month}

    {rows, _state} =
      Enum.map_reduce(0..(months - 1), {initial, initial}, fn index, {opening, rou_opening} ->
        period = add_months(start_period, index)
        last? = index == months - 1

        {interest, principal, payment_this_month} = month_amounts(opening, payment, rate, last?)

        closing = opening - principal
        amortization = amortization_at(initial, months, index)
        rou_closing = rou_opening - amortization

        row = %{
          index: index,
          period: period,
          period_key: period_key(period),
          payment_cents: payment_this_month,
          interest_cents: interest,
          principal_cents: principal,
          liability_opening_cents: opening,
          liability_closing_cents: closing,
          amortization_cents: amortization,
          rou_opening_cents: rou_opening,
          rou_closing_cents: rou_closing
        }

        {row, {closing, rou_closing}}
      end)

    rows
  end

  def slices(_lease), do: []

  @doc """
  The row for one `"YYYY-MM"` key: `{:ok, row}` inside the term,
  `:outside_term` before commencement/after the end, or
  `{:error, :bad_period}` for a malformed key.
  """
  @spec slice(map(), String.t()) :: {:ok, slice()} | :outside_term | {:error, :bad_period}
  def slice(lease, period_key) do
    with %Date{} <- lease.start_on,
         {:ok, period} <- parse_period(period_key),
         true <- in_term?(lease, period) do
      case Enum.at(slices(lease), month_index(lease.start_on, period)) do
        nil -> :outside_term
        row -> {:ok, row}
      end
    else
      nil -> :outside_term
      false -> :outside_term
      :error -> {:error, :bad_period}
    end
  end

  @doc "Is `period` inside the lease term?"
  def in_term?(%{months: months, start_on: %Date{} = start}, period)
      when is_integer(months) and months > 0 do
    index = month_index(start, period)
    index >= 0 and index < months
  end

  def in_term?(_lease, _period), do: false

  @doc ~s(The period's stable key, "YYYY-MM".)
  def period_key({year, month}) do
    "#{year}-#{month |> Integer.to_string() |> String.pad_leading(2, "0")}"
  end

  @doc "Parse a `\"YYYY-MM\"` key; `:error` for anything else."
  def parse_period(key) when is_binary(key) do
    with [year, month] <- String.split(key, "-"),
         true <- byte_size(year) == 4 and byte_size(month) == 2,
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

  @doc "The fiscal month BEFORE `%Date{}` — the cron's default."
  def previous_month(%Date{year: year, month: 1}), do: {year - 1, 12}
  def previous_month(%Date{year: year, month: month}), do: {year, month - 1}

  @doc "How many months after commencement the period is (0 = first month)."
  def month_index(%Date{} = start, {year, month}) do
    year * 12 + month - (start.year * 12 + start.month)
  end

  # ── internals ──────────────────────────────────────────────────────────────

  defp month_amounts(opening, payment, rate, last?) do
    cond do
      last? ->
        interest = max(payment - opening, 0)
        {interest, opening, interest + opening}

      true ->
        interest = rate_amount(opening, rate)
        principal = max(payment - interest, 0)
        {interest, principal, payment}
    end
  end

  defp rate_amount(base, rate) do
    base
    |> Decimal.new()
    |> Decimal.mult(rate)
    |> Decimal.round(0, :half_up)
    |> Decimal.to_integer()
    |> max(0)
  end

  defp amortization_at(initial, months, index) do
    base = div(initial, months)
    last = initial - base * (months - 1)

    if index == months - 1, do: last, else: base
  end

  defp annual_rate(%{annual_rate_bps: bps}) when is_integer(bps) and bps >= 0, do: bps
  defp annual_rate(_lease), do: 0

  defp monthly_rate(lease) do
    Decimal.div(Decimal.new(annual_rate(lease)), Decimal.new(120_000))
  end

  defp annuity(months, rate) do
    if Decimal.equal?(rate, 0) do
      Decimal.new(months)
    else
      one = Decimal.new(1)

      factor =
        Enum.reduce(1..months, one, fn _, acc -> Decimal.mult(acc, Decimal.add(one, rate)) end)

      Decimal.div(Decimal.sub(one, Decimal.div(one, factor)), rate)
    end
  end

  defp add_months({year, month}, 0), do: {year, month}

  defp add_months({year, month}, count) do
    total = year * 12 + (month - 1) + count
    {div(total, 12), rem(total, 12) + 1}
  end
end
