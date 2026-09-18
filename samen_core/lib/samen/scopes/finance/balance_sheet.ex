defmodule Samen.Scopes.Finance.BalanceSheet do
  @moduledoc """
  Balance Sheet report (WS-ERP E11; BigCapital-inspired financial statements).

  Groups accounts by kind (asset, liability, equity) and shows balances
  at a point in time. The balance sheet equation:

      Assets = Liabilities + Equity

  This must always hold — it's the fundamental accounting equation,
  enforced by the same R1 invariant that keeps the trial balance balanced.

  ## Design

  - **Assets** — accounts with `kind: :asset` (cash, receivables, inventory,
    equipment, etc.)
  - **Liabilities** — accounts with `kind: :liability` (payables, loans,
    accrued expenses, etc.)
  - **Equity** — accounts with `kind: :equity` (retained earnings, owner's
    equity, etc.)
  - **Net Income** — income minus expense (the P&L result for the period)
    is added to equity to balance the sheet

  The balance sheet is a point-in-time snapshot: balances are computed
  from all posted entries up to and including `as_of_date`.

  ## Fail-closed invariant

  If assets ≠ liabilities + equity (after adding net income), the report
  includes a `balanced: false` flag. This should never happen with a
  healthy ledger.
  """

  @doc """
  Generate a balance sheet for an org at a given date.

  Returns `{:ok, %{assets: [...], liabilities: [...], equity: [...],
  net_income: int, total_assets: int, total_liabilities_equity: int, balanced: bool}}`.
  """
  def generate(org_id, as_of_date, opts) do
    repo = Keyword.fetch!(opts, :repo)
    account_resource = Keyword.fetch!(opts, :account_resource)
    line_resource = Keyword.fetch!(opts, :line_resource)

    account_table = AshPostgres.DataLayer.Info.table(account_resource)
    line_table = AshPostgres.DataLayer.Info.table(line_resource)

    # Get all accounts with their balances at the point in time
    sql = """
    SELECT
      a.id,
      a.code,
      a.name,
      a.kind,
      a.normal_side,
      COALESCE(SUM(l.debit_cents - l.credit_cents), 0)::bigint AS balance
    FROM #{account_table} a
    LEFT JOIN #{line_table} l ON l.account_id = a.id
      AND l.entry_id IN (
        SELECT e.id FROM #{entry_table(line_table)} e
        WHERE e.status = 'posted' AND e.posted_at <= $2
      )
    WHERE a.org_id = $1
      AND a.kind IN ('asset', 'liability', 'equity')
    GROUP BY a.id, a.code, a.name, a.kind, a.normal_side
    ORDER BY a.code
    """

    # Get income and expense for net income calculation
    income_expense_sql = """
    SELECT
      a.kind,
      COALESCE(SUM(l.debit_cents - l.credit_cents), 0)::bigint AS balance
    FROM #{account_table} a
    LEFT JOIN #{line_table} l ON l.account_id = a.id
      AND l.entry_id IN (
        SELECT e.id FROM #{entry_table(line_table)} e
        WHERE e.status = 'posted' AND e.posted_at <= $2
      )
    WHERE a.org_id = $1
      AND a.kind IN ('income', 'expense')
    GROUP BY a.kind
    """

    with {:ok, %{rows: account_rows}} <- repo.query(sql, [dump_uuid(org_id), as_of_date]),
         {:ok, %{rows: ie_rows}} <- repo.query(income_expense_sql, [dump_uuid(org_id), as_of_date]) do
      accounts =
        Enum.map(account_rows, fn [id, code, name, kind, normal_side, balance] ->
          %{
            id: id,
            code: code,
            name: name,
            kind: String.to_atom(kind),
            normal_side: String.to_atom(normal_side),
            balance: balance
          }
        end)

      # Calculate net income: income (credit-normal, so negative balance = revenue)
      # minus expense (debit-normal, so positive balance = expense)
      income_balance =
        ie_rows
        |> Enum.find(fn [kind, _] -> kind == "income" end)
        |> case do
          [_, balance] -> abs(balance)
          nil -> 0
        end

      expense_balance =
        ie_rows
        |> Enum.find(fn [kind, _] -> kind == "expense" end)
        |> case do
          [_, balance] -> balance
          nil -> 0
        end

      net_income = income_balance - expense_balance

      assets = Enum.filter(accounts, &(&1.kind == :asset))
      liabilities = Enum.filter(accounts, &(&1.kind == :liability))
      equity = Enum.filter(accounts, &(&1.kind == :equity))

      total_assets = Enum.reduce(assets, 0, fn a, acc -> acc + a.balance end)
      total_liabilities = Enum.reduce(liabilities, 0, fn a, acc -> acc + a.balance end)
      total_equity = Enum.reduce(equity, 0, fn a, acc -> acc + a.balance end) + net_income

      {:ok,
       %{
         assets: assets,
         liabilities: liabilities,
         equity: equity,
         net_income: net_income,
         total_assets: total_assets,
         total_liabilities: total_liabilities,
         total_equity: total_equity,
         balanced: total_assets == total_liabilities + total_equity,
         as_of_date: as_of_date
       }}
    end
  end

  defp entry_table(line_table) do
    String.replace(line_table, "_line", "_entry")
  end

  defp dump_uuid(nil), do: nil
  defp dump_uuid(id), do: Ecto.UUID.dump!(id)
end
