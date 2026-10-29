defmodule Samen.Scopes.Finance.DimensionReconcile do
  @moduledoc """
  The R6 READ mirror (WS-ACCT Phase 1; ADR-054 §3): every per-cost-object
  balance is the SUM of the posted lines that name it — there is no cached
  column to trust, so the reconciliation IS the read.

    * `balances/3` — one row per `(axis, cost object)`: `debit_cents`,
      `credit_cents` and the signed `balance_cents` (`debits − credits`).
      R6b says every `balance_cents` is zero.
    * `violations/3` — the entries that break R6a (an axis named on some of the
      entry's lines but not all), returned as
      `%{entry_id, key, lines, tagged}`.
    * `balanced?/3` — the single verdict: no non-zero balance AND no incomplete
      entry.

  Bare SQL over the line table joined to its posted entries (the `Reconcile`
  idiom: a draft is a staged intention, not a fact). Like `Reconcile`, the line
  resource is passed per mount — a scope is materialized per host namespace, so
  no module name is hard-coded here:

      Samen.Scopes.Finance.DimensionReconcile.balanced?(org_id, repo,
        line_resource: Demo.FinanceScope.JournalLine
      )

  The write-side twin is `Samen.Scopes.Finance.DimensionBalance`. The pair is
  the R6 guarantee: the guard refuses the imbalance at the door, this module
  proves the door held — including against rows forced in below Ash (the
  sabotage's shape).
  """

  @doc """
  Per `(axis, cost object)` debit/credit sums over POSTED lines. Only lines that
  actually carry a dimension contribute — an undimensioned posting has no cost
  object to report against.
  """
  def balances(org_id, repo, opts) do
    line_resource = Keyword.fetch!(opts, :line_resource)

    table = AshPostgres.DataLayer.Info.table(line_resource)
    org = attr_source(line_resource, :org_id)
    dim = attr_source(line_resource, :dimension_refs)
    debit = attr_source(line_resource, :debit_cents)
    credit = attr_source(line_resource, :credit_cents)
    posted_join = posted_join_sql(line_resource)

    sql = """
    SELECT d.key,
           d.value,
           COALESCE(SUM(l.#{debit}), 0)::bigint,
           COALESCE(SUM(l.#{credit}), 0)::bigint
    FROM #{table} l
    #{posted_join}
    CROSS JOIN LATERAL jsonb_each_text(l.#{dim}) AS d(key, value)
    WHERE l.#{org} = $1
    GROUP BY d.key, d.value
    ORDER BY d.key, d.value
    """

    case repo.query(sql, [dump_uuid(org_id)]) do
      {:ok, %{rows: rows}} ->
        {:ok,
         Enum.map(rows, fn [key, value, debits, credits] ->
           %{
             key: key,
             cost_object_id: value,
             debit_cents: debits,
             credit_cents: credits,
             balance_cents: debits - credits
           }
         end)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  R6a violations: posted entries where an axis is named on fewer than all of the
  entry's lines.
  """
  def violations(org_id, repo, opts) do
    line_resource = Keyword.fetch!(opts, :line_resource)

    table = AshPostgres.DataLayer.Info.table(line_resource)
    org = attr_source(line_resource, :org_id)
    id = attr_source(line_resource, :id)
    dim = attr_source(line_resource, :dimension_refs)
    posted_join = posted_join_sql(line_resource)
    entry_fk = line_entry_fk_source(line_resource)

    sql = """
    WITH posted AS (
      SELECT l.#{id} AS line_id, l.#{entry_fk} AS entry_id, l.#{dim} AS refs
      FROM #{table} l
      #{posted_join}
      WHERE l.#{org} = $1
    ),
    per_entry AS (
      SELECT entry_id, COUNT(*)::bigint AS lines FROM posted GROUP BY entry_id
    ),
    tagged AS (
      SELECT p.entry_id, k.key, COUNT(*)::bigint AS tagged
      FROM posted p CROSS JOIN LATERAL jsonb_object_keys(p.refs) AS k(key)
      GROUP BY p.entry_id, k.key
    )
    SELECT t.entry_id::text, t.key, e.lines, t.tagged
    FROM tagged t JOIN per_entry e ON e.entry_id = t.entry_id
    WHERE t.tagged < e.lines
    ORDER BY 1, 2
    """

    case repo.query(sql, [dump_uuid(org_id)]) do
      {:ok, %{rows: rows}} ->
        {:ok,
         Enum.map(rows, fn [entry_id, key, lines, tagged] ->
           %{entry_id: entry_id, key: key, lines: lines, tagged: tagged}
         end)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  The R6 verdict: `true` iff every cost object's posted debits equal its credits
  (R6b) and no posted entry is partially dimensioned (R6a). `false` is a broken
  ledger, not a rounding opinion.
  """
  def balanced?(org_id, repo, opts) do
    with {:ok, rows} <- balances(org_id, repo, opts),
         {:ok, violations} <- violations(org_id, repo, opts) do
      {:ok, Enum.all?(rows, &(&1.balance_cents == 0)) and violations == []}
    end
  end

  # Restrict the sum to lines whose ENTRY is posted (Reconcile's join, same
  # rationale: a draft's lines are staged intentions; a voided entry keeps its
  # lines and its reversal nets them).
  defp posted_join_sql(line_resource) do
    entry_resource = entry_resource(line_resource)

    entry_table = AshPostgres.DataLayer.Info.table(entry_resource)
    entry_pk = attr_source(entry_resource, :id)
    entry_status = attr_source(entry_resource, :status)

    "JOIN #{entry_table} e ON e.#{entry_pk} = l.#{line_entry_fk_source(line_resource)} " <>
      "AND e.#{entry_status} = 'posted'"
  end

  defp entry_resource(line_resource) do
    line_resource
    |> Ash.Resource.Info.relationships()
    |> Enum.find(&(&1.type == :belongs_to and &1.name == :entry))
    |> Map.fetch!(:destination)
  end

  defp line_entry_fk_source(line_resource) do
    line_resource
    |> Ash.Resource.Info.relationships()
    |> Enum.find(&(&1.type == :belongs_to and &1.name == :entry))
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
