defmodule Samen.Scopes.Finance.TrialBalance do
  @moduledoc """
  Trial Balance report (WS-ERP E11; BigCapital-inspired financial statements).

  Lists every account in the Chart of Accounts with its balance
  (Σ debit_cents − Σ credit_cents over posted lines). The trial balance
  is the foundation for the Balance Sheet and P&L — both are grouped
  views of the same data.

  ## Design

  - All accounts are listed, grouped by `kind` (asset, liability, equity,
    income, expense)
  - Each account shows its balance as signed integer cents
  - The trial balance MUST balance: Σ debit balances = Σ credit balances
    (the R1 invariant — every posted entry is balanced, so the org-wide
    sum is zero)
  - This is a pure read — no DB writes, no side effects

  ## Physical names come from the resources

  The read is SQL, so every table/column is resolved from the passed resources
  (`Samen.Scopes.Finance.ReportColumns`) rather than hardcoded: a host's
  columns are abbrev-prefixed (`ecl_account_id`), and a bare `account_id`
  would parse in a fixture and fail on the real table.

  ## Fail-closed invariant

  If the trial balance does not balance (Σ ≠ 0), the report includes a
  `balanced: false` flag. This should never happen with a healthy ledger
  — it indicates a bypass of `UnbalancedEntry`.
  """

  alias Samen.Scopes.Finance.ReportColumns

  @doc """
  Generate a trial balance for an org at a given timestamp.

  `opts` requires `:repo`, `:account_resource`, `:line_resource`, and
  `:entry_resource` (the entry the lines belong to; its columns are resolved
  like the others).

  Returns `{:ok, %{accounts: [...], total_debits: int, total_credits: int, balanced: bool}}`.
  """
  def generate(org_id, as_of_date, opts) do
    repo = Keyword.fetch!(opts, :repo)
    account_resource = Keyword.fetch!(opts, :account_resource)
    line_resource = Keyword.fetch!(opts, :line_resource)
    entry_resource = Keyword.fetch!(opts, :entry_resource)

    account_table = ReportColumns.table(account_resource)
    line_table = ReportColumns.table(line_resource)
    entry_table = ReportColumns.table(entry_resource)

    # Get all accounts with their balances
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
    GROUP BY
      a.#{ReportColumns.column(account_resource, :id)},
      a.#{ReportColumns.column(account_resource, :code)},
      a.#{ReportColumns.column(account_resource, :name)},
      a.#{ReportColumns.column(account_resource, :kind)},
      a.#{ReportColumns.column(account_resource, :normal_side)}
    ORDER BY a.#{ReportColumns.column(account_resource, :code)}
    """

    case repo.query(sql, [dump_uuid(org_id), as_of_date]) do
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

        total_debits = Enum.reduce(accounts, 0, fn a, acc -> acc + max(a.balance, 0) end)
        total_credits = Enum.reduce(accounts, 0, fn a, acc -> acc + abs(min(a.balance, 0)) end)

        {:ok,
         %{
           accounts: accounts,
           total_debits: total_debits,
           total_credits: total_credits,
           balanced: total_debits == total_credits,
           as_of_date: as_of_date
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp dump_uuid(nil), do: nil
  defp dump_uuid(id), do: Ecto.UUID.dump!(id)
end
