defmodule Samen.Scopes.Finance.ProfitLoss do
  @moduledoc """
  Profit & Loss (Income Statement) report (WS-ERP E11; BigCapital-inspired
  financial statements).

  Shows income and expense accounts for a period, computing net income
  (revenue − expenses). The P&L is a period statement, not a point-in-time
  snapshot like the Balance Sheet.

  ## Design

  - **Revenue** — accounts with `kind: :income` (sales, service revenue,
    interest income, etc.)
  - **Expenses** — accounts with `kind: :expense` (cost of goods, rent,
    salaries, depreciation, etc.)
  - **Net Income** = Σ revenue − Σ expenses

  The P&L feeds into the Balance Sheet's equity section (retained earnings
  += net income for the period).

  ## Period

  The P&L covers a date range (`from_date` to `to_date`). Only posted
  entries within this range are included, filtered on the entry's
  `posted_at` — the ledger's own time axis, not the document date.

  ## Physical names come from the resources

  The read is SQL, so every table/column is resolved from the passed resources
  (`Samen.Scopes.Finance.ReportColumns`) — a host's columns are abbrev-prefixed.

  ## Fail-closed invariant

  This is a pure read — no writes, no side effects. The report is
  deterministic: the same inputs always produce the same output.
  """

  alias Samen.Scopes.Finance.ReportColumns

  @doc """
  Generate a P&L for an org for a given period.

  `opts` requires `:repo`, `:account_resource`, `:line_resource`, and
  `:entry_resource`.

  Returns `{:ok, %{revenue: [...], expenses: [...], total_revenue: int,
  total_expenses: int, net_income: int, from_date, to_date}}`.
  """
  def generate(org_id, from_date, to_date, opts) do
    repo = Keyword.fetch!(opts, :repo)
    account_resource = Keyword.fetch!(opts, :account_resource)
    line_resource = Keyword.fetch!(opts, :line_resource)
    entry_resource = Keyword.fetch!(opts, :entry_resource)

    account_table = ReportColumns.table(account_resource)
    line_table = ReportColumns.table(line_resource)
    entry_table = ReportColumns.table(entry_resource)

    # Get income and expense accounts with their period balances
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
      AND l.#{ReportColumns.column(line_resource, :org_id)} = $1
      AND l.#{ReportColumns.column(line_resource, :entry_id)} IN (
        SELECT e.#{ReportColumns.column(entry_resource, :id)} FROM #{entry_table} e
        WHERE e.#{ReportColumns.column(entry_resource, :org_id)} = $1
          AND e.#{ReportColumns.column(entry_resource, :status)} = 'posted'
          AND e.#{ReportColumns.column(entry_resource, :posted_at)} >= $2
          AND e.#{ReportColumns.column(entry_resource, :posted_at)} <= $3
      )
    WHERE a.#{ReportColumns.column(account_resource, :org_id)} = $1
      AND a.#{ReportColumns.column(account_resource, :kind)} IN ('income', 'expense')
    GROUP BY
      a.#{ReportColumns.column(account_resource, :id)},
      a.#{ReportColumns.column(account_resource, :code)},
      a.#{ReportColumns.column(account_resource, :name)},
      a.#{ReportColumns.column(account_resource, :kind)},
      a.#{ReportColumns.column(account_resource, :normal_side)}
    ORDER BY a.#{ReportColumns.column(account_resource, :code)}
    """

    case repo.query(sql, [dump_uuid(org_id), from_date, to_date]) do
      {:ok, %{rows: rows}} ->
        accounts =
          Enum.map(rows, fn [id, code, name, kind, normal_side, balance] ->
            %{
              id: id,
              code: code,
              name: name,
              kind: String.to_atom(kind),
              normal_side: String.to_atom(normal_side),
              balance: balance
            }
          end)

        # Revenue: income accounts (credit-normal, so negative balance = revenue)
        revenue = Enum.filter(accounts, &(&1.kind == :income))
        total_revenue = Enum.reduce(revenue, 0, fn a, acc -> acc + abs(a.balance) end)

        # Expenses: expense accounts (debit-normal, so positive balance = expense)
        expenses = Enum.filter(accounts, &(&1.kind == :expense))
        total_expenses = Enum.reduce(expenses, 0, fn a, acc -> acc + a.balance end)

        net_income = total_revenue - total_expenses

        {:ok,
         %{
           revenue: revenue,
           expenses: expenses,
           total_revenue: total_revenue,
           total_expenses: total_expenses,
           net_income: net_income,
           from_date: from_date,
           to_date: to_date
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp dump_uuid(nil), do: nil
  defp dump_uuid(id), do: Ecto.UUID.dump!(id)
end
