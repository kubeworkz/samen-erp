defmodule Samen.Scopes.Finance.CashFlow do
  @moduledoc """
  The condensed cash-flow statement (WS-ACCT Phase 13; ADR-054 D12).

  A pure read over the posted ledger, never a stored balance. The cash
  accounts are the ones the host's posting map binds to the `:cash` meaning
  (`PostingAccount.key`), so the statement follows the host's chart rather
  than a hard-coded account code.

  The report is deliberately the *movement* view the board pack needs:

    * `opening_cents` — the cash accounts' balance before the period;
    * `inflows_cents` / `outflows_cents` — debits / credits inside the period;
    * `net_cents` — inflows minus outflows;
    * `closing_cents` — the cash accounts' balance through the period end.

  `mapped?: false` is the honest empty state for a host that never bound
  `:cash`: every amount is zero and no statement is invented. A host with a
  cash mapping gets `reconciled?: true` only when closing equals opening plus
  the period's net movement — the same read checking itself against the
  ledger's own time axis.

  Physical table/column names come from `ReportColumns`, exactly like the
  trial balance, balance sheet and P&L reads, so a host's abbrev-prefixed
  columns are not guessed.
  """

  require Ash.Query

  alias Samen.Scopes.Finance.ReportColumns

  @type statement :: %{
          opening_cents: integer(),
          inflows_cents: integer(),
          outflows_cents: integer(),
          net_cents: integer(),
          closing_cents: integer(),
          cash_account_ids: [String.t()],
          mapped?: boolean(),
          reconciled?: boolean()
        }

  @doc """
  Build the cash-flow statement for `org_id` over `[from_date, to_date]`.

  Required opts: `:repo`, `:posting_account`, `:line`, `:entry`.
  """
  @spec statement(String.t(), DateTime.t(), DateTime.t(), keyword()) ::
          {:ok, statement()} | {:error, term()}
  def statement(org_id, from_date, to_date, opts) do
    repo = Keyword.fetch!(opts, :repo)
    posting_account = Keyword.fetch!(opts, :posting_account)
    line = Keyword.fetch!(opts, :line)
    entry = Keyword.fetch!(opts, :entry)

    cash_account_ids = cash_account_ids(posting_account, org_id)

    if cash_account_ids == [] do
      {:ok, empty_statement()}
    else
      sql = statement_sql(line, entry)

      params = [
        dump_uuid(org_id),
        from_date,
        to_date,
        Enum.map(cash_account_ids, &dump_uuid/1)
      ]

      case repo.query(sql, params) do
        {:ok, %{rows: [[opening, inflows, outflows, closing]]}} ->
          net = inflows - outflows

          {:ok,
           %{
             opening_cents: opening,
             inflows_cents: inflows,
             outflows_cents: outflows,
             net_cents: net,
             closing_cents: closing,
             cash_account_ids: cash_account_ids,
             mapped?: true,
             reconciled?: closing == opening + net
           }}

        {:ok, _other} ->
          {:error, :unexpected_cash_flow_shape}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp cash_account_ids(posting_account, org_id) do
    posting_account
    |> Ash.Query.filter(org_id == ^org_id and key == :cash)
    |> Ash.read!(authorize?: false)
    |> Enum.map(& &1.account_id)
    |> Enum.uniq()
  end

  defp statement_sql(line, entry) do
    line_table = ReportColumns.table(line)
    entry_table = ReportColumns.table(entry)

    line_org = ReportColumns.column(line, :org_id)
    line_account = ReportColumns.column(line, :account_id)
    line_entry = ReportColumns.column(line, :entry_id)
    debit = ReportColumns.column(line, :debit_cents)
    credit = ReportColumns.column(line, :credit_cents)

    entry_id = ReportColumns.column(entry, :id)
    entry_org = ReportColumns.column(entry, :org_id)
    entry_status = ReportColumns.column(entry, :status)
    posted_at = ReportColumns.column(entry, :posted_at)

    """
    SELECT
      COALESCE(SUM(CASE WHEN e.#{posted_at} < $2 THEN l.#{debit} - l.#{credit} ELSE 0 END), 0)::bigint,
      COALESCE(SUM(CASE WHEN e.#{posted_at} >= $2 AND e.#{posted_at} <= $3
                        THEN l.#{debit} ELSE 0 END), 0)::bigint,
      COALESCE(SUM(CASE WHEN e.#{posted_at} >= $2 AND e.#{posted_at} <= $3
                        THEN l.#{credit} ELSE 0 END), 0)::bigint,
      COALESCE(SUM(CASE WHEN e.#{posted_at} <= $3 THEN l.#{debit} - l.#{credit} ELSE 0 END), 0)::bigint
    FROM #{line_table} l
    JOIN #{entry_table} e ON e.#{entry_id} = l.#{line_entry}
    WHERE l.#{line_org} = $1
      AND e.#{entry_org} = $1
      AND e.#{entry_status} = 'posted'
      AND l.#{line_account} = ANY($4::uuid[])
    """
  end

  defp empty_statement do
    %{
      opening_cents: 0,
      inflows_cents: 0,
      outflows_cents: 0,
      net_cents: 0,
      closing_cents: 0,
      cash_account_ids: [],
      mapped?: false,
      reconciled?: true
    }
  end

  defp dump_uuid(nil), do: nil
  defp dump_uuid(id) when is_binary(id) and byte_size(id) == 16, do: id
  defp dump_uuid(id), do: Ecto.UUID.dump!(id)
end
