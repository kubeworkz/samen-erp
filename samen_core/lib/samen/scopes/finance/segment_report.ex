defmodule Samen.Scopes.Finance.SegmentReport do
  @moduledoc """
  Segment P&L by the ledger's frozen dimension axes (WS-ACCT Phase 13
  extension).

  The report groups posted income and expense lines by one dimension axis
  (`"project"`, `"lot"`, `"fund"` or `"cost_pool"`) and returns revenue,
  expense and net income per segment. Lines that do not carry the chosen axis
  are not dropped: they land in an explicit `Unallocated` bucket, so the
  segment totals always tie to the company P&L.

  ## Why cost objects, not a second segment master

  `JournalLine.dimension_refs` already carries the CostObject ids the rest of
  the accounting model uses. A segment report that introduced another
  segmentation table would be a second truth; this read is a GROUP BY over the
  posted lines. The optional `:cost_object` resource is used only to label the
  returned ids (code/name), never to decide which lines belong to a segment.

  ## Signs

  Revenue is income credits less income debits; expense is expense debits less
  expense credits; net is revenue less expense. This is the same presentation
  as `Samen.Scopes.Finance.ProfitLoss`, and the totals for the period must
  match it.

  ## Physical names

  Every table/column comes from `ReportColumns`. The dimension map is read with
  PostgreSQL's `jsonb_each_text`, and the axis is a bound parameter — never
  interpolated SQL.
  """

  require Ash.Query

  alias Samen.Scopes.Finance.ReportColumns

  @axes ~w(project lot fund cost_pool)

  @type segment :: %{
          segment_id: String.t() | nil,
          code: String.t() | nil,
          name: String.t() | nil,
          allocated?: boolean(),
          revenue_cents: integer(),
          expense_cents: integer(),
          net_cents: integer(),
          line_count: integer()
        }

  @type report :: %{
          dimension_key: String.t(),
          from_date: DateTime.t(),
          to_date: DateTime.t(),
          segments: [segment()],
          allocated: [segment()],
          unallocated: segment() | nil,
          totals: %{
            revenue_cents: integer(),
            expense_cents: integer(),
            net_cents: integer(),
            line_count: integer()
          }
        }

  @doc """
  Build the segment report for `org_id` over `[from_date, to_date]`.

  Required opts: `:repo`, `:account_resource`, `:line_resource`,
  `:entry_resource`.

  Optional:

    * `:dimension_key` — one of `"project"`, `"lot"`, `"fund"`, `"cost_pool"`
      (default `"project"`);
    * `:cost_object` — the host's mounted CostObject module, used only for
      code/name labels;
    * `:scope` — the Ash scope for that label read. Without it the read uses
      `authorize?: false`, matching the other statement reads.
  """
  @spec report(String.t(), DateTime.t(), DateTime.t(), keyword()) ::
          {:ok, report()} | {:error, term()}
  def report(org_id, from_date, to_date, opts) do
    repo = Keyword.fetch!(opts, :repo)
    account = Keyword.fetch!(opts, :account_resource)
    line = Keyword.fetch!(opts, :line_resource)
    entry = Keyword.fetch!(opts, :entry_resource)
    dimension_key = opts |> Keyword.get(:dimension_key, "project") |> to_string()

    if dimension_key in @axes do
      sql = sql(account, line, entry)

      with {:ok, %{rows: rows}} <-
             repo.query(sql, [dump_uuid(org_id), from_date, to_date, dimension_key]),
           {:ok, labels} <- labels(org_id, rows, opts) do
        segments =
          rows
          |> Enum.map(fn [segment_id, revenue, expense, line_count] ->
            segment_id = load_uuid(segment_id)
            label = Map.get(labels, segment_id, %{})

            %{
              segment_id: segment_id,
              code: Map.get(label, :code),
              name: Map.get(label, :name),
              allocated?: not is_nil(segment_id),
              revenue_cents: revenue,
              expense_cents: expense,
              net_cents: revenue - expense,
              line_count: line_count
            }
          end)
          |> Enum.sort_by(&segment_sort_key/1)

        allocated = Enum.filter(segments, & &1.allocated?)
        unallocated = Enum.find(segments, &(not &1.allocated?))

        totals = %{
          revenue_cents: Enum.reduce(segments, 0, &(&1.revenue_cents + &2)),
          expense_cents: Enum.reduce(segments, 0, &(&1.expense_cents + &2)),
          net_cents: Enum.reduce(segments, 0, &(&1.net_cents + &2)),
          line_count: Enum.reduce(segments, 0, &(&1.line_count + &2))
        }

        {:ok,
         %{
           dimension_key: dimension_key,
           from_date: from_date,
           to_date: to_date,
           segments: segments,
           allocated: allocated,
           unallocated: unallocated,
           totals: totals
         }}
      end
    else
      {:error, {:unknown_dimension, dimension_key}}
    end
  end

  defp sql(account, line, entry) do
    account_table = ReportColumns.table(account)
    line_table = ReportColumns.table(line)
    entry_table = ReportColumns.table(entry)

    account_id = ReportColumns.column(account, :id)
    account_kind = ReportColumns.column(account, :kind)
    account_org = ReportColumns.column(account, :org_id)

    line_account = ReportColumns.column(line, :account_id)
    line_org = ReportColumns.column(line, :org_id)
    line_entry = ReportColumns.column(line, :entry_id)
    dimension_refs = ReportColumns.column(line, :dimension_refs)
    debit = ReportColumns.column(line, :debit_cents)
    credit = ReportColumns.column(line, :credit_cents)

    entry_id = ReportColumns.column(entry, :id)
    entry_org = ReportColumns.column(entry, :org_id)
    entry_status = ReportColumns.column(entry, :status)
    posted_at = ReportColumns.column(entry, :posted_at)

    """
    SELECT
      d.value AS segment_id,
      COALESCE(SUM(CASE WHEN a.#{account_kind} = 'income'
                        THEN l.#{credit} - l.#{debit} ELSE 0 END), 0)::bigint AS revenue,
      COALESCE(SUM(CASE WHEN a.#{account_kind} = 'expense'
                        THEN l.#{debit} - l.#{credit} ELSE 0 END), 0)::bigint AS expense,
      COUNT(*)::bigint AS line_count
    FROM #{line_table} l
    JOIN #{entry_table} e
      ON e.#{entry_id} = l.#{line_entry}
      AND e.#{entry_org} = $1
      AND e.#{entry_status} = 'posted'
    JOIN #{account_table} a
      ON a.#{account_id} = l.#{line_account}
      AND a.#{account_org} = $1
    LEFT JOIN LATERAL jsonb_each_text(l.#{dimension_refs}) AS d(key, value)
      ON d.key = $4
    WHERE l.#{line_org} = $1
      AND e.#{posted_at} >= $2
      AND e.#{posted_at} <= $3
      AND a.#{account_kind} IN ('income', 'expense')
    GROUP BY d.value
    ORDER BY d.value NULLS LAST
    """
  end

  defp labels(org_id, rows, opts) do
    case Keyword.get(opts, :cost_object) do
      nil ->
        {:ok, %{}}

      resource ->
        ids =
          rows
          |> Enum.map(&List.first/1)
          |> Enum.map(&load_uuid/1)
          |> Enum.reject(&is_nil/1)
          |> Enum.uniq()

        if ids == [] do
          {:ok, %{}}
        else
          query =
            resource
            |> Ash.Query.filter(org_id == ^org_id and id in ^ids)

          result =
            case Keyword.get(opts, :scope) do
              nil -> Ash.read(query, authorize?: false)
              scope -> Ash.read(query, scope: scope)
            end

          case result do
            {:ok, objects} ->
              {:ok,
               Map.new(objects, fn object ->
                 {object.id, %{code: Map.get(object, :code), name: Map.get(object, :name)}}
               end)}

            {:error, reason} ->
              {:error, reason}
          end
        end
    end
  end

  defp segment_sort_key(%{allocated?: false}), do: {1, "", ""}
  defp segment_sort_key(segment), do: {0, segment.code || "", segment.segment_id || ""}

  defp load_uuid(id) when is_binary(id) and byte_size(id) == 16, do: Ecto.UUID.load!(id)
  defp load_uuid(id), do: id

  defp dump_uuid(nil), do: nil
  defp dump_uuid(id) when is_binary(id) and byte_size(id) == 16, do: id
  defp dump_uuid(id), do: Ecto.UUID.dump!(id)
end
