defmodule Samen.Scopes.Inventory.LedgerSum do
  @moduledoc """
  The live ledger sums (WS-ERP E3): bare SQL over the append-only
  `StockLedger` table — the single arithmetic substrate the NegativeStock
  guard, `StockLevelSync`, and `ReconcileStock` all share, so the layers
  can never disagree about what "on hand" MEANS (they can only disagree
  about WHEN they read it: the guard reads mid-transaction, the sync
  writes after the event lands, the reconcile reads after commit).

  * `on_hand/5` — Σ `qty` for an org's `(item, warehouse)` pair.
  * `org_on_hand/3` — Σ `qty` over the whole org's ledger (R3's org-wide leg).
  """

  @doc "Σ `qty` for the org's (item, warehouse) pair — the live in-transaction sum."
  def on_hand(repo, ledger_resource, org_id, item_id, warehouse_id) do
    table = AshPostgres.DataLayer.Info.table(ledger_resource)
    org = attr_source(ledger_resource, :org_id)
    item = attr_source(ledger_resource, :item_id)
    warehouse = attr_source(ledger_resource, :warehouse_id)
    qty = attr_source(ledger_resource, :qty)

    case repo.query(
           """
           SELECT COALESCE(SUM(#{qty}), 0) FROM #{table}
           WHERE #{org} = $1 AND #{item} = $2 AND #{warehouse} = $3
           """,
           [dump_uuid(org_id), dump_uuid(item_id), dump_uuid(warehouse_id)]
         ) do
      {:ok, %{rows: [[total]]}} -> to_i(total)
      {:error, reason} -> raise "ledger on_hand sum failed: #{inspect(reason)}"
    end
  end

  @doc "Σ `qty` over the whole org's ledger (R3's org-wide leg)."
  def org_on_hand(repo, ledger_resource, org_id) do
    table = AshPostgres.DataLayer.Info.table(ledger_resource)
    org = attr_source(ledger_resource, :org_id)
    qty = attr_source(ledger_resource, :qty)

    case repo.query(
           "SELECT COALESCE(SUM(#{qty}), 0) FROM #{table} WHERE #{org} = $1",
           [dump_uuid(org_id)]
         ) do
      {:ok, %{rows: [[total]]}} -> to_i(total)
      {:error, reason} -> raise "ledger org sum failed: #{inspect(reason)}"
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp attr_source(resource, name) do
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
