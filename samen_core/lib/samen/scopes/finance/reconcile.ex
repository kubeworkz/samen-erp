defmodule Samen.Scopes.Finance.Reconcile do
  @moduledoc """
  The R1 read mirror (WS-ERP E1; ADR-049 §2, decision 7): every balance is the
  SUM of its account's lines — there is no cached balance column to trust, so
  the reconciliation IS the read.

  * `account_balance/3` — one account's balance as signed integer cents
    (debit-positive, credit-negative; income/credit-normal accounts therefore
    read negative, which is the double-entry convention, not a bug).
  * `org_balance/2` — the org-wide signed sum. R1 says this is ZERO, always
    (every posted entry is balanced, so the org-wide net of all lines is zero).

  Both are bare SQL sums over the line table — the read mirror of
  `Samen.Scopes.Finance.UnbalancedEntry`'s write-side check. The reconciliation
  red-path suite (`Samen.FinanceScopeTest`) proves org_balance == 0 on a seeded
  ledger and that a bypass (an unbalanced entry forced into the table below the
  guard) makes it DIVERGE — the anti-tautology: the sum is load-bearing.

  The entry/line resources are passed per mount (the ADR-004 pattern — a scope
  is materialized per host namespace, so no module name is hard-coded here):

      Samen.Scopes.Finance.Reconcile.org_balance(org_id, repo,
        line_resource: Demo.FinanceScope.JournalLine
      )
  """

  @doc """
  One account's balance in signed integer cents: `Σ debit_cents − Σ credit_cents`
  over the account's POSTED lines only (a draft is not yet a fact; a void's
  reversing pair nets out naturally).
  """
  def account_balance(account_id, repo, opts) do
    line_resource = Keyword.fetch!(opts, :line_resource)

    table = AshPostgres.DataLayer.Info.table(line_resource)
    acct = attr_source(line_resource, :account_id)
    debit = attr_source(line_resource, :debit_cents)
    credit = attr_source(line_resource, :credit_cents)
    posted_join = posted_join_sql(line_resource)

    sql = """
    SELECT COALESCE(SUM(l.#{debit} - l.#{credit}), 0)::bigint
    FROM #{table} l
    #{posted_join}
    WHERE l.#{acct} = $1
    """

    case repo.query(sql, [dump_uuid(account_id)]) do
      {:ok, %{rows: [[balance]]}} -> {:ok, balance}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  The org-wide signed sum over ALL lines (posted entries only). R1: this is
  zero, always. Non-zero is a broken ledger.
  """
  def org_balance(org_id, repo, opts) do
    line_resource = Keyword.fetch!(opts, :line_resource)

    table = AshPostgres.DataLayer.Info.table(line_resource)
    org = attr_source(line_resource, :org_id)
    debit = attr_source(line_resource, :debit_cents)
    credit = attr_source(line_resource, :credit_cents)
    posted_join = posted_join_sql(line_resource)

    sql = """
    SELECT COALESCE(SUM(l.#{debit} - l.#{credit}), 0)::bigint
    FROM #{table} l
    #{posted_join}
    WHERE l.#{org} = $1
    """

    case repo.query(sql, [dump_uuid(org_id)]) do
      {:ok, %{rows: [[balance]]}} -> {:ok, balance}
      {:error, reason} -> {:error, reason}
    end
  end

  # Restrict the sum to lines whose ENTRY is posted (a draft's lines are staged
  # intentions, not facts; a voided entry keeps its lines — the reversing entry
  # nets them). Joins the entry table on the line's belongs_to :entry FK, whose
  # destination is resolved from the line resource itself (no hard-coded module).
  defp posted_join_sql(line_resource) do
    entry_resource = entry_resource(line_resource)

    entry_table = AshPostgres.DataLayer.Info.table(entry_resource)
    entry_pk = attr_source(entry_resource, :id)
    entry_status = attr_source(entry_resource, :status)
    line_entry_fk = line_entry_fk_source(line_resource, entry_resource)

    "JOIN #{entry_table} e ON e.#{entry_pk} = l.#{line_entry_fk} " <>
      "AND e.#{entry_status} = 'posted'"
  end

  defp entry_resource(line_resource) do
    line_resource
    |> Ash.Resource.Info.relationships()
    |> Enum.find(&(&1.type == :belongs_to and &1.name == :entry))
    |> Map.fetch!(:destination)
  end

  defp line_entry_fk_source(line_resource, entry_resource) do
    line_resource
    |> Ash.Resource.Info.relationships()
    |> Enum.find(&(&1.type == :belongs_to and &1.destination == entry_resource))
    |> Map.fetch!(:source_attribute)
    |> then(&attr_source(line_resource, &1))
  end

  defp attr_source(resource, name) do
    case Ash.Resource.Info.attribute(resource, name) do
      nil -> nil
      attr -> to_string(attr.source || attr.name)
    end
  end

  defp dump_uuid(value) when is_binary(value) and byte_size(value) == 16, do: value

  defp dump_uuid(value) do
    case Ecto.UUID.dump(value) do
      {:ok, bin} -> bin
      :error -> value
    end
  end
end
