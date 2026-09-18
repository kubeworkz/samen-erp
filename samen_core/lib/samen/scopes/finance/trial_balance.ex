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

  ## Fail-closed invariant

  If the trial balance does not balance (Σ ≠ 0), the report includes a
  `balanced: false` flag. This should never happen with a healthy ledger
  — it indicates a bypass of `UnbalancedEntry`.
  """

  @doc """
  Generate a trial balance for an org at a given timestamp.

  Returns `{:ok, %{accounts: [...], total_debits: int, total_credits: int, balanced: bool}}`.
  """
  def generate(org_id, as_of_date, opts) do
    repo = Keyword.fetch!(opts, :repo)
    account_resource = Keyword.fetch!(opts, :account_resource)
    line_resource = Keyword.fetch!(opts, :line_resource)

    account_table = AshPostgres.DataLayer.Info.table(account_resource)
    line_table = AshPostgres.DataLayer.Info.table(line_resource)

    # Get all accounts with their balances
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
    GROUP BY a.id, a.code, a.name, a.kind, a.normal_side
    ORDER BY a.code
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

  defp entry_table(line_table) do
    # The entry table is the line table minus the "_line" suffix
    String.replace(line_table, "_line", "_entry")
  end

  defp dump_uuid(nil), do: nil
  defp dump_uuid(id), do: Ecto.UUID.dump!(id)
end
