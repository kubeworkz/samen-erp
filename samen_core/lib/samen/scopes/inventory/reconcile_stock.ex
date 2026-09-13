defmodule Samen.Scopes.Inventory.ReconcileStock do
  @moduledoc """
  The R3 reconciliation reads (WS-ERP E3; design §6.3): bare SQL sums over
  the ledger, computed INDEPENDENTLY of `StockLevelSync` (the two share no
  code path — the reconciler never reads the level rows it compares
  against its own ledger sums through the sync writer's arithmetic), so a
  bypass that edits the rollup or skips the ledger DIVERGES and the
  red-path fails.

  * `level/5` — the ledger's own `(qty, value)` truth for one
    `(item, warehouse)` pair: `on_hand` == Σ `qty`; `stock_value` ==
    Σ (`qty` × `unit_cost_cents`).
  * `divergences/3` — every org pair whose LEVEL row disagrees with the
    ledger's sums (qty OR value) — the standing reconciliation read the
    E3 suite's green paths assert empty, and sabotage 304's hand-edit
    makes non-empty.
  * `org_totals/2` — the org-wide (Σ qty, Σ value) over the ledger —
    R3's org-wide green path.
  """

  @doc """
  The ledger's own (qty, value) truth for one (item, warehouse) pair:
  `on_hand` == Σ `qty`; `stock_value` == Σ (qty × unit_cost_cents).
  """
  def level(repo, ledger_resource, org_id, item_id, warehouse_id) do
    table = AshPostgres.DataLayer.Info.table(ledger_resource)
    org = col(ledger_resource, :org_id)
    item = col(ledger_resource, :item_id)
    warehouse = col(ledger_resource, :warehouse_id)
    qty = col(ledger_resource, :qty)
    cost = col(ledger_resource, :unit_cost_cents)

    case repo.query(
           """
           SELECT COALESCE(SUM(#{qty}), 0), COALESCE(SUM(#{qty} * #{cost}), 0)
           FROM #{table}
           WHERE #{org} = $1 AND #{item} = $2 AND #{warehouse} = $3
           """,
           [dump_uuid(org_id), dump_uuid(item_id), dump_uuid(warehouse_id)]
         ) do
      {:ok, %{rows: [[on_hand, value]]}} ->
        {:ok, %{on_hand: to_i(on_hand), stock_value: to_i(value)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Every org pair whose `StockLevel` row disagrees with the ledger's own
  sums (qty OR value) — the standing R3 read. Compares the rollup rows
  against sums computed FRESH from the ledger (never through the sync
  writer's arithmetic), so a hand-edited level row or a skipped event
  shows up here.
  """
  def divergences(repo, ledger_resource, level_resource, org_id) do
    ledger_table = AshPostgres.DataLayer.Info.table(ledger_resource)
    level_table = AshPostgres.DataLayer.Info.table(level_resource)

    l_org = col(ledger_resource, :org_id)
    l_item = col(ledger_resource, :item_id)
    l_wh = col(ledger_resource, :warehouse_id)
    l_qty = col(ledger_resource, :qty)
    l_cost = col(ledger_resource, :unit_cost_cents)

    v_org = col(level_resource, :org_id)
    v_item = col(level_resource, :item_id)
    v_wh = col(level_resource, :warehouse_id)
    v_qty = col(level_resource, :qty_on_hand)
    v_value = col(level_resource, :stock_value_cents)
    v_id = col(level_resource, :id)

    # A LEFT JOIN from the ledger's pairs: a pair with NO level row (or a
    # level row whose sums disagree) diverges. An org with an EMPTY ledger
    # produces no pairs at all (GROUP BY over zero rows), so it cannot
    # false-positive against its own absence of level rows.
    case repo.query(
           """
           SELECT pairs.#{l_item}, pairs.#{l_wh},
                  COALESCE(v.#{v_qty}, 0), pairs.on_hand,
                  COALESCE(v.#{v_value}, 0), pairs.stock_value
           FROM (
             SELECT #{l_item}, #{l_wh},
                    SUM(#{l_qty}) AS on_hand,
                    SUM(#{l_qty} * #{l_cost}) AS stock_value
             FROM #{ledger_table}
             WHERE #{l_org} = $1
             GROUP BY #{l_item}, #{l_wh}
           ) pairs
           LEFT JOIN #{level_table} v
             ON v.#{v_org} = $1 AND v.#{v_item} = pairs.#{l_item} AND v.#{v_wh} = pairs.#{l_wh}
           WHERE v.#{v_id} IS NULL
              OR v.#{v_qty} IS DISTINCT FROM pairs.on_hand
              OR v.#{v_value} IS DISTINCT FROM pairs.stock_value
           """,
           [dump_uuid(org_id)]
         ) do
      {:ok, %{rows: rows}} ->
        {:ok,
         Enum.map(rows, fn [item_id, warehouse_id, level_qty, ledger_qty, level_value, ledger_value] ->
           %{
             item_id: to_uuid(item_id),
             warehouse_id: to_uuid(warehouse_id),
             level_qty: to_i(level_qty),
             ledger_qty: to_i(ledger_qty),
             level_value: to_i(level_value),
             ledger_value: to_i(ledger_value)
           }
         end)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "The org-wide (Σ qty, Σ value) over the ledger — R3's org-wide leg."
  def org_totals(repo, ledger_resource, org_id) do
    table = AshPostgres.DataLayer.Info.table(ledger_resource)
    org = col(ledger_resource, :org_id)
    qty = col(ledger_resource, :qty)
    cost = col(ledger_resource, :unit_cost_cents)

    case repo.query(
           """
           SELECT COALESCE(SUM(#{qty}), 0), COALESCE(SUM(#{qty} * #{cost}), 0)
           FROM #{table}
           WHERE #{org} = $1
           """,
           [dump_uuid(org_id)]
         ) do
      {:ok, %{rows: [[qty_total, value_total]]}} ->
        {:ok, %{on_hand: to_i(qty_total), stock_value: to_i(value_total)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────────

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

  defp to_i(nil), do: 0
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
