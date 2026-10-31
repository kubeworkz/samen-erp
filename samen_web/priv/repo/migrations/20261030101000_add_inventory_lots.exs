defmodule Samen.WebTest.Repo.Migrations.AddInventoryLots do
  @moduledoc """
  WS-ACCT Phase 4 (ADR-054 D3) — lots and foundry WIP on the `samen_web` test
  host (`Samen.WebTest.Erp`, lot abbrev `ilt`):

    * `ilt_lot` — one physical production lot, including the Finance cost
      object (`fco_cost_object`) its GL lines are dimensioned by;
    * `inw_warehouse.inw_kind` — `owned` / `consignment` / `supplier`.

  A lot is stock events, not a second register: its cost is the Σ of
  `inl_stock_ledger` events anchored `source_key = 'lot'`, and R7
  (`Samen.Scopes.Inventory.ReconcileLot`) reads supplier-location stock against
  the WIP GL balance. Catalog rows via `catalog_sync/1,2` in the same
  transaction (ADR-004).
  """

  use Samen.Migration

  @resources [Samen.WebTest.Erp.Lot]

  def up do
    create table(:ilt_lot, primary_key: false) do
      add(:ilt_code, :text, null: false)
      add(:ilt_stage, :text, null: false, default: "design")
      add(:ilt_wafer_count, :integer, null: false, default: 0)
      add(:ilt_die_expected, :integer, null: false, default: 0)
      add(:ilt_die_actual, :integer, null: false, default: 0)
      add(:ilt_supplier_id, :uuid)
      add(:ilt_fab_order_id, :uuid)
      add(:ilt_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:ilt_org_id, :uuid, null: false)
      add(:ilt_inserted_at, :utc_datetime, null: false)
      add(:ilt_updated_at, :utc_datetime, null: false)

      add(
        :ilt_item_id,
        references(:ini_item,
          column: :ini_id,
          name: "ilt_lot_ilt_item_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(
        :ilt_cost_object_id,
        references(:fco_cost_object,
          column: :fco_id,
          name: "ilt_lot_ilt_cost_object_id_fkey",
          type: :uuid
        ),
        null: false
      )
    end

    create(index(:ilt_lot, [:ilt_org_id]))
    create(unique_index(:ilt_lot, [:ilt_org_id, :ilt_code]))
    create(index(:ilt_lot, [:ilt_item_id]))
    create(index(:ilt_lot, [:ilt_cost_object_id]))

    create(
      constraint(:ilt_lot, :ilt_stage_valid,
        check: "ilt_stage IN ('design', 'mask', 'fab', 'dice', 'assembly', 'test', 'delivered')"
      )
    )

    create(
      constraint(:ilt_lot, :ilt_counts_non_negative,
        check: "ilt_wafer_count >= 0 AND ilt_die_expected >= 0 AND ilt_die_actual >= 0"
      )
    )

    alter table(:inw_warehouse) do
      add(:inw_kind, :text, null: false, default: "owned")
    end

    create(
      constraint(:inw_warehouse, :inw_kind_valid,
        check: "inw_kind IN ('owned', 'consignment', 'supplier')"
      )
    )

    catalog_sync(@resources)

    catalog_sync([Samen.WebTest.Erp.Warehouse], only: [:kind])
  end

  def down do
    catalog_sync_down([Samen.WebTest.Erp.Warehouse], only: [:kind])

    catalog_sync_down(@resources)

    drop(constraint(:inw_warehouse, :inw_kind_valid))

    alter table(:inw_warehouse) do
      remove(:inw_kind)
    end

    drop(table(:ilt_lot))
  end
end
