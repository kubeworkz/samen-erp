defmodule Samen.Scopes.Finance.BudgetVsActual do
  @moduledoc """
  Budget-vs-actual (WS-ERP E8; design §2.1 + §6.2): a PURE READ over the
  posted journal lines vs the budget lines — never a stored column, never a
  new mechanism (design §6.2: "rollups + floors, never a new mechanism";
  §2.1: "budget-vs-actual = a pure function over rollup vs BudgetLine").

  For every budget line (account, planned_cents) the read reports:

    * `planned_cents` — the plan magnitude (BudgetLine).
    * `actual_cents`  — the account's POSTED activity within the budget's
      period year, signed TOWARD the account's normal side: a debit-normal
      account reads Σ debits − Σ credits; a credit-normal account reads
      Σ credits − Σ debits. A positive actual is "activity in the planned
      direction" for both — the variance math is uniform.
    * `variance_cents` = actual − planned (positive = over plan).
    * `pct` = variance / planned × 100 (nil when planned is 0 — never a
      fabricated division).

  The sums are bare SQL over the line table restricted to POSTED entries
  within [Jan 1, Dec 31] of the budget's year — the `Reconcile` read-mirror
  discipline (no cached column is trusted; there is no cached column). The
  entry-status filter reuses the Reconcile's entry-table join resolution from
  the line resource (no hard-coded module).

  Caller passes its mount's resources per the ADR-004 pattern:

      BudgetVsActual.read(org_id, budget, repo,
        budget_line_resource: ..., journal_line_resource: ..., account_resource: ...
      )
  """

  def read(org_id, budget, repo, opts) do
    line_resource = Keyword.fetch!(opts, :budget_line_resource)
    journal_line = Keyword.fetch!(opts, :journal_line_resource)
    account_resource = Keyword.fetch!(opts, :account_resource)
    year = budget.period

    line_table = AshPostgres.DataLayer.Info.table(line_resource)
    line_budget = attr_source(line_resource, :budget_id)
    line_account = attr_source(line_resource, :account_id)
    line_planned = attr_source(line_resource, :planned_cents)
    line_org = attr_source(line_resource, :org_id)

    acct_table = AshPostgres.DataLayer.Info.table(account_resource)
    acct_pk = attr_source(account_resource, :id)
    acct_side = attr_source(account_resource, :normal_side)
    acct_code = attr_source(account_resource, :code)
    acct_name = attr_source(account_resource, :name)
    acct_org = attr_source(account_resource, :org_id)

    jl_table = AshPostgres.DataLayer.Info.table(journal_line)
    jl_account = attr_source(journal_line, :account_id)
    jl_org = attr_source(journal_line, :org_id)
    jl_debit = attr_source(journal_line, :debit_cents)
    jl_credit = attr_source(journal_line, :credit_cents)
    jl_entry_fk = entry_fk_source(journal_line)

    entry_table = AshPostgres.DataLayer.Info.table(entry_resource(journal_line))
    entry_pk = attr_source(entry_resource(journal_line), :id)
    entry_status = attr_source(entry_resource(journal_line), :status)
    entry_date = attr_source(entry_resource(journal_line), :entry_date)

    sql = """
    SELECT
      a.#{acct_code},
      a.#{acct_name},
      a.#{acct_side}::text,
      l.#{line_planned}::bigint,
      COALESCE(actuals.actual_cents, 0)::bigint
    FROM #{line_table} l
    JOIN #{acct_table} a
      ON a.#{acct_pk} = l.#{line_account} AND a.#{acct_org} = l.#{line_org}
    LEFT JOIN (
      SELECT jl.#{jl_account} AS account_id,
             SUM(
               CASE WHEN a2.#{acct_side} = 'debit'
                    THEN jl.#{jl_debit} - jl.#{jl_credit}
                    ELSE jl.#{jl_credit} - jl.#{jl_debit}
               END
             ) AS actual_cents
      FROM #{jl_table} jl
      JOIN #{acct_table} a2 ON a2.#{acct_pk} = jl.#{jl_account}
      JOIN #{entry_table} e
        ON e.#{entry_pk} = jl.#{jl_entry_fk}
       AND e.#{entry_status} = 'posted'
       AND e.#{entry_date} >= make_date($2, 1, 1)
       AND e.#{entry_date} <= make_date($2, 12, 31)
      WHERE jl.#{jl_org} = $1
      GROUP BY jl.#{jl_account}
    ) actuals ON actuals.account_id = l.#{line_account}
    WHERE l.#{line_org} = $1 AND l.#{line_budget} = $3
    ORDER BY a.#{acct_code}
    """

    case repo.query(sql, [dump_uuid(org_id), year, dump_uuid(budget.id)]) do
      {:ok, %{rows: rows}} -> {:ok, Enum.map(rows, &to_row/1)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp to_row([code, name, side, planned, actual]) do
    variance = actual - planned

    %{
      account_code: code,
      account_name: name,
      normal_side: String.to_existing_atom(side),
      planned_cents: planned,
      actual_cents: actual,
      variance_cents: variance,
      pct: if(planned == 0, do: nil, else: Float.round(variance / planned * 100 * 1.0, 2))
    }
  end

  defp entry_resource(journal_line) do
    Ash.Resource.Info.relationship(journal_line, :entry).destination
  end

  defp entry_fk_source(journal_line) do
    rel = Ash.Resource.Info.relationship(journal_line, :entry)
    Ash.Resource.Info.attribute(journal_line, rel.source_attribute).source
  end

  defp attr_source(resource, attr) do
    Ash.Resource.Info.attribute(resource, attr).source
  end

  defp dump_uuid(nil), do: nil

  defp dump_uuid(id) when is_binary(id) do
    case Ecto.UUID.dump(id) do
      {:ok, bin} -> bin
      :error -> id
    end
  end
end
