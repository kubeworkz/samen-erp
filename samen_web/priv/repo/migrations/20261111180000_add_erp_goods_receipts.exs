defmodule Samen.WebTest.Repo.Migrations.AddErpGoodsReceipts do
  @moduledoc """
  The goods-receipt detail fixture: the receipt header and its materialized
  receipt lines (the AP match panel's link destination).

  The base ERP mount deliberately left these two tables out while the web
  surfaces did not read receipts. The goods-receipt detail surface now loads
  `GoodsReceipt.lines`, so this migration tables the same rows the production
  mount carries, without the prod-only belt triggers.
  """
  use Samen.Migration

  @resources [
    Samen.WebTest.Erp.GoodsReceipt,
    Samen.WebTest.Erp.ReceiptLine
  ]

  def up do
    create table(:igr_goods_receipt, primary_key: false) do
      add(:igr_number, :text, null: false)
      add(:igr_received_date, :date, null: false)
      add(:igr_memo, :text)
      add(:igr_status, :text, null: false, default: "draft")
      add(:igr_posted_entry_id, :uuid)
      add(:igr_received_at, :utc_datetime)
      add(:igr_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:igr_org_id, :uuid, null: false)
      add(:igr_inserted_at, :utc_datetime, null: false)
      add(:igr_updated_at, :utc_datetime, null: false)

      add(
        :igr_purchase_order_id,
        references(:ipo_purchase_order,
          column: :ipo_id,
          name: "igr_goods_receipt_igr_purchase_order_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(
        :igr_warehouse_id,
        references(:inw_warehouse,
          column: :inw_id,
          name: "igr_goods_receipt_igr_warehouse_id_fkey",
          type: :uuid
        ),
        null: false
      )
    end

    create(index(:igr_goods_receipt, [:igr_org_id]))
    create(index(:igr_goods_receipt, [:igr_org_id, :igr_number], unique: true))
    create(index(:igr_goods_receipt, [:igr_purchase_order_id]))
    create(index(:igr_goods_receipt, [:igr_posted_entry_id]))

    create(
      constraint(:igr_goods_receipt, :igr_status_valid, check: "igr_status IN ('draft','posted')")
    )

    create table(:ird_receipt_line, primary_key: false) do
      add(:ird_qty, :bigint, null: false)
      add(:ird_unit_cost_cents, :bigint, null: false, default: 0)
      add(:ird_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:ird_org_id, :uuid, null: false)
      add(:ird_inserted_at, :utc_datetime, null: false)
      add(:ird_updated_at, :utc_datetime, null: false)

      add(
        :ird_goods_receipt_id,
        references(:igr_goods_receipt,
          column: :igr_id,
          name: "ird_receipt_line_ird_goods_receipt_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(
        :ird_po_line_id,
        references(:ipl_po_line,
          column: :ipl_id,
          name: "ird_receipt_line_ird_po_line_id_fkey",
          type: :uuid
        ),
        null: false
      )
    end

    create(index(:ird_receipt_line, [:ird_org_id]))
    create(index(:ird_receipt_line, [:ird_goods_receipt_id]))
    create(index(:ird_receipt_line, [:ird_po_line_id]))

    create(constraint(:ird_receipt_line, :ird_qty_positive, check: "ird_qty > 0"))

    create(
      constraint(:ird_receipt_line, :ird_unit_cost_non_negative,
        check: "ird_unit_cost_cents >= 0"
      )
    )

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    drop(table(:ird_receipt_line))
    drop(table(:igr_goods_receipt))
  end
end
