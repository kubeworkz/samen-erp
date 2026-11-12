defmodule Samen.Scopes.Finance.ReconciliationWorkbench do
  @moduledoc """
  The reconciliation workbench's read (WS-ACCT follow-on).

  The workbench answers two questions without introducing a second ledger:

    * which accounts have posted activity, and what are their debit, credit and
      signed balances;
    * which posted lines make up one selected account's balance.

  The balance columns are derived from the POSTED `JournalLine` rows in the
  same way `Reconcile.account_balance/3` derives a single account balance:
  drafts are staged intentions, and a void's reversing pair nets out naturally.
  `report/2` also calls `Reconcile.org_balance/3` for the independent R1 verdict,
  so the page's "org balance" is the kernel read, not a second arithmetic path.

  There is no reconciliation table, status column or checklist here. A
  workbench row is a read at request time; the only durable facts are the
  ledger's own posted entries and lines.

  Resources are passed per mount, exactly like `Reconcile` and
  `DimensionReconcile` (a scope is materialized under each host's namespace):

      Samen.Scopes.Finance.ReconciliationWorkbench.report(org_id,
        repo: MyRepo,
        account_resource: MyHost.Erp.Account,
        line_resource: MyHost.Erp.JournalLine,
        entry_resource: MyHost.Erp.JournalEntry
      )
  """

  alias Samen.Scopes.Finance.{Reconcile, ReportColumns}

  @default_line_limit 100
  @max_line_limit 200

  @doc """
  The workbench's account read.

  Returns `{:ok, %{org_balance_cents:, balanced?:, accounts:, account_count:,
  posted_line_count:}}` or `{:error, reason}`.

  Every returned account is scoped to `org_id`. `balance_cents` is
  `debit_cents - credit_cents` (the ledger's signed convention), and
  `posted_line_count` counts only lines whose entry is `:posted`.
  """
  def report(org_id, opts) do
    repo = Keyword.fetch!(opts, :repo)
    account_resource = Keyword.fetch!(opts, :account_resource)
    line_resource = Keyword.fetch!(opts, :line_resource)
    entry_resource = Keyword.fetch!(opts, :entry_resource)

    account_table = ReportColumns.table(account_resource)
    line_table = ReportColumns.table(line_resource)
    entry_table = ReportColumns.table(entry_resource)

    sql = """
    SELECT
      a.#{ReportColumns.column(account_resource, :id)}::text,
      a.#{ReportColumns.column(account_resource, :code)},
      a.#{ReportColumns.column(account_resource, :name)},
      a.#{ReportColumns.column(account_resource, :kind)},
      a.#{ReportColumns.column(account_resource, :normal_side)},
      COALESCE(SUM(p.debit_cents), 0)::bigint,
      COALESCE(SUM(p.credit_cents), 0)::bigint,
      COUNT(p.debit_cents)::bigint,
      MAX(p.entry_date)
    FROM #{account_table} a
    LEFT JOIN (
      SELECT
        l.#{ReportColumns.column(line_resource, :account_id)} AS account_id,
        l.#{ReportColumns.column(line_resource, :debit_cents)} AS debit_cents,
        l.#{ReportColumns.column(line_resource, :credit_cents)} AS credit_cents,
        e.#{ReportColumns.column(entry_resource, :entry_date)} AS entry_date
      FROM #{line_table} l
      JOIN #{entry_table} e
        ON e.#{ReportColumns.column(entry_resource, :id)} =
           l.#{ReportColumns.column(line_resource, :entry_id)}
       AND e.#{ReportColumns.column(entry_resource, :org_id)} =
           l.#{ReportColumns.column(line_resource, :org_id)}
       AND e.#{ReportColumns.column(entry_resource, :status)} = 'posted'
      WHERE l.#{ReportColumns.column(line_resource, :org_id)} = $1
        AND e.#{ReportColumns.column(entry_resource, :org_id)} = $1
    ) p ON p.account_id = a.#{ReportColumns.column(account_resource, :id)}
    WHERE a.#{ReportColumns.column(account_resource, :org_id)} = $1
    GROUP BY
      a.#{ReportColumns.column(account_resource, :id)},
      a.#{ReportColumns.column(account_resource, :code)},
      a.#{ReportColumns.column(account_resource, :name)},
      a.#{ReportColumns.column(account_resource, :kind)},
      a.#{ReportColumns.column(account_resource, :normal_side)}
    ORDER BY a.#{ReportColumns.column(account_resource, :code)}
    """

    with {:ok, %{rows: rows}} <- repo.query(sql, [dump_uuid(org_id)]),
         {:ok, org_balance} <-
           Reconcile.org_balance(org_id, repo, line_resource: line_resource) do
      accounts =
        Enum.map(rows, fn [id, code, name, kind, normal_side, debit, credit, lines, last_entry] ->
          %{
            id: id,
            code: code,
            name: name,
            kind: String.to_atom(kind),
            normal_side: String.to_atom(normal_side),
            debit_cents: debit,
            credit_cents: credit,
            balance_cents: debit - credit,
            posted_line_count: lines,
            last_entry_date: last_entry
          }
        end)

      {:ok,
       %{
         org_balance_cents: org_balance,
         balanced?: org_balance == 0,
         accounts: accounts,
         account_count: length(accounts),
         posted_line_count: Enum.reduce(accounts, 0, &(&1.posted_line_count + &2))
       }}
    end
  end

  @doc """
  The posted lines for one account, newest first, bounded to `:limit`
  (default #{@default_line_limit}, maximum #{@max_line_limit}).

  The account and every line are scoped to `org_id`; a foreign account id
  resolves to `[]`, never to another org's rows.
  """
  def lines(org_id, account_id, opts) do
    repo = Keyword.fetch!(opts, :repo)
    line_resource = Keyword.fetch!(opts, :line_resource)
    entry_resource = Keyword.fetch!(opts, :entry_resource)
    limit = opts |> Keyword.get(:limit, @default_line_limit) |> clamp_limit()

    line_table = ReportColumns.table(line_resource)
    entry_table = ReportColumns.table(entry_resource)

    sql = """
    SELECT
      l.#{ReportColumns.column(line_resource, :id)}::text,
      e.#{ReportColumns.column(entry_resource, :id)}::text,
      e.#{ReportColumns.column(entry_resource, :entry_date)},
      e.#{ReportColumns.column(entry_resource, :memo)},
      e.#{ReportColumns.column(entry_resource, :source_key)},
      e.#{ReportColumns.column(entry_resource, :source_id)}::text,
      l.#{ReportColumns.column(line_resource, :memo)},
      l.#{ReportColumns.column(line_resource, :debit_cents)},
      l.#{ReportColumns.column(line_resource, :credit_cents)},
      e.#{ReportColumns.column(entry_resource, :posted_at)}
    FROM #{line_table} l
    JOIN #{entry_table} e
      ON e.#{ReportColumns.column(entry_resource, :id)} =
         l.#{ReportColumns.column(line_resource, :entry_id)}
     AND e.#{ReportColumns.column(entry_resource, :org_id)} =
         l.#{ReportColumns.column(line_resource, :org_id)}
     AND e.#{ReportColumns.column(entry_resource, :status)} = 'posted'
    WHERE l.#{ReportColumns.column(line_resource, :org_id)} = $1
      AND e.#{ReportColumns.column(entry_resource, :org_id)} = $1
      AND l.#{ReportColumns.column(line_resource, :account_id)} = $2
    ORDER BY
      e.#{ReportColumns.column(entry_resource, :entry_date)} DESC,
      e.#{ReportColumns.column(entry_resource, :posted_at)} DESC,
      l.#{ReportColumns.column(line_resource, :id)} DESC
    LIMIT $3
    """

    case repo.query(sql, [dump_uuid(org_id), dump_uuid(account_id), limit]) do
      {:ok, %{rows: rows}} ->
        {:ok,
         Enum.map(rows, fn [
                             line_id,
                             entry_id,
                             entry_date,
                             entry_memo,
                             source_key,
                             source_id,
                             line_memo,
                             debit,
                             credit,
                             posted_at
                           ] ->
           %{
             line_id: line_id,
             entry_id: entry_id,
             entry_date: entry_date,
             entry_memo: entry_memo,
             source_key: source_key,
             source_id: source_id,
             line_memo: line_memo,
             debit_cents: debit,
             credit_cents: credit,
             posted_at: posted_at
           }
         end)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp clamp_limit(limit) when is_integer(limit), do: limit |> max(1) |> min(@max_line_limit)
  defp clamp_limit(_limit), do: @default_line_limit

  defp dump_uuid(value) when is_binary(value) and byte_size(value) == 16, do: value

  defp dump_uuid(value) do
    case Ecto.UUID.dump(value) do
      {:ok, bin} -> bin
      :error -> value
    end
  end
end
