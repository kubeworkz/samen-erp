defmodule Samen.Scopes.Finance.BoardPack do
  @moduledoc """
  The board reporting package (WS-ACCT Phase 13; ADR-054 D12).

  The package is a **read of reads**: every number comes from an existing
  ledger or rollup read, never from a hand-entered sheet.

    * condensed profit & loss — `Samen.Scopes.Finance.ProfitLoss`;
    * balance sheet — `Samen.Scopes.Finance.BalanceSheet`;
    * cash flow — `Samen.Scopes.Finance.CashFlow` (the host's `:cash`
      posting accounts);
    * runway — `Samen.Scopes.Finance.ForecastRead` (the latest published
      forecast version, when the host supplies one);
    * variance bridge and appendix — `Samen.Scopes.Finance.VarianceReport`;
    * close status — `Samen.Scopes.Finance.CloseBoard`.

  The exec snapshot and KPI block only restate those reads (net income,
  operating margin, mapped EBITDA addbacks, cash movement, close
  completeness). The `:sources` list names the read behind every section, so
  the surface can show its own provenance.

  Narrative pages (risks, opportunities, board asks, resolutions) are
  authored documents by decision D12 and are deliberately not generated here.

  ## Honest absence

  A host without the `:cash` posting map gets `mapped?: false` and zero
  amounts, never a guessed account. A host without the variance resource gets
  an empty bridge with `labour_basis: :unavailable`; a month with no close run
  gets `close: nil`. The page renders those absences rather than a fabricated
  green state.
  """

  require Ash.Query

  alias Samen.Scopes.Finance.{
    BalanceSheet,
    CashFlow,
    CloseBoard,
    ForecastRead,
    ProfitLoss,
    VarianceReport
  }

  @addback_keys [:amortization_expense, :depreciation_expense]

  @type report :: %{
          period_key: String.t(),
          period: map(),
          generated_at: DateTime.t(),
          exec: map(),
          kpis: map(),
          statements: map(),
          variance_bridge: map(),
          variance_appendix: [map()],
          runway: map() | nil,
          close: map() | nil,
          traffic_lights: [map()],
          sources: [map()]
        }

  @doc """
  Build the report for `{org_id, year, month}`.

  Required opts: `:repo`, `:account`, `:line`, `:entry`, `:posting_account`.
  Optional: `:period`, `:run`, `:task` (the Work Task module), `:variance`
  (the `CostVariance` module; absent means the variance section is
  unavailable), and `:forecast`/`:forecast_driver` (a published
  `ForecastVersion` and its driver module; absent means runway is
  unavailable).
  """
  @spec report(String.t(), integer(), integer(), keyword()) ::
          {:ok, report()} | {:error, term()}
  def report(org_id, year, month, opts) do
    repo = Keyword.fetch!(opts, :repo)
    account = Keyword.fetch!(opts, :account)
    line = Keyword.fetch!(opts, :line)
    entry = Keyword.fetch!(opts, :entry)
    posting_account = Keyword.fetch!(opts, :posting_account)

    period = Keyword.get(opts, :period)
    run = Keyword.get(opts, :run)
    task = Keyword.get(opts, :task)
    variance_mod = Keyword.get(opts, :variance)

    {from_date, to_date} = boundaries(year, month)

    statement_opts = [
      repo: repo,
      account_resource: account,
      line_resource: line,
      entry_resource: entry
    ]

    with {:ok, profit_loss} <- ProfitLoss.generate(org_id, from_date, to_date, statement_opts),
         {:ok, balance_sheet} <- BalanceSheet.generate(org_id, to_date, statement_opts),
         {:ok, cash_flow} <-
           CashFlow.statement(org_id, from_date, to_date,
             repo: repo,
             posting_account: posting_account,
             line: line,
             entry: entry
           ) do
      variance = variance_report(org_id, year, month, variance_mod)
      close = close_report(run, task, period)

      runway =
        forecast_runway(
          org_id,
          Keyword.get(opts, :forecast),
          Keyword.get(opts, :forecast_driver),
          opts
        )

      exec = exec_snapshot(profit_loss, balance_sheet, cash_flow, close)
      kpis = kpis(profit_loss, cash_flow, close, posting_account, org_id)

      {:ok,
       %{
         period_key: period_key(year, month),
         period: period_view(period, year, month),
         generated_at: DateTime.utc_now(),
         exec: exec,
         kpis: kpis,
         statements: %{
           profit_loss: profit_loss,
           balance_sheet: balance_sheet,
           cash_flow: cash_flow
         },
         variance_bridge: variance_bridge(variance, year, month),
         variance_appendix: variance.rows,
         runway: runway,
         close: close,
         traffic_lights: traffic_lights(balance_sheet, cash_flow, close, variance),
         sources:
           [
             %{section: "Profit & loss", read: "ProfitLoss.generate/4"},
             %{section: "Balance sheet", read: "BalanceSheet.generate/3"},
             %{section: "Cash flow", read: "CashFlow.statement/4"},
             %{section: "Variance", read: "VarianceReport.for_period/3"},
             %{section: "Close", read: "CloseBoard.report/2"}
           ] ++ runway_sources(runway)
       }}
    end
  end

  defp boundaries(year, month) do
    first = Date.new!(year, month, 1)
    last = Date.end_of_month(first)

    {
      DateTime.new!(first, ~T[00:00:00], "Etc/UTC"),
      DateTime.new!(last, ~T[23:59:59], "Etc/UTC")
    }
  end

  defp variance_report(_org_id, year, month, nil) do
    %{
      period_key: period_key(year, month),
      rows: [],
      totals: %{by_type: %{}, net_cents: 0},
      labour_basis: :unavailable
    }
  end

  defp variance_report(org_id, year, month, variance_mod) do
    VarianceReport.for_period(org_id, period_key(year, month), variance: variance_mod)
  end

  defp close_report(nil, _task, _period), do: nil

  defp close_report(run, task, period) do
    CloseBoard.report(run, task: task, period: period)
  end

  defp forecast_runway(_org_id, nil, _driver, _opts), do: nil
  defp forecast_runway(_org_id, _version, nil, _opts), do: nil

  defp forecast_runway(org_id, version, driver, opts) do
    read =
      ForecastRead.runway(version,
        org_id: org_id,
        driver: driver,
        repo: Keyword.fetch!(opts, :repo),
        posting_account: Keyword.fetch!(opts, :posting_account),
        line: Keyword.fetch!(opts, :line),
        entry: Keyword.fetch!(opts, :entry)
      )

    # The read reports `mapped?: false` when the host has no `:cash` posting
    # account. A zero-cents runway from that read is an absence, not a result.
    status = if read.mapped?, do: read.status, else: :unmapped

    Map.merge(read, %{
      status: status,
      version_name: version.name,
      version_number: version.version,
      starts_on: version.starts_on,
      ends_on: version.ends_on,
      published_at: version.published_at
    })
  end

  defp runway_sources(nil), do: []
  defp runway_sources(runway), do: [%{section: "Runway", read: runway.source}]

  defp exec_snapshot(profit_loss, balance_sheet, cash_flow, close) do
    %{
      revenue_cents: profit_loss.total_revenue,
      expenses_cents: profit_loss.total_expenses,
      net_income_cents: profit_loss.net_income,
      assets_cents: balance_sheet.total_assets,
      liabilities_cents: balance_sheet.total_liabilities,
      equity_cents: balance_sheet.total_equity,
      balanced?: balance_sheet.balanced,
      cash_cents: cash_flow.closing_cents,
      close_percent: close && close.completeness.percent,
      close_complete?: close != nil and close.completeness.complete?
    }
  end

  defp kpis(profit_loss, cash_flow, close, posting_account, org_id) do
    addbacks = ebitda_addbacks(profit_loss, posting_account, org_id)

    %{
      revenue_cents: profit_loss.total_revenue,
      expenses_cents: profit_loss.total_expenses,
      net_income_cents: profit_loss.net_income,
      operating_margin_pct: pct(profit_loss.net_income, profit_loss.total_revenue),
      ebitda_cents: profit_loss.net_income + addbacks,
      ebitda_basis: if(addbacks == 0, do: :no_mapped_addbacks, else: :mapped_addbacks),
      cash_closing_cents: cash_flow.closing_cents,
      cash_net_cents: cash_flow.net_cents,
      close_percent: close && close.completeness.percent
    }
  end

  # EBITDA is only quoted from the host's own posting map: net income plus the
  # mapped amortization/depreciation expense accounts. A host that has not
  # mapped either gets the net-income basis, named as such.
  defp ebitda_addbacks(profit_loss, posting_account, org_id) do
    account_ids =
      posting_account
      |> Ash.Query.filter(org_id == ^org_id)
      |> Ash.read!(authorize?: false)
      |> Enum.filter(&(&1.key in @addback_keys))
      |> MapSet.new(& &1.account_id)

    if MapSet.size(account_ids) == 0 do
      0
    else
      profit_loss.expenses
      |> Enum.filter(&MapSet.member?(account_ids, &1.id))
      |> Enum.reduce(0, &(&1.balance + &2))
    end
  end

  defp pct(_value, 0), do: nil

  defp pct(value, base) do
    Float.round(value / base * 100 * 1.0, 2)
  end

  defp variance_bridge(variance, year, month) do
    rows =
      variance.totals.by_type
      |> Enum.map(fn {type, cents} ->
        %{
          type: type,
          variance_cents: cents,
          favourability: if(cents > 0, do: :unfavourable, else: :favourable)
        }
      end)
      |> Enum.sort_by(& &1.type)

    %{
      period_key: period_key(year, month),
      rows: rows,
      net_cents: variance.totals.net_cents,
      labour_basis: variance.labour_basis
    }
  end

  defp traffic_lights(balance_sheet, cash_flow, close, variance) do
    [
      %{
        key: :statements,
        label: "Balance sheet",
        status: if(balance_sheet.balanced, do: :green, else: :red),
        detail:
          if(balance_sheet.balanced,
            do: "assets equal liabilities plus equity",
            else: "the sheet does not balance"
          )
      },
      %{
        key: :cash,
        label: "Cash mapping",
        status: if(cash_flow.mapped?, do: :green, else: :grey),
        detail:
          if(cash_flow.mapped?,
            do: "cash movement is ledger-derived",
            else: "no :cash posting account is mapped"
          )
      },
      %{
        key: :close,
        label: "Close run",
        status:
          cond do
            is_nil(close) -> :grey
            close.completeness.complete? -> :green
            true -> :amber
          end,
        detail:
          cond do
            is_nil(close) -> "no close run is recorded"
            close.completeness.complete? -> "every phase is signed and its task is closed"
            true -> "#{close.completeness.done}/#{close.completeness.total} phases done"
          end
      },
      %{
        key: :variance,
        label: "Variance",
        status:
          cond do
            variance.rows == [] -> :grey
            variance.totals.net_cents <= 0 -> :green
            true -> :amber
          end,
        detail:
          if(variance.rows == [],
            do: "no variance rows recorded",
            else: "net #{variance.totals.net_cents} cents"
          )
      }
    ]
  end

  defp period_view(nil, year, month), do: %{id: nil, year: year, month: month, status: nil}

  defp period_view(period, year, month) do
    %{
      id: Map.get(period, :id),
      year: Map.get(period, :year) || year,
      month: Map.get(period, :month) || month,
      status: Map.get(period, :status)
    }
  end

  defp period_key(year, month) do
    "#{year}-#{month |> Integer.to_string() |> String.pad_leading(2, "0")}"
  end
end
