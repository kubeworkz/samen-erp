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

  ## Signs

  A balance is `Σ(debit_cents − credit_cents)`, so assets and expenses are
  positive and liabilities, equity and income are negative. The report keeps
  those signed balances on the rows (the ledger's own convention) and flips
  the liability/equity totals once, so a caller never has to remember which
  side of the sheet it is holding — `assets == liabilities + equity` compares
  like with like, including the net income added to equity.

  ## Physical names come from the resources

  The read is SQL, so every table/column is resolved from the passed resources
  (`Samen.Scopes.Finance.ReportColumns`) — a host's columns are abbrev-prefixed.

  ## Fail-closed invariant

  If assets ≠ liabilities + equity (after adding net income), the report
  includes a `balanced: false` flag. This should never happen with a
  healthy ledger.
  """

  alias Samen.Scopes.Finance.ReportColumns

  @doc """
  Generate a balance sheet for an org at a given date.

  `opts` requires `:repo`, `:account_resource`, `:line_resource`, and
  `:entry_resource`.

  Returns `{:ok, %{assets: [...], liabilities: [...], equity: [...],
  net_income: int, total_assets: int, total_liabilities: int, total_equity: int,
  balanced: bool}}`.
  """
  def generate(org_id, as_of_date, opts) do
    repo = Keyword.fetch!(opts, :repo)
    account_resource = Keyword.fetch!(opts, :account_resource)
    line_resource = Keyword.fetch!(opts, :line_resource)
    entry_resource = Keyword.fetch!(opts, :entry_resource)

    account_table = ReportColumns.table(account_resource)
    line_table = ReportColumns.table(line_resource)
    entry_table = ReportColumns.table(entry_resource)

    # Get all accounts with their balances at the point in time
    sql = """
    SELECT
      a.#{ReportColumns.column(account_resource, :id)} AS id,
      a.#{ReportColumns.column(account_resource, :code)} AS code,
      a.#{ReportColumns.column(account_resource, :name)} AS name,
      a.#{ReportColumns.column(account_resource, :kind)} AS kind,
      a.#{ReportColumns.column(account_resource, :normal_side)} AS normal_side,
      COALESCE(SUM(l.#{ReportColumns.column(line_resource, :debit_cents)} -
                  l.#{ReportColumns.column(line_resource, :credit_cents)}), 0)::bigint AS balance
    FROM #{account_table} a
    LEFT JOIN #{line_table} l
      ON l.#{ReportColumns.column(line_resource, :account_id)} =
         a.#{ReportColumns.column(account_resource, :id)}
      AND l.#{ReportColumns.column(line_resource, :entry_id)} IN (
        SELECT e.#{ReportColumns.column(entry_resource, :id)} FROM #{entry_table} e
        WHERE e.#{ReportColumns.column(entry_resource, :status)} = 'posted'
          AND e.#{ReportColumns.column(entry_resource, :posted_at)} <= $2
      )
    WHERE a.#{ReportColumns.column(account_resource, :org_id)} = $1
      AND a.#{ReportColumns.column(account_resource, :kind)} IN ('asset', 'liability', 'equity')
    GROUP BY
      a.#{ReportColumns.column(account_resource, :id)},
      a.#{ReportColumns.column(account_resource, :code)},
      a.#{ReportColumns.column(account_resource, :name)},
      a.#{ReportColumns.column(account_resource, :kind)},
      a.#{ReportColumns.column(account_resource, :normal_side)}
    ORDER BY a.#{ReportColumns.column(account_resource, :code)}
    """

    # Get income and expense for net income calculation
    income_expense_sql = """
    SELECT
      a.#{ReportColumns.column(account_resource, :kind)} AS kind,
      COALESCE(SUM(l.#{ReportColumns.column(line_resource, :debit_cents)} -
                  l.#{ReportColumns.column(line_resource, :credit_cents)}), 0)::bigint AS balance
    FROM #{account_table} a
    LEFT JOIN #{line_table} l
      ON l.#{ReportColumns.column(line_resource, :account_id)} =
         a.#{ReportColumns.column(account_resource, :id)}
      AND l.#{ReportColumns.column(line_resource, :entry_id)} IN (
        SELECT e.#{ReportColumns.column(entry_resource, :id)} FROM #{entry_table} e
        WHERE e.#{ReportColumns.column(entry_resource, :status)} = 'posted'
          AND e.#{ReportColumns.column(entry_resource, :posted_at)} <= $2
      )
    WHERE a.#{ReportColumns.column(account_resource, :org_id)} = $1
      AND a.#{ReportColumns.column(account_resource, :kind)} IN ('income', 'expense')
    GROUP BY a.#{ReportColumns.column(account_resource, :kind)}
    """

    with {:ok, %{rows: account_rows}} <- repo.query(sql, [dump_uuid(org_id), as_of_date]),
         {:ok, %{rows: ie_rows}} <-
           repo.query(income_expense_sql, [dump_uuid(org_id), as_of_date]) do
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

      # Income is credit-normal (negative balance = revenue); expense is
      # debit-normal (positive balance = expense).
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

      # Liabilities/equity carry credit-normal (negative) balances; flip them
      # to the sheet's presentation sign.
      total_liabilities = Enum.reduce(liabilities, 0, fn a, acc -> acc - a.balance end)
      contributed_equity = Enum.reduce(equity, 0, fn a, acc -> acc - a.balance end)
      total_equity = contributed_equity + net_income

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

  defp dump_uuid(nil), do: nil
  defp dump_uuid(id), do: Ecto.UUID.dump!(id)
end
