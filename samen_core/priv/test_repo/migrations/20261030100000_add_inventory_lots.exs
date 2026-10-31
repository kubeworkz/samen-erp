defmodule SamenCore.TestRepo.Migrations.AddInventoryLots do
  @moduledoc """
  WS-ACCT Phase 4 (ADR-054 D3) — lots and foundry WIP in the `samen_core` test
  fixture (`SamenCore.Support.InventoryFixture`, abbrev `slt` for the lot):

    * `slt_lot` — one physical production lot: `code` (unique per org), the
      `item` it produces, `supplier_id` (a plain cross-scope vendor id),
      `stage ∈ {design, mask, fab, dice, assembly, test, delivered}`, wafer and
      die counts, `fab_order_id`, and the Finance `cost_object_id` its GL
      lines are dimensioned by (R7).
    * `swh_warehouse.swh_kind` — `owned` / `consignment` / `supplier`, so
      wafers at a foundry are ordinary stock at a SUPPLIER LOCATION rather than
      a parallel WIP register (ADR-049 §4).

  No second quantity mechanism moves with this migration: a lot's cost is the
  Σ of `skl_stock_ledger` events whose object-ref names it
  (`source_key = 'lot'`), and R7
  (`Samen.Scopes.Inventory.ReconcileLot`) reads that against the WIP balance
  the journal carries.

  Catalog rows via `catalog_sync/1,2` in the SAME transaction (ADR-004): the
  new resource in full and ONLY the new column on the already-catalogued
  `Warehouse`.
  """

  use Samen.Migration

  @resources [SamenCore.Support.InventoryFixture.Lot]

  def up do
    create table(:slt_lot, primary_key: false) do
      add(:slt_code, :text, null: false)
      add(:slt_stage, :text, null: false, default: "design")
      add(:slt_wafer_count, :integer, null: false, default: 0)
      add(:slt_die_expected, :integer, null: false, default: 0)
      add(:slt_die_actual, :integer, null: false, default: 0)
      add(:slt_supplier_id, :uuid)
      add(:slt_fab_order_id, :uuid)
      add(:slt_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:slt_org_id, :uuid, null: false)
      add(:slt_inserted_at, :utc_datetime, null: false)
      add(:slt_updated_at, :utc_datetime, null: false)

      add(
        :slt_item_id,
        references(:sit_item,
          column: :sit_id,
          name: "slt_lot_slt_item_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(
        :slt_cost_object_id,
        references(:cob_cost_object,
          column: :cob_id,
          name: "slt_lot_slt_cost_object_id_fkey",
          type: :uuid
        ),
        null: false
      )
    end

    create(index(:slt_lot, [:slt_org_id]))
    create(unique_index(:slt_lot, [:slt_org_id, :slt_code]))
    create(index(:slt_lot, [:slt_item_id]))
    create(index(:slt_lot, [:slt_cost_object_id]))

    create(
      constraint(:slt_lot, :slt_stage_valid,
        check: "slt_stage IN ('design', 'mask', 'fab', 'dice', 'assembly', 'test', 'delivered')"
      )
    )

    create(
      constraint(:slt_lot, :slt_counts_non_negative,
        check: "slt_wafer_count >= 0 AND slt_die_expected >= 0 AND slt_die_actual >= 0"
      )
    )

    alter table(:swh_warehouse) do
      add(:swh_kind, :text, null: false, default: "owned")
    end

    create(
      constraint(:swh_warehouse, :swh_kind_valid,
        check: "swh_kind IN ('owned', 'consignment', 'supplier')"
      )
    )

    catalog_sync(@resources)

    catalog_sync([SamenCore.Support.InventoryFixture.Warehouse], only: [:kind])
  end

  def down do
    catalog_sync_down([SamenCore.Support.InventoryFixture.Warehouse], only: [:kind])

    catalog_sync_down(@resources)

    drop(constraint(:swh_warehouse, :swh_kind_valid))

    alter table(:swh_warehouse) do
      remove(:swh_kind)
    end

    drop(table(:slt_lot))
  end
end
