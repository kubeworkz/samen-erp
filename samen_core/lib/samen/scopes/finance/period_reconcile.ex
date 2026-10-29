defmodule Samen.Scopes.Finance.PeriodReconcile do
  @moduledoc """
  The **R10 read mirror** (WS-ACCT Phase 3; ADR-054 §3): every POSTED journal
  entry, joined to the fiscal period its `entry_date` lands in, where that period
  is `:closed`.

  R10's write side is `Samen.Scopes.Finance.PeriodGuard` (Ash) plus the
  migration's trigger (the database belt). This module is the independent third
  check: a bare SQL join over the two tables that consults neither guard, so a
  posting that somehow landed — a trigger disabled by an operator, a restored
  backup, a write from another process — is detectable rather than invisible.

  ## The condition is `posted_at > closed_at`, not "the date is in a closed period"

  Read that literally and every period would violate R10 the moment it closed:
  its own entries are dated inside it, and they were posted before it closed,
  which is exactly what a period contains. R10 is about a posting arriving AFTER
  the period was published. So the join pins the two stamps against each other:
  a posted entry whose `entry_date` lands in a closed period **and** whose
  `posted_at` is later than that period's `closed_at`.

  That is the case the trigger cannot see by construction — it fires on the
  WRITE, and by then the period is closed, so a belt that had been off (or a write
  that predated the belt's deployment) leaves a row only a read can find.

  ```
  Samen.Scopes.Finance.PeriodReconcile.clean?(org_id, repo,
    entry_resource: Demo.FinanceScope.JournalEntry,
    period_resource: Demo.FinanceScope.FiscalPeriod
  )
  ```

  Both resources are passed per mount (a scope is materialized per host
  namespace, so no module name is hard-coded here — the `Reconcile` /
  `DimensionReconcile` idiom).
  """

  @doc """
  Every entry that was POSTED after its period closed and is dated inside it, as
  `%{entry_id, entry_date, posted_at, year, month}` rows (oldest first).

  An empty list is the R10 verdict.
  """
  def violations(org_id, repo, opts) do
    {entry_table, period_table, cols} = tables(opts)

    sql = """
    SELECT e.#{cols.entry_id}::text,
           e.#{cols.entry_date},
           e.#{cols.posted_at},
           p.#{cols.year},
           p.#{cols.month}
    FROM #{entry_table} e
    JOIN #{period_table} p
      ON p.#{cols.period_org} = e.#{cols.entry_org}
     AND p.#{cols.year} = EXTRACT(YEAR FROM e.#{cols.entry_date})::int
     AND p.#{cols.month} = EXTRACT(MONTH FROM e.#{cols.entry_date})::int
    WHERE e.#{cols.entry_org} = $1
      AND e.#{cols.entry_status} = 'posted'
      AND p.#{cols.period_status} = 'closed'
      AND p.#{cols.closed_at} IS NOT NULL
      AND e.#{cols.posted_at} > p.#{cols.closed_at}
    ORDER BY e.#{cols.entry_date}, e.#{cols.entry_id}
    """

    case repo.query(sql, [dump_uuid(org_id)]) do
      {:ok, %{rows: rows}} ->
        {:ok,
         Enum.map(rows, fn [entry_id, entry_date, posted_at, year, month] ->
           %{
             entry_id: entry_id,
             entry_date: entry_date,
             posted_at: posted_at,
             year: year,
             month: month
           }
         end)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "The single R10 verdict: no posted entry sits inside a closed period."
  def clean?(org_id, repo, opts) do
    case violations(org_id, repo, opts) do
      {:ok, []} -> {:ok, true}
      {:ok, _rows} -> {:ok, false}
      {:error, reason} -> {:error, reason}
    end
  end

  # ── plumbing ───────────────────────────────────────────────────────────────

  defp tables(opts) do
    entry = Keyword.fetch!(opts, :entry_resource)
    period = Keyword.fetch!(opts, :period_resource)

    cols = %{
      entry_id: attr_source(entry, :id),
      entry_org: attr_source(entry, :org_id),
      entry_date: attr_source(entry, :entry_date),
      entry_status: attr_source(entry, :status),
      posted_at: attr_source(entry, :posted_at),
      period_org: attr_source(period, :org_id),
      period_status: attr_source(period, :status),
      closed_at: attr_source(period, :closed_at),
      year: attr_source(period, :year),
      month: attr_source(period, :month)
    }

    {AshPostgres.DataLayer.Info.table(entry), AshPostgres.DataLayer.Info.table(period), cols}
  end

  defp attr_source(resource, name) do
    case Ash.Resource.Info.attribute(resource, name) do
      nil -> raise ArgumentError, "#{inspect(resource)} has no #{inspect(name)} attribute"
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
