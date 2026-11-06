defmodule Samen.Web.Finance.BoardPack do
  @moduledoc """
  The board reporting package's host seam (WS-ACCT Phase 13; ADR-054 D12).

  `Samen.Scopes.Finance.BoardPack` composes the ledger reads; this module
  answers the surface's questions: which fiscal period is showing, which
  close run belongs to it, and which host resources feed the reads. The
  period is the newest declared month (the board pack is a month-end
  artefact); its run is read org-scoped through the same mount the close
  dashboard uses.

  The package is read-only. There is no write path here, no PII projection,
  and the CSV egress is the same report data serialized through
  `Samen.Web.Csv` — the pixel and the download cannot diverge.
  """

  require Ash.Query

  alias Samen.Scopes.Finance.BoardPack, as: CoreBoardPack
  alias Samen.Web.Csv
  alias Samen.Web.Mount

  @columns [:section, :label, :value, :unit, :source]
  @appendix_limit 250

  @type state :: %{
          period: struct(),
          run: struct() | nil,
          report: CoreBoardPack.report(),
          task_wired?: boolean()
        }

  @doc "The exported package's bounded column allowlist."
  def columns, do: @columns

  @doc """
  Load the newest period's board package for `mount` + `org_id`.

  Returns `{:ok, %{period:, run:, report:, task_wired?:}}` or
  `{:error, :no_mount | :no_org | :no_period | :finance_not_mounted | term()}`.
  """
  @spec load(Mount.t() | nil, String.t() | nil) :: {:ok, state()} | {:error, term()}
  def load(%Mount{} = mount, org_id) when is_binary(org_id) do
    scope = Mount.scope(mount, org_id)

    with {:ok, period_mod} <- resource(mount, :FiscalPeriod),
         {:ok, run_mod} <- resource(mount, :CloseRun),
         {:ok, account} <- resource(mount, :Account),
         {:ok, line} <- resource(mount, :JournalLine),
         {:ok, entry} <- resource(mount, :JournalEntry),
         {:ok, posting_account} <- resource(mount, :PostingAccount),
         {:ok, period} <- latest_period(period_mod, scope) do
      run = latest_run(run_mod, period, scope)
      task = task_module(mount)
      variance = optional_resource(mount, :CostVariance)

      case CoreBoardPack.report(org_id, period.year, period.month,
             repo: mount.repo,
             account: account,
             line: line,
             entry: entry,
             posting_account: posting_account,
             variance: variance,
             period: period,
             run: run,
             task: task
           ) do
        {:ok, report} ->
          {:ok, %{period: period, run: run, report: report, task_wired?: task != nil}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def load(%Mount{}, _org_id), do: {:error, :no_org}
  def load(nil, _org_id), do: {:error, :no_mount}

  @doc """
  The package's CSV binary. The rows are the exec snapshot, statement totals,
  cash movement and the variance bridge/appendix — the same numbers the page
  renders, serialized through the framework's RFC-4180 + formula-neutralizing
  writer.
  """
  @spec csv(CoreBoardPack.report()) :: String.t()
  def csv(report) do
    [Enum.map(@columns, &to_string/1) | summary_rows(report) ++ variance_rows(report)]
    |> Csv.serialize()
  end

  # -- reads -----------------------------------------------------------------

  defp latest_period(period_mod, scope) do
    period_mod
    |> Ash.Query.sort(year: :desc, month: :desc)
    |> Ash.read(scope: scope)
    |> case do
      {:ok, [period | _]} -> {:ok, period}
      {:ok, []} -> {:error, :no_period}
      {:error, reason} -> {:error, reason}
    end
  end

  defp latest_run(run_mod, period, scope) do
    run_mod
    |> Ash.Query.filter(period_id == ^period.id)
    |> Ash.Query.sort(started_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read(scope: scope)
    |> case do
      {:ok, [run | _]} -> run
      _ -> nil
    end
  end

  defp resource(mount, name) do
    module = Mount.resource(mount, name)

    if Code.ensure_loaded?(module) do
      {:ok, module}
    else
      {:error, :finance_not_mounted}
    end
  end

  defp optional_resource(mount, name) do
    module = Mount.resource(mount, name)
    if Code.ensure_loaded?(module), do: module
  end

  defp task_module(%Mount{} = mount) do
    case Mount.label(mount, :work_namespace, nil) do
      namespace when is_atom(namespace) and not is_nil(namespace) ->
        task = Module.concat(namespace, :Task)
        if Code.ensure_loaded?(task), do: task

      _ ->
        nil
    end
  end

  # -- CSV rows --------------------------------------------------------------

  defp summary_rows(report) do
    exec = report.exec
    profit_loss = report.statements.profit_loss
    balance_sheet = report.statements.balance_sheet
    cash_flow = report.statements.cash_flow

    [
      row("exec", "Revenue", exec.revenue_cents, "cents", "ProfitLoss.generate/4"),
      row("exec", "Expenses", exec.expenses_cents, "cents", "ProfitLoss.generate/4"),
      row("exec", "Net income", exec.net_income_cents, "cents", "ProfitLoss.generate/4"),
      row("exec", "Total assets", exec.assets_cents, "cents", "BalanceSheet.generate/3"),
      row("exec", "Total liabilities", exec.liabilities_cents, "cents", "BalanceSheet.generate/3"),
      row("exec", "Total equity", exec.equity_cents, "cents", "BalanceSheet.generate/3"),
      row("exec", "Balance sheet balanced", exec.balanced?, "boolean", "BalanceSheet.generate/3"),
      row("exec", "Closing cash", exec.cash_cents, "cents", "CashFlow.statement/4"),
      row("exec", "Close completeness", exec.close_percent, "percent", "CloseBoard.report/2"),
      row("profit_loss", "Total revenue", profit_loss.total_revenue, "cents", "ProfitLoss.generate/4"),
      row("profit_loss", "Total expenses", profit_loss.total_expenses, "cents", "ProfitLoss.generate/4"),
      row("profit_loss", "Net income", profit_loss.net_income, "cents", "ProfitLoss.generate/4"),
      row("balance_sheet", "Total assets", balance_sheet.total_assets, "cents", "BalanceSheet.generate/3"),
      row("balance_sheet", "Total liabilities", balance_sheet.total_liabilities, "cents", "BalanceSheet.generate/3"),
      row("balance_sheet", "Total equity", balance_sheet.total_equity, "cents", "BalanceSheet.generate/3"),
      row("cash_flow", "Opening cash", cash_flow.opening_cents, "cents", "CashFlow.statement/4"),
      row("cash_flow", "Cash inflows", cash_flow.inflows_cents, "cents", "CashFlow.statement/4"),
      row("cash_flow", "Cash outflows", cash_flow.outflows_cents, "cents", "CashFlow.statement/4"),
      row("cash_flow", "Net cash movement", cash_flow.net_cents, "cents", "CashFlow.statement/4"),
      row("cash_flow", "Closing cash", cash_flow.closing_cents, "cents", "CashFlow.statement/4")
    ] ++
      Enum.map(report.variance_bridge.rows, fn bridge ->
        row("variance_bridge", bridge.type, bridge.variance_cents, "cents", "VarianceReport.for_period/3")
      end) ++
      [
        row("variance_bridge", "Net variance", report.variance_bridge.net_cents, "cents", "VarianceReport.for_period/3"),
        row("variance_bridge", "Labour basis", report.variance_bridge.labour_basis, "text", "VarianceReport.for_period/3")
      ]
  end

  defp variance_rows(report) do
    rows =
      report.variance_appendix
      |> Enum.take(@appendix_limit)
      |> Enum.map(fn row ->
        row(
          "variance_appendix",
          "#{row.type} #{row.cost_object_id}",
          row.variance_cents,
          "cents",
          "VarianceReport.for_period/3"
        )
      end)

    case length(report.variance_appendix) > @appendix_limit do
      true ->
        rows ++
          [
            row(
              "variance_appendix",
              "truncated",
              length(report.variance_appendix) - @appendix_limit,
              "rows omitted",
              "VarianceReport.for_period/3"
            )
          ]

      false ->
        rows
    end
  end

  defp row(section, label, value, unit, source) do
    [to_string(section), to_string(label), to_string(value), to_string(unit), to_string(source)]
  end
end
