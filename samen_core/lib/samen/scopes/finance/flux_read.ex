defmodule Samen.Scopes.Finance.FluxRead do
  @moduledoc """
  The period-over-period flux read (WS-ACCT follow-on).

  Flux is a read over the ledger's own posted lines: for one month, compare
  each account's posted debit/credit activity with the immediately preceding
  month. Nothing is persisted, and there is no budget, forecast or checklist
  input — the movement is the posted lines themselves.

  Periods use `JournalEntry.entry_date` (the accounting month), while the
  posted-only predicate uses the entry's `:posted` status. A draft is not a
  fact and contributes nothing; a void's reversing pair contributes its two
  posted sides and nets naturally.

  Rows include accounts with activity in either month. `delta_cents` is
  `current_net_cents - prior_net_cents` (debit-positive signed), `delta_pct`
  is the delta against the prior month's absolute net (or `nil` when the prior
  month had no activity), and the rows are ordered by the largest absolute
  movement so the page leads with the accounts that moved the books most.

      Samen.Scopes.Finance.FluxRead.report(org_id, 2026, 9,
        repo: MyRepo,
        account_resource: MyHost.Erp.Account,
        line_resource: MyHost.Erp.JournalLine,
        entry_resource: MyHost.Erp.JournalEntry
      )
  """

  alias Samen.Scopes.Finance.ReportColumns

  @doc """
  Compare `year`/`month` activity with the prior calendar month.

  Returns `{:ok, %{period:, prior_period:, rows:, moved_account_count:}}` or
  `{:error, :bad_period | term()}`.
  """
  def report(org_id, year, month, opts) do
    with {:ok, current_from} <- month_start(year, month) do
      current_to = Date.end_of_month(current_from)
      prior_from = current_from |> Date.add(-1) |> Date.beginning_of_month()
      prior_to = Date.end_of_month(prior_from)

      repo = Keyword.fetch!(opts, :repo)
      account_resource = Keyword.fetch!(opts, :account_resource)
      line_resource = Keyword.fetch!(opts, :line_resource)
      entry_resource = Keyword.fetch!(opts, :entry_resource)

      account_table = ReportColumns.table(account_resource)
      line_table = ReportColumns.table(line_resource)
      entry_table = ReportColumns.table(entry_resource)

      sql = """
      WITH posted AS (
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
      )
      SELECT
        a.#{ReportColumns.column(account_resource, :id)}::text,
        a.#{ReportColumns.column(account_resource, :code)},
        a.#{ReportColumns.column(account_resource, :name)},
        a.#{ReportColumns.column(account_resource, :kind)},
        a.#{ReportColumns.column(account_resource, :normal_side)},
        COALESCE(SUM(CASE WHEN p.entry_date >= $2 AND p.entry_date <= $3
                          THEN p.debit_cents ELSE 0 END), 0)::bigint,
        COALESCE(SUM(CASE WHEN p.entry_date >= $2 AND p.entry_date <= $3
                          THEN p.credit_cents ELSE 0 END), 0)::bigint,
        COALESCE(SUM(CASE WHEN p.entry_date >= $4 AND p.entry_date <= $5
                          THEN p.debit_cents ELSE 0 END), 0)::bigint,
        COALESCE(SUM(CASE WHEN p.entry_date >= $4 AND p.entry_date <= $5
                          THEN p.credit_cents ELSE 0 END), 0)::bigint
      FROM #{account_table} a
      LEFT JOIN posted p
        ON p.account_id = a.#{ReportColumns.column(account_resource, :id)}
      WHERE a.#{ReportColumns.column(account_resource, :org_id)} = $1
      GROUP BY
        a.#{ReportColumns.column(account_resource, :id)},
        a.#{ReportColumns.column(account_resource, :code)},
        a.#{ReportColumns.column(account_resource, :name)},
        a.#{ReportColumns.column(account_resource, :kind)},
        a.#{ReportColumns.column(account_resource, :normal_side)}
      ORDER BY a.#{ReportColumns.column(account_resource, :code)}
      """

      params = [
        dump_uuid(org_id),
        current_from,
        current_to,
        prior_from,
        prior_to
      ]

      case repo.query(sql, params) do
        {:ok, %{rows: rows}} ->
          flux_rows =
            rows
            |> Enum.map(&flux_row/1)
            |> Enum.filter(fn row ->
              row.current_debit_cents + row.current_credit_cents +
                row.prior_debit_cents + row.prior_credit_cents > 0
            end)
            |> Enum.sort_by(&{-abs(&1.delta_cents), &1.code})

          {:ok,
           %{
             period: period(current_from, current_to),
             prior_period: period(prior_from, prior_to),
             rows: flux_rows,
             moved_account_count: length(flux_rows)
           }}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp flux_row([
         id,
         code,
         name,
         kind,
         normal_side,
         current_debit,
         current_credit,
         prior_debit,
         prior_credit
       ]) do
    current_net = current_debit - current_credit
    prior_net = prior_debit - prior_credit
    delta = current_net - prior_net

    %{
      id: id,
      code: code,
      name: name,
      kind: String.to_atom(kind),
      normal_side: String.to_atom(normal_side),
      current_debit_cents: current_debit,
      current_credit_cents: current_credit,
      current_net_cents: current_net,
      prior_debit_cents: prior_debit,
      prior_credit_cents: prior_credit,
      prior_net_cents: prior_net,
      delta_cents: delta,
      delta_pct: delta_pct(delta, prior_net),
      direction: direction(delta)
    }
  end

  defp delta_pct(_delta, 0), do: nil
  defp delta_pct(delta, prior_net), do: Float.round(delta / abs(prior_net) * 100, 1)

  defp direction(delta) when delta > 0, do: :up
  defp direction(delta) when delta < 0, do: :down
  defp direction(_delta), do: :flat

  defp month_start(year, month)
       when is_integer(year) and is_integer(month) and month in 1..12 do
    case Date.new(year, month, 1) do
      {:ok, date} -> {:ok, date}
      _ -> {:error, :bad_period}
    end
  end

  defp month_start(_year, _month), do: {:error, :bad_period}

  defp period(from_date, to_date) do
    %{
      year: from_date.year,
      month: from_date.month,
      from_date: from_date,
      to_date: to_date
    }
  end

  defp dump_uuid(value) when is_binary(value) and byte_size(value) == 16, do: value

  defp dump_uuid(value) do
    case Ecto.UUID.dump(value) do
      {:ok, bin} -> bin
      :error -> value
    end
  end
end
