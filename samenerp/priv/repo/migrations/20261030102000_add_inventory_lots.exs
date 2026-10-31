defmodule Samenerp.Repo.Migrations.AddInventoryLots do
  @moduledoc """
  WS-ACCT Phase 4 (ADR-054 D3) — lots and foundry WIP on the REAL host
  (`Samenerp.Erp`, lot abbrev `elt`):

    * `elt_lot` — one physical production lot on the Kubeworkz books, with the
      Finance cost object (`eco_cost_object`) its GL lines are dimensioned by;
    * `enw_warehouse.enw_kind` — `owned` / `consignment` / `supplier`, so the
      foundry and the assembly-and-test partner are stock LOCATIONS. "WIP –
      Foundry" becomes the GL presentation of that stock (ADR-054 D3), not a
      second register: the lot's cost is the Σ of `enl_stock_ledger` events
      anchored `source_key = 'lot'`.

  R7 (`Samen.Scopes.Inventory.ReconcileLot`) is the standing read: supplier-
  location stock value per lot == the WIP balance the journal carries for that
  lot, and the stage cost is the same ledger read over every location.

  Catalog rows via `catalog_sync/1,2` in the SAME transaction (ADR-004).
  """

  use Samen.Migration

  @resources [Samenerp.Erp.Lot]

  def up do
    create table(:elt_lot, primary_key: false) do
      add(:elt_code, :text, null: false)
      add(:elt_stage, :text, null: false, default: "design")
      add(:elt_wafer_count, :integer, null: false, default: 0)
      add(:elt_die_expected, :integer, null: false, default: 0)
      add(:elt_die_actual, :integer, null: false, default: 0)
      add(:elt_supplier_id, :uuid)
      add(:elt_fab_order_id, :uuid)
      add(:elt_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:elt_org_id, :uuid, null: false)
      add(:elt_inserted_at, :utc_datetime, null: false)
      add(:elt_updated_at, :utc_datetime, null: false)

      add(
        :elt_item_id,
        references(:eni_item,
          column: :eni_id,
          name: "elt_lot_elt_item_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(
        :elt_cost_object_id,
        references(:eco_cost_object,
          column: :eco_id,
          name: "elt_lot_elt_cost_object_id_fkey",
          type: :uuid
        ),
        null: false
      )
    end

    create(index(:elt_lot, [:elt_org_id]))
    create(unique_index(:elt_lot, [:elt_org_id, :elt_code]))
    create(index(:elt_lot, [:elt_item_id]))
    create(index(:elt_lot, [:elt_cost_object_id]))

    create(
      constraint(:elt_lot, :elt_stage_valid,
        check: "elt_stage IN ('design', 'mask', 'fab', 'dice', 'assembly', 'test', 'delivered')"
      )
    )

    create(
      constraint(:elt_lot, :elt_counts_non_negative,
        check: "elt_wafer_count >= 0 AND elt_die_expected >= 0 AND elt_die_actual >= 0"
      )
    )

    alter table(:enw_warehouse) do
      add(:enw_kind, :text, null: false, default: "owned")
    end

    create(
      constraint(:enw_warehouse, :enw_kind_valid,
        check: "enw_kind IN ('owned', 'consignment', 'supplier')"
      )
    )

    catalog_sync(@resources)

    catalog_sync([Samenerp.Erp.Warehouse], only: [:kind])
  end

  def down do
    catalog_sync_down([Samenerp.Erp.Warehouse], only: [:kind])

    catalog_sync_down(@resources)

    drop(constraint(:enw_warehouse, :enw_kind_valid))

    alter table(:enw_warehouse) do
      remove(:enw_kind)
    end

    drop(table(:elt_lot))
  end
end
