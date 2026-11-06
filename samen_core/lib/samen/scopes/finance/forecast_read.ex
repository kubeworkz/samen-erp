defmodule Samen.Scopes.Finance.ForecastRead do
  @moduledoc """
  The derived reads over a `ForecastVersion` (WS-ACCT Phase 14; ADR-054 D11).

  Every function here is a read. The only stored forecast inputs are the
  version's three scenario weights and its monthly driver facts; the P&L, cash
  flow, runway, scenario comparison, actual-to-forecast bridge and accuracy
  figures are computed from those rows. Actuals come from the existing
  `ProfitLoss` and `CashFlow` reads over the posted ledger, never from a
  second forecast store.

  ## What the driver amounts mean

  `ForecastDriver.amount_cents` is the driver's monetary impact for its month.
  The guard derives its category from the driver tree:

    * revenue — `slot_price`
    * COGS — `die_yield`
    * operating expense — `eda_spend`, `headcount`
    * cash out — `burn`
    * cash in — `grant_pipeline`

  The read weights each scenario's category sums by the version's
  `scenario_weights`; there is no generic formula evaluator and no hidden
  arithmetic between drivers.

  ## Honest absence

  No drivers means empty rows and zero totals. No `:cash` posting map means
  `mapped?: false` and no runway rather than a guessed bank balance. A
  non-positive net burn reports `:not_burning` with a nil runway, not an
  invented infinity.
  """

  require Ash.Query

  alias Samen.Scopes.Finance.{CashFlow, ProfitLoss}

  @scenarios ~w(base upside downside)

  @type totals :: %{
          revenue_cents: integer(),
          cogs_cents: integer(),
          operating_expense_cents: integer(),
          net_income_cents: integer(),
          cash_in_cents: integer(),
          cash_out_cents: integer(),
          net_cash_cents: integer()
        }

  @doc """
  Weighted monthly P&L for `version`.

  Required opts: `:driver` (the host's ForecastDriver module).
  """
  def pnl(version, opts) do
    driver_mod = Keyword.fetch!(opts, :driver)
    weights = weights(version)
    months = weighted_months(drivers(version, driver_mod), weights)
    totals = sum_months(months)

    %{
      version_id: version.id,
      name: version.name,
      version: version.version,
      starts_on: version.starts_on,
      ends_on: version.ends_on,
      weights: weights,
      rows: month_rows(months),
      totals: totals
    }
  end

  @doc """
  Weighted monthly cash flow for `version`, opening from the ledger's cash
  accounts and carrying the forecast movement forward.

  Required opts: `:driver`, `:repo`, `:posting_account`, `:line`, `:entry`.
  """
  def cash_flow(version, opts) do
    driver_mod = Keyword.fetch!(opts, :driver)
    weights = weights(version)

    cash =
      CashFlow.statement(
        org_id(version, opts),
        from_datetime(version),
        to_datetime(version),
        repo: Keyword.fetch!(opts, :repo),
        posting_account: Keyword.fetch!(opts, :posting_account),
        line: Keyword.fetch!(opts, :line),
        entry: Keyword.fetch!(opts, :entry)
      )
      |> elem(1)

    months = weighted_months(drivers(version, driver_mod), weights)

    {rows, closing_cents} =
      Enum.map_reduce(months, cash.opening_cents, fn {date, totals}, opening ->
        row = %{
          period_on: date,
          period_key: period_key(date),
          opening_cents: opening,
          cash_in_cents: totals.cash_in_cents,
          cash_out_cents: totals.cash_out_cents,
          net_cents: totals.net_cash_cents,
          closing_cents: opening + totals.net_cash_cents
        }

        {row, row.closing_cents}
      end)

    %{
      version_id: version.id,
      opening_cents: cash.opening_cents,
      actual_cash_cents: cash.closing_cents,
      closing_cents: closing_cents,
      mapped?: cash.mapped?,
      reconciled?: cash.mapped? and cash.reconciled?,
      cash_account_ids: cash.cash_account_ids,
      rows: rows,
      source: "CashFlow.statement/4"
    }
  end

  @doc """
  Cash runway from the weighted forecast burn and the ledger's cash balance.

  The cash-on-hand leg is the actual closing balance from `CashFlow.statement/4`
  over the version's range; the burn leg is the weighted monthly net cash
  outflow (`cash_out - cash_in`). `reconciled?` is the cash read's own
  reconciliation against the host's `:cash` posting accounts.
  """
  def runway(version, opts) do
    cash = cash_flow(version, opts)
    month_count = length(cash.rows)

    total_net_burn =
      Enum.reduce(cash.rows, 0, fn row, acc ->
        acc + row.cash_out_cents - row.cash_in_cents
      end)

    avg_monthly_burn =
      if month_count == 0, do: nil, else: round(total_net_burn / month_count)

    status =
      cond do
        month_count == 0 -> :no_forecast
        avg_monthly_burn == nil or avg_monthly_burn <= 0 -> :not_burning
        true -> :runway
      end

    runway_months =
      if status == :runway do
        Float.round(cash.actual_cash_cents / avg_monthly_burn, 1)
      end

    %{
      version_id: version.id,
      status: status,
      cash_on_hand_cents: cash.actual_cash_cents,
      avg_monthly_burn_cents: avg_monthly_burn,
      runway_months: runway_months,
      mapped?: cash.mapped?,
      reconciled?: cash.reconciled?,
      cash_account_ids: cash.cash_account_ids,
      source: "ForecastRead.cash_flow/2 (cash leg: CashFlow.statement/4)"
    }
  end

  @doc """
  Per-scenario totals plus the version's weighted blend.

  Required opts: `:driver`.
  """
  def scenarios(version, opts) do
    driver_mod = Keyword.fetch!(opts, :driver)
    weights = weights(version)
    rows = drivers(version, driver_mod)

    scenario_rows =
      Enum.map(@scenarios, fn key ->
        totals =
          rows
          |> Enum.filter(&(to_string(&1.scenario) == key))
          |> totals_for_rows()

        Map.merge(
          %{scenario: String.to_existing_atom(key), weight: Map.get(weights, key, 0.0)},
          totals
        )
      end)

    pnl = pnl(version, opts)

    %{
      version_id: version.id,
      weights: weights,
      scenarios: scenario_rows,
      weighted: pnl.totals
    }
  end

  @doc """
  Actual-to-forecast bridge over revenue, expenses, net income and cash.

  Actual P&L and cash are recomputed for the version's range; the forecast side
  is the weighted driver read. This is a bridge, not a stored variance row.
  """
  def variance(version, opts) do
    forecast = pnl(version, opts)

    actual =
      ProfitLoss.generate(
        org_id(version, opts),
        from_datetime(version),
        to_datetime(version),
        repo: Keyword.fetch!(opts, :repo),
        account_resource: Keyword.fetch!(opts, :account),
        line_resource: Keyword.fetch!(opts, :line),
        entry_resource: Keyword.fetch!(opts, :entry)
      )
      |> elem(1)

    actual_cash =
      CashFlow.statement(
        org_id(version, opts),
        from_datetime(version),
        to_datetime(version),
        repo: Keyword.fetch!(opts, :repo),
        posting_account: Keyword.fetch!(opts, :posting_account),
        line: Keyword.fetch!(opts, :line),
        entry: Keyword.fetch!(opts, :entry)
      )
      |> elem(1)

    forecast_expenses =
      forecast.totals.cogs_cents + forecast.totals.operating_expense_cents

    rows = [
      bridge_row(:revenue, actual.total_revenue, forecast.totals.revenue_cents),
      bridge_row(:expenses, actual.total_expenses, forecast_expenses),
      bridge_row(:net_income, actual.net_income, forecast.totals.net_income_cents),
      bridge_row(:cash_net, actual_cash.net_cents, forecast.totals.net_cash_cents)
    ]

    %{
      version_id: version.id,
      actual: %{
        revenue_cents: actual.total_revenue,
        expenses_cents: actual.total_expenses,
        net_income_cents: actual.net_income,
        cash_net_cents: actual_cash.net_cents
      },
      forecast: forecast.totals,
      rows: rows,
      net_variance_cents: actual.net_income - forecast.totals.net_income_cents
    }
  end

  @doc """
  Compare every published version overlapping `[from_date, to_date]` to the
  ledger actuals for that range.

  `actual` is computed once from `ProfitLoss` (and is not stored anywhere);
  each version's forecast is recomputed from its driver rows. Accuracy is
  `max(0, 100 - |forecast net − actual net| / |actual net| × 100)`, and nil
  when the actual net is zero — never a fabricated division.
  """
  def accuracy(org_id, from_date, to_date, opts) do
    version_mod = Keyword.fetch!(opts, :version)
    driver_mod = Keyword.fetch!(opts, :driver)
    from = date(from_date)
    to = date(to_date)

    actual =
      ProfitLoss.generate(
        org_id,
        start_datetime(from),
        end_datetime(to),
        repo: Keyword.fetch!(opts, :repo),
        account_resource: Keyword.fetch!(opts, :account),
        line_resource: Keyword.fetch!(opts, :line),
        entry_resource: Keyword.fetch!(opts, :entry)
      )
      |> elem(1)

    versions =
      version_mod
      |> Ash.Query.filter(
        org_id == ^org_id and status == :published and
          starts_on <= ^to and ends_on >= ^from
      )
      |> Ash.read!(authorize?: false)

    rows =
      versions
      |> Enum.map(fn version ->
        forecast = pnl(version, driver: driver_mod).totals.net_income_cents
        error = forecast - actual.net_income
        abs_error = abs(error)

        %{
          version_id: version.id,
          name: version.name,
          version: version.version,
          starts_on: version.starts_on,
          ends_on: version.ends_on,
          forecast_net_income_cents: forecast,
          actual_net_income_cents: actual.net_income,
          error_cents: error,
          abs_error_cents: abs_error,
          accuracy_pct: accuracy_pct(abs_error, actual.net_income)
        }
      end)
      |> Enum.sort_by(& &1.version)

    %{
      org_id: org_id,
      from_date: from,
      to_date: to,
      actual: %{
        revenue_cents: actual.total_revenue,
        expenses_cents: actual.total_expenses,
        net_income_cents: actual.net_income
      },
      versions: rows
    }
  end

  # ── driver weighting ──────────────────────────────────────────────────────

  defp drivers(version, driver_mod) do
    driver_mod
    |> Ash.Query.filter(version_id == ^version.id)
    |> Ash.read!(authorize?: false)
  end

  # A create-returned version can have `org_id` unloaded (Ash does not return
  # every injected column on a write). Reads that touch the ledger take the
  # caller's org explicitly; the version id alone is enough for driver reads.
  defp org_id(version, opts) do
    Keyword.get(opts, :org_id) || version.org_id
  end

  defp weights(version) do
    Map.new(version.scenario_weights || %{}, fn {key, value} ->
      {to_string(key), number(value)}
    end)
  end

  defp weighted_months(drivers, weights) do
    drivers
    |> Enum.group_by(& &1.period_on)
    |> Enum.map(fn {date, rows} -> {date, totals_for_rows(rows, weights)} end)
    |> Enum.sort_by(fn {date, _totals} -> Date.to_erl(date) end)
  end

  defp totals_for_rows(rows, weights \\ nil) do
    totals =
      Enum.reduce(
        rows,
        %{revenue: 0.0, cogs: 0.0, operating_expense: 0.0, cash_in: 0.0, cash_out: 0.0},
        fn row, acc ->
          weight = if weights, do: Map.get(weights, to_string(row.scenario), 0.0), else: 1.0

          Map.update(
            acc,
            row.category,
            weight * row.amount_cents,
            &(&1 + weight * row.amount_cents)
          )
        end
      )

    %{
      revenue_cents: round(totals.revenue),
      cogs_cents: round(totals.cogs),
      operating_expense_cents: round(totals.operating_expense),
      net_income_cents: round(totals.revenue - totals.cogs - totals.operating_expense),
      cash_in_cents: round(totals.cash_in),
      cash_out_cents: round(totals.cash_out),
      net_cash_cents: round(totals.cash_in - totals.cash_out)
    }
  end

  defp month_rows(months) do
    Enum.map(months, fn {date, totals} ->
      Map.merge(%{period_on: date, period_key: period_key(date)}, totals)
    end)
  end

  defp sum_months(months) do
    Enum.reduce(months, empty_totals(), fn {_date, totals}, acc ->
      Map.merge(acc, totals, fn _key, left, right -> left + right end)
    end)
  end

  defp empty_totals do
    %{
      revenue_cents: 0,
      cogs_cents: 0,
      operating_expense_cents: 0,
      net_income_cents: 0,
      cash_in_cents: 0,
      cash_out_cents: 0,
      net_cash_cents: 0
    }
  end

  defp bridge_row(line, actual, forecast) do
    variance = actual - forecast

    %{
      line: line,
      actual_cents: actual,
      forecast_cents: forecast,
      variance_cents: variance,
      pct: if(forecast == 0, do: nil, else: Float.round(variance / forecast * 100 * 1.0, 2))
    }
  end

  defp accuracy_pct(_abs_error, 0), do: nil

  defp accuracy_pct(abs_error, actual) do
    Float.round(max(0.0, 100.0 - abs_error / abs(actual) * 100.0), 2)
  end

  defp number(value) when is_integer(value), do: value * 1.0
  defp number(value) when is_float(value), do: value
  defp number(%Decimal{} = value), do: Decimal.to_float(value)
  defp number(_), do: 0.0

  # ── date helpers ──────────────────────────────────────────────────────────

  defp from_datetime(version), do: start_datetime(version.starts_on)
  defp to_datetime(version), do: end_datetime(version.ends_on)

  defp start_datetime(%Date{} = date), do: DateTime.new!(date, ~T[00:00:00], "Etc/UTC")

  defp end_datetime(%Date{} = date), do: DateTime.new!(date, ~T[23:59:59], "Etc/UTC")

  defp date(%Date{} = date), do: date
  defp date(%DateTime{} = datetime), do: DateTime.to_date(datetime)
  defp date(value) when is_binary(value), do: Date.from_iso8601!(value)

  defp period_key(date) do
    "#{date.year}-#{date.month |> Integer.to_string() |> String.pad_leading(2, "0")}"
  end
end
