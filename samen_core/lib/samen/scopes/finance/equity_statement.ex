defmodule Samen.Scopes.Finance.EquityStatement do
  @moduledoc """
  Statement of changes in equity (WS-ACCT Phase 13 extension).

  The statement is a **period read** over the posted ledger. It presents every
  equity account's opening balance, the period's increases and decreases, and
  its closing balance, plus the unclosed earnings the balance sheet adds to
  equity because the ledger has no automatic closing entry.

  ## Why there is an unclosed-earnings row

  `Samen.Scopes.Finance.BalanceSheet` adds the cumulative income less expense
  through the reporting date to equity. Until a host posts its own closing
  entry, that result is not in an equity account, so a statement that only read
  equity-account lines would disagree with the balance sheet. The
  `:unclosed_earnings` section carries that result explicitly:

    * opening — cumulative net income before the period;
    * net income — the period's income less expense;
    * closing — cumulative net income through the period end.

  A host that does post closing entries simply has a zero unclosed result after
  the close; the same arithmetic still holds.

  ## Signs

  Equity accounts are credit-normal, so the statement presents them positive:
  `opening + increases - decreases = closing`. The `debit_cents` and
  `credit_cents` fields are the period's raw postings; `change_cents` is their
  presentation-sign net (`credits - debits`).

  ## Physical names

  Every table/column comes from `ReportColumns`, exactly like the trial
  balance, balance sheet and P&L reads, so a host's abbrev-prefixed columns are
  not guessed.
  """

  alias Samen.Scopes.Finance.ReportColumns

  @type row :: %{
          account_id: String.t(),
          code: String.t(),
          name: String.t(),
          normal_side: atom(),
          opening_cents: integer(),
          debit_cents: integer(),
          credit_cents: integer(),
          change_cents: integer(),
          closing_cents: integer()
        }

  @type statement :: %{
          from_date: DateTime.t(),
          to_date: DateTime.t(),
          rows: [row()],
          unclosed_earnings: map(),
          opening_total_cents: integer(),
          net_income_cents: integer(),
          other_changes_cents: integer(),
          closing_total_cents: integer(),
          articulated?: boolean()
        }

  @doc """
  Build the statement for `org_id` over `[from_date, to_date]`.

  Required opts: `:repo`, `:account_resource`, `:line_resource`,
  `:entry_resource`.
  """
  @spec generate(String.t(), DateTime.t(), DateTime.t(), keyword()) ::
          {:ok, statement()} | {:error, term()}
  def generate(org_id, from_date, to_date, opts) do
    repo = Keyword.fetch!(opts, :repo)
    account = Keyword.fetch!(opts, :account_resource)
    line = Keyword.fetch!(opts, :line_resource)
    entry = Keyword.fetch!(opts, :entry_resource)

    with {:ok, equity_rows} <-
           repo.query(equity_sql(account, line, entry), [dump_uuid(org_id), from_date, to_date]),
         {:ok, income_rows} <-
           repo.query(income_sql(account, line, entry), [dump_uuid(org_id), from_date, to_date]) do
      rows =
        Enum.map(equity_rows.rows, fn [
                                        id,
                                        code,
                                        name,
                                        normal_side,
                                        opening_signed,
                                        debit,
                                        credit
                                      ] ->
          opening = -opening_signed
          change = credit - debit

          %{
            account_id: load_uuid(id),
            code: code,
            name: name,
            normal_side: normal_side(normal_side),
            opening_cents: opening,
            debit_cents: debit,
            credit_cents: credit,
            change_cents: change,
            closing_cents: opening + change
          }
        end)

      [pre_signed, period_signed, through_signed] =
        case income_rows.rows do
          [[a, b, c]] -> [a, b, c]
          [] -> [0, 0, 0]
        end

      opening_unclosed = -pre_signed
      net_income = -period_signed
      closing_unclosed = -through_signed

      opening_total = Enum.reduce(rows, opening_unclosed, &(&1.opening_cents + &2))
      other_changes = Enum.reduce(rows, 0, &(&1.change_cents + &2))
      closing_total = Enum.reduce(rows, closing_unclosed, &(&1.closing_cents + &2))

      {:ok,
       %{
         from_date: from_date,
         to_date: to_date,
         rows: rows,
         unclosed_earnings: %{
           opening_cents: opening_unclosed,
           net_income_cents: net_income,
           closing_cents: closing_unclosed
         },
         opening_total_cents: opening_total,
         net_income_cents: net_income,
         other_changes_cents: other_changes,
         closing_total_cents: closing_total,
         articulated?: opening_total + net_income + other_changes == closing_total
       }}
    end
  end

  defp equity_sql(account, line, entry) do
    account_table = ReportColumns.table(account)
    line_table = ReportColumns.table(line)
    entry_table = ReportColumns.table(entry)

    account_id = ReportColumns.column(account, :id)
    account_code = ReportColumns.column(account, :code)
    account_name = ReportColumns.column(account, :name)
    account_kind = ReportColumns.column(account, :kind)
    account_side = ReportColumns.column(account, :normal_side)
    account_org = ReportColumns.column(account, :org_id)

    line_account = ReportColumns.column(line, :account_id)
    line_org = ReportColumns.column(line, :org_id)
    line_entry = ReportColumns.column(line, :entry_id)
    debit = ReportColumns.column(line, :debit_cents)
    credit = ReportColumns.column(line, :credit_cents)

    entry_id = ReportColumns.column(entry, :id)
    entry_org = ReportColumns.column(entry, :org_id)
    entry_status = ReportColumns.column(entry, :status)
    posted_at = ReportColumns.column(entry, :posted_at)

    """
    SELECT
      a.#{account_id} AS id,
      a.#{account_code} AS code,
      a.#{account_name} AS name,
      a.#{account_side} AS normal_side,
      COALESCE(SUM(CASE WHEN e.#{posted_at} < $2
                        THEN l.#{debit} - l.#{credit} ELSE 0 END), 0)::bigint AS opening_signed,
      COALESCE(SUM(CASE WHEN e.#{posted_at} >= $2 AND e.#{posted_at} <= $3
                        THEN l.#{debit} ELSE 0 END), 0)::bigint AS period_debit,
      COALESCE(SUM(CASE WHEN e.#{posted_at} >= $2 AND e.#{posted_at} <= $3
                        THEN l.#{credit} ELSE 0 END), 0)::bigint AS period_credit
    FROM #{account_table} a
    LEFT JOIN #{line_table} l
      ON l.#{line_account} = a.#{account_id}
      AND l.#{line_org} = $1
    LEFT JOIN #{entry_table} e
      ON e.#{entry_id} = l.#{line_entry}
      AND e.#{entry_org} = $1
      AND e.#{entry_status} = 'posted'
    WHERE a.#{account_org} = $1
      AND a.#{account_kind} = 'equity'
    GROUP BY
      a.#{account_id},
      a.#{account_code},
      a.#{account_name},
      a.#{account_side}
    ORDER BY a.#{account_code}
    """
  end

  defp income_sql(account, line, entry) do
    account_table = ReportColumns.table(account)
    line_table = ReportColumns.table(line)
    entry_table = ReportColumns.table(entry)

    account_id = ReportColumns.column(account, :id)
    account_kind = ReportColumns.column(account, :kind)
    account_org = ReportColumns.column(account, :org_id)

    line_account = ReportColumns.column(line, :account_id)
    line_org = ReportColumns.column(line, :org_id)
    line_entry = ReportColumns.column(line, :entry_id)
    debit = ReportColumns.column(line, :debit_cents)
    credit = ReportColumns.column(line, :credit_cents)

    entry_id = ReportColumns.column(entry, :id)
    entry_org = ReportColumns.column(entry, :org_id)
    entry_status = ReportColumns.column(entry, :status)
    posted_at = ReportColumns.column(entry, :posted_at)

    """
    SELECT
      COALESCE(SUM(CASE WHEN e.#{posted_at} < $2
                        THEN l.#{debit} - l.#{credit} ELSE 0 END), 0)::bigint,
      COALESCE(SUM(CASE WHEN e.#{posted_at} >= $2 AND e.#{posted_at} <= $3
                        THEN l.#{debit} - l.#{credit} ELSE 0 END), 0)::bigint,
      COALESCE(SUM(CASE WHEN e.#{posted_at} <= $3
                        THEN l.#{debit} - l.#{credit} ELSE 0 END), 0)::bigint
    FROM #{line_table} l
    JOIN #{entry_table} e
      ON e.#{entry_id} = l.#{line_entry}
      AND e.#{entry_org} = $1
      AND e.#{entry_status} = 'posted'
    JOIN #{account_table} a
      ON a.#{account_id} = l.#{line_account}
      AND a.#{account_org} = $1
    WHERE l.#{line_org} = $1
      AND a.#{account_kind} IN ('income', 'expense')
    """
  end

  defp normal_side("debit"), do: :debit
  defp normal_side("credit"), do: :credit
  defp normal_side(:debit), do: :debit
  defp normal_side(:credit), do: :credit
  defp normal_side(_other), do: :credit

  defp load_uuid(id) when is_binary(id) and byte_size(id) == 16, do: Ecto.UUID.load!(id)
  defp load_uuid(id), do: id

  defp dump_uuid(nil), do: nil
  defp dump_uuid(id) when is_binary(id) and byte_size(id) == 16, do: id
  defp dump_uuid(id), do: Ecto.UUID.dump!(id)
end
