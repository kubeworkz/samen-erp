defmodule Samen.Scopes.Inventory.ReconcileProduction do
  @moduledoc """
  The R4 reconciliation reads (WS-ERP E6; design §6.3): for every completed
  work order, the ProductionLog facts and the StockLedger events are
  computed as INDEPENDENT bare-SQL aggregations (they share only the WO's
  id — never a code path), so a facade bypass that lands one side without
  the other DIVERGES and the red-path fails.

  * `order/3` — one WO's two legs: the ledger events anchored
    `source_key: "work_order"` (consumption Σ qty/Σ value per item + the
    produce event) and the ProductionLog facts (the same shapes).
  * `divergences/2` — every org WO whose log facts disagree with its
    ledger events, or whose produce-event cost disagrees with the stamped
    roll-up (beyond the ±1 rounding unit — the floor division's
    granularity) — the standing read the suite's green paths assert empty
    and the sabotage's bypass makes non-empty.
  """

  @source_key "work_order"

  @doc "The work-order anchor source_key (single source of truth, the ProduceWo discipline)."
  def source_key, do: @source_key

  @doc """
  One completed WO's two legs, each computed fresh from its own table:

    * `:ledger` — Σ consumption (negative) value, the produce event's
      (qty, unit_cost);
    * `:log` — Σ consumption rows, the produce row, the Σ adjustments.
  """
  def order(repo, org_id, opts) do
    wo_id = Keyword.fetch!(opts, :work_order_id)

    with {:ok, ledger} <- ledger_leg(repo, org_id, wo_id, opts),
         {:ok, log} <- log_leg(repo, org_id, wo_id, opts) do
      {:ok, %{ledger: ledger, log: log}}
    end
  end

  @doc """
  Every org completed WO whose two sides disagree — the standing R4 read.
  The refused shapes:

    * a `:completed` WO with NO `:production_in` ledger event;
    * a `:completed` WO with NO `:produce` log row;
    * consumption events whose {item, qty} do not match the log's consume
      rows (a bypass that skipped the log, or forged one);
    * a produce cost that differs from the stamped `actual_unit_cost_cents`
      beyond ±1 (the floor-division rounding unit).
  """
  def divergences(repo, org_id, opts) do
    wo_resource = Keyword.fetch!(opts, :wo_resource)
    ledger_resource = Keyword.fetch!(opts, :ledger_resource)
    log_resource = Keyword.fetch!(opts, :log_resource)

    wo_table = AshPostgres.DataLayer.Info.table(wo_resource)
    ledger_table = AshPostgres.DataLayer.Info.table(ledger_resource)
    log_table = AshPostgres.DataLayer.Info.table(log_resource)

    wo_org = col(wo_resource, :org_id)
    wo_id = col(wo_resource, :id)
    wo_status = col(wo_resource, :status)
    wo_unit_cost = col(wo_resource, :actual_unit_cost_cents)
    wo_item = col(wo_resource, :item_id)
    wo_qty = col(wo_resource, :qty)

    l_org = col(ledger_resource, :org_id)
    l_src_id = col(ledger_resource, :source_id)
    l_src_key = col(ledger_resource, :source_key)
    l_kind = col(ledger_resource, :kind)
    l_item = col(ledger_resource, :item_id)
    l_qty = col(ledger_resource, :qty)
    l_cost = col(ledger_resource, :unit_cost_cents)
    l_id = col(ledger_resource, :id)

    g_org = col(log_resource, :org_id)
    g_wo = col(log_resource, :work_order_id)
    g_kind = col(log_resource, :entry_kind)
    g_item = col(log_resource, :item_id)
    g_qty = col(log_resource, :qty)

    # Consumption comparison: per {item, qty} multiset on each side.
    case repo.query(
           """
           WITH led AS (
             SELECT #{l_item} AS item, SUM(#{l_qty}) AS qty, SUM(#{l_qty} * #{l_cost}) AS value
             FROM #{ledger_table}
             WHERE #{l_org} = $1 AND #{l_src_key} = '#{@source_key}' AND #{l_kind} = 'production_consume'
             GROUP BY #{l_item}
           ),
           log AS (
             SELECT #{g_item} AS item, SUM(#{g_qty}) AS qty
             FROM #{log_table}
             WHERE #{g_org} = $1 AND #{g_kind} = 'consume'
             GROUP BY #{g_item}
           ),
           wo AS (
             SELECT w.#{wo_id} AS wid, w.#{wo_item} AS item, w.#{wo_qty} AS qty,
                    w.#{wo_status} AS status, w.#{wo_unit_cost} AS unit_cost,
                    COALESCE(p.#{l_id}::text, '') IS NOT NULL AS has_produce,
                    COALESCE(g.#{g_item}::text, '') IS NOT NULL AS has_log_produce
             FROM #{wo_table} w
             LEFT JOIN #{ledger_table} p
               ON p.#{l_src_id} = w.#{wo_id} AND p.#{l_org} = $1
              AND p.#{l_src_key} = '#{@source_key}' AND p.#{l_kind} = 'production_in'
             LEFT JOIN #{log_table} g
               ON g.#{g_wo} = w.#{wo_id} AND g.#{g_org} = $1 AND g.#{g_kind} = 'produce'
             WHERE w.#{wo_org} = $1
           )
           SELECT w.wid,
                  (w.status = 'completed' AND NOT w.has_produce),
                  (w.status = 'completed' AND NOT w.has_log_produce),
                  EXISTS (
                    SELECT 1 FROM led l FULL OUTER JOIN log g ON l.item = g.item
                    WHERE COALESCE(l.qty, 0) <> COALESCE(g.qty, 0)
                       OR l.item IS NULL OR g.item IS NULL
                  ),
                  w.item, w.qty, w.unit_cost,
                  (SELECT #{l_cost} FROM #{ledger_table} p2
                    WHERE p2.#{l_src_id} = w.wid AND p2.#{l_org} = $1
                      AND p2.#{l_src_key} = '#{@source_key}' AND p2.#{l_kind} = 'production_in'
                    LIMIT 1)
           FROM wo w
           """,
           [dump_uuid(org_id)]
         ) do
      {:ok, %{rows: rows}} ->
        rows
        |> Enum.flat_map(fn [wid, no_produce, no_log_produce, consumption_mismatch, item, qty,
                              unit_cost, produce_cost] ->
           reasons = []

           reasons =
             if no_produce, do: [:no_produce_event | reasons], else: reasons

           reasons =
             if no_log_produce, do: [:no_produce_log_row | reasons], else: reasons

           reasons =
             if consumption_mismatch, do: [:consumption_mismatch | reasons], else: reasons

           reasons =
             if is_integer(unit_cost) and produce_cost != nil and
                  abs(produce_cost - unit_cost) > 1,
                do: [:produce_cost_mismatch | reasons],
                else: reasons

           case reasons do
             [] ->
               []

             reasons ->
               [
                 %{
                   work_order_id: to_uuid(wid),
                   reasons: reasons,
                   produce_cost: to_i(produce_cost),
                   stamped_unit_cost: to_i(unit_cost),
                   finished_item: to_uuid(item),
                   finished_qty: to_i(qty)
                 }
               ]
           end
         end)
         |> then(&{:ok, &1})

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── the two legs ────────────────────────────────────────────────────────────

  defp ledger_leg(repo, org_id, wo_id, opts) do
    ledger_resource = Keyword.fetch!(opts, :ledger_resource)
    table = AshPostgres.DataLayer.Info.table(ledger_resource)
    org = col(ledger_resource, :org_id)
    src_id = col(ledger_resource, :source_id)
    src_key = col(ledger_resource, :source_key)
    kind = col(ledger_resource, :kind)
    qty = col(ledger_resource, :qty)
    cost = col(ledger_resource, :unit_cost_cents)

    case repo.query(
           """
           SELECT
             COALESCE(SUM(#{qty}) FILTER (WHERE #{kind} = 'production_consume'), 0),
             COALESCE(SUM(#{qty} * #{cost}) FILTER (WHERE #{kind} = 'production_consume'), 0),
             (SELECT #{cost} FROM #{table} WHERE #{src_id} = $2 AND #{org} = $1
               AND #{src_key} = '#{@source_key}' AND #{kind} = 'production_in' LIMIT 1),
             (SELECT #{qty} FROM #{table} WHERE #{src_id} = $2 AND #{org} = $1
               AND #{src_key} = '#{@source_key}' AND #{kind} = 'production_in' LIMIT 1)
           FROM #{table}
           WHERE #{org} = $1 AND #{src_id} = $2
           """,
           [dump_uuid(org_id), dump_uuid(wo_id)]
         ) do
      {:ok, %{rows: []}} ->
        {:ok, %{consume_qty: 0, consume_value: 0, produce_cost: nil, produce_qty: nil}}

      {:ok, %{rows: [[consume_qty, consume_value, produce_cost, produce_qty]]}} ->
        {:ok,
         %{
           consume_qty: to_i(consume_qty),
           consume_value: to_i(consume_value),
           produce_cost: to_i(produce_cost),
           produce_qty: to_i(produce_qty)
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp log_leg(repo, org_id, wo_id, opts) do
    log_resource = Keyword.fetch!(opts, :log_resource)
    table = AshPostgres.DataLayer.Info.table(log_resource)
    org = col(log_resource, :org_id)
    wo = col(log_resource, :work_order_id)
    kind = col(log_resource, :entry_kind)
    qty = col(log_resource, :qty)
    cost = col(log_resource, :unit_cost_cents)
    adj = col(log_resource, :adjustment_cents)

    case repo.query(
           """
           SELECT
             COALESCE(SUM(#{qty}) FILTER (WHERE #{kind} = 'consume'), 0),
             (SELECT #{cost} FROM #{table} WHERE #{wo} = $2 AND #{org} = $1
               AND #{kind} = 'produce' LIMIT 1),
             COALESCE(SUM(#{adj}) FILTER (WHERE #{kind} = 'adjust'), 0)
           FROM #{table}
           WHERE #{org} = $1 AND #{wo} = $2
           """,
           [dump_uuid(org_id), dump_uuid(wo_id)]
         ) do
      {:ok, %{rows: [[consume_qty, produce_cost, adjustments]]}} ->
        {:ok,
         %{
           consume_qty: to_i(consume_qty),
           produce_cost: to_i(produce_cost),
           adjustments: to_i(adjustments)
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── helpers ─────────────────────────────────────────────────────────────────

  defp col(resource, name) do
    case Ash.Resource.Info.attribute(resource, name) do
      nil -> raise ArgumentError, "no attribute #{inspect(name)} on #{inspect(resource)}"
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

  defp to_uuid(<<_::128>> = bin), do: Ecto.UUID.load!(bin)
  defp to_uuid(bin) when is_binary(bin), do: bin
  defp to_uuid(nil), do: nil

  defp to_i(nil), do: nil
  defp to_i(v) when is_integer(v), do: v
  defp to_i(%Decimal{} = d), do: Decimal.to_integer(d)

  defp to_i(bin) when is_binary(bin) do
    case Integer.parse(bin) do
      {i, ""} -> i
      _ -> 0
    end
  end

  defp to_i(_), do: 0
end
