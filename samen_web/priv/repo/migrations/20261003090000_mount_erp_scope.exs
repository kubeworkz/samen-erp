defmodule Samen.WebTest.Repo.Migrations.MountErpScope do
  @moduledoc """
  Mounts the ERP Finance + Inventory scopes into the samen_web test host's
  Postgres — the test-side twin of `Samenerp.Repo.Migrations.MountErpScope`,
  at the scopes' DEFAULT abbrevs (`fca`/`fje`/`fjl`/`fai`/`ini`/`inw`/`ibo`/
  `ipo`/`ipl`/`iwo`) the `Samen.WebTest.Erp` domain mounts with.

  DELIBERATE SUBSET: only the tables the six `Samen.Web.Erp` surfaces read and
  write — CoA, journal (+ its lines), AP bill, item, warehouse, BOM (the work
  order's FK target), PO (+ its lines), work order. The scope materializes the
  full 26-resource domain; the resources never read here (budgets, stock
  ledger/level, goods receipts, sales orders, production log, FX, …) stay
  untabled — the web tests never query them.

  NO BELT TRIGGERS (the posture of every samen_web scope mount — this repo
  carries exactly one trigger file): the raw-SQL twin guards are prod-DDL,
  and the web LiveView tests exercise the ASH-level guards the UI path
  actually rides (`UnbalancedEntry`/`EntryLines`/`ApLines`/`PoState`/
  `WoState`/`SameOrgFk`). Column-level CHECKs and FKs that shape legitimate
  UI-path writes are kept.
  """
  use Samen.Migration

  @resources [
    Samen.WebTest.Erp.Account,
    Samen.WebTest.Erp.JournalEntry,
    Samen.WebTest.Erp.JournalLine,
    Samen.WebTest.Erp.ApInvoice,
    Samen.WebTest.Erp.PaymentReceipt,
    Samen.WebTest.Erp.PostingAccount,
    Samen.WebTest.Erp.Budget,
    Samen.WebTest.Erp.BudgetLine,
    Samen.WebTest.Erp.Item,
    Samen.WebTest.Erp.Warehouse,
    Samen.WebTest.Erp.StockLedger,
    Samen.WebTest.Erp.StockLevel,
    Samen.WebTest.Erp.PurchaseOrder,
    Samen.WebTest.Erp.PoLine,
    Samen.WebTest.Erp.GoodsReceipt,
    Samen.WebTest.Erp.ReceiptLine,
    Samen.WebTest.Erp.SalesOrder,
    Samen.WebTest.Erp.SoLine,
    Samen.WebTest.Erp.Bom,
    Samen.WebTest.Erp.BomLine,
    Samen.WebTest.Erp.WorkOrder,
    Samen.WebTest.Erp.ProductionLog,
    Samen.WebTest.Erp.ExchangeRate,
    Samen.WebTest.Erp.OrgFxSettings,
    Samen.WebTest.Erp.TransferOrder,
    Samen.WebTest.Erp.LandedCost
  ]

  def up do
    # ── fca_account — the chart of accounts (E1) ──────────────────────────
    create table(:fca_account, primary_key: false) do
      add(:fca_code, :text, null: false)
      add(:fca_name, :text, null: false)
      add(:fca_kind, :text, null: false)
      add(:fca_normal_side, :text, null: false)
      add(:fca_currency, :text, null: false, default: "USD")
      add(:fca_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:fca_org_id, :uuid, null: false)
      add(:fca_inserted_at, :utc_datetime, null: false)
      add(:fca_updated_at, :utc_datetime, null: false)
      add(:fca_archived_at, :utc_datetime_usec)

      add(
        :fca_parent_id,
        references(:fca_account,
          column: :fca_id,
          name: "fca_account_fca_parent_id_fkey",
          type: :uuid
        )
      )
    end

    create(index(:fca_account, [:fca_org_id]))
    create(index(:fca_account, [:fca_parent_id]))
    create(index(:fca_account, [:fca_org_id, :fca_code], unique: true))

    # ── fje_journal_entry — the ledger event (E1) ─────────────────────────
    create table(:fje_journal_entry, primary_key: false) do
      add(:fje_entry_date, :date, null: false)
      add(:fje_memo, :text)
      add(:fje_status, :text, null: false, default: "draft")
      add(:fje_source_key, :text)
      add(:fje_source_id, :uuid)
      add(:fje_posted_at, :utc_datetime)
      add(:fje_voided_entry_id, :uuid)
      add(:fje_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:fje_org_id, :uuid, null: false)
      add(:fje_inserted_at, :utc_datetime, null: false)
      add(:fje_updated_at, :utc_datetime, null: false)
      add(:fje_archived_at, :utc_datetime_usec)
    end

    create(index(:fje_journal_entry, [:fje_org_id]))
    create(index(:fje_journal_entry, [:fje_source_key, :fje_source_id]))

    create(
      constraint(:fje_journal_entry, :fje_status_valid,
        check: "fje_status IN ('draft', 'posted', 'void')"
      )
    )

    # ── fjl_journal_line — the posting (E1) ───────────────────────────────
    create table(:fjl_journal_line, primary_key: false) do
      add(:fjl_debit_cents, :bigint, null: false, default: 0)
      add(:fjl_credit_cents, :bigint, null: false, default: 0)
      add(:fjl_memo, :text)
      add(:fjl_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:fjl_org_id, :uuid, null: false)
      add(:fjl_inserted_at, :utc_datetime, null: false)
      add(:fjl_updated_at, :utc_datetime, null: false)

      add(
        :fjl_entry_id,
        references(:fje_journal_entry,
          column: :fje_id,
          name: "fjl_journal_line_fjl_entry_id_fkey",
          type: :uuid
        )
      )

      add(
        :fjl_account_id,
        references(:fca_account,
          column: :fca_id,
          name: "fjl_journal_line_fjl_account_id_fkey",
          type: :uuid
        )
      )
    end

    create(index(:fjl_journal_line, [:fjl_org_id]))
    create(index(:fjl_journal_line, [:fjl_entry_id]))
    create(index(:fjl_journal_line, [:fjl_account_id]))

    create(
      constraint(:fjl_journal_line, :fjl_amounts_positive,
        check: "fjl_debit_cents >= 0 AND fjl_credit_cents >= 0"
      )
    )

    # ── fai_ap_invoice — the AP vendor bill (E2) ──────────────────────────
    create table(:fai_ap_invoice, primary_key: false) do
      add(:fai_vendor_id, :uuid, null: false)
      add(:fai_number, :text, null: false)
      add(:fai_bill_date, :date, null: false)
      add(:fai_due_date, :date)
      add(:fai_memo, :text)
      add(:fai_lines, :map, null: false)
      add(:fai_status, :text, null: false, default: "draft")
      add(:fai_posted_entry_id, :uuid)
      add(:fai_posted_at, :utc_datetime)
      add(:fai_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:fai_org_id, :uuid, null: false)
      add(:fai_inserted_at, :utc_datetime, null: false)
      add(:fai_updated_at, :utc_datetime, null: false)
    end

    create(index(:fai_ap_invoice, [:fai_org_id]))
    create(index(:fai_ap_invoice, [:fai_vendor_id]))
    create(index(:fai_ap_invoice, [:fai_org_id, :fai_number], unique: true))

    create(
      constraint(:fai_ap_invoice, :fai_status_valid,
        check: "fai_status IN ('draft','approved','paid','void')"
      )
    )

    # ── ini_item — the item master (E3) ───────────────────────────────────
    create table(:ini_item, primary_key: false) do
      add(:ini_sku, :text, null: false)
      add(:ini_name, :text, null: false)
      add(:ini_kind, :text, null: false, default: "stocked")
      add(:ini_uom, :text, null: false, default: "unit")
      add(:ini_reorder_point, :integer)
      add(:ini_default_income_account_id, :uuid)
      add(:ini_default_expense_account_id, :uuid)
      add(:ini_default_inventory_account_id, :uuid)
      add(:ini_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:ini_org_id, :uuid, null: false)
      add(:ini_inserted_at, :utc_datetime, null: false)
      add(:ini_updated_at, :utc_datetime, null: false)
    end

    create(index(:ini_item, [:ini_org_id]))
    create(index(:ini_item, [:ini_org_id, :ini_sku], unique: true))

    # ── inw_warehouse — a stock location (E3; FK target of PO/WO) ─────────
    create table(:inw_warehouse, primary_key: false) do
      add(:inw_code, :text, null: false)
      add(:inw_name, :text, null: false)
      add(:inw_allow_negative, :boolean, null: false, default: false)
      add(:inw_is_sellable, :boolean, null: false, default: true)
      add(:inw_address, :text)
      add(:inw_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:inw_org_id, :uuid, null: false)
      add(:inw_inserted_at, :utc_datetime, null: false)
      add(:inw_updated_at, :utc_datetime, null: false)
    end

    create(index(:inw_warehouse, [:inw_org_id]))
    create(index(:inw_warehouse, [:inw_org_id, :inw_code], unique: true))

    # ── ibo_bom — the bill of materials (E6; WO FK target) ────────────────
    create table(:ibo_bom, primary_key: false) do
      add(:ibo_version, :integer, null: false)
      add(:ibo_is_active, :boolean, null: false, default: true)
      add(:ibo_name, :text, null: false)
      add(:ibo_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:ibo_org_id, :uuid, null: false)
      add(:ibo_inserted_at, :utc_datetime, null: false)
      add(:ibo_updated_at, :utc_datetime, null: false)

      add(
        :ibo_item_id,
        references(:ini_item, column: :ini_id, name: "ibo_bom_ibo_item_id_fkey", type: :uuid)
      )
    end

    create(index(:ibo_bom, [:ibo_org_id]))
    create(index(:ibo_bom, [:ibo_org_id, :ibo_item_id, :ibo_version], unique: true))

    create(
      unique_index(:ibo_bom, [:ibo_org_id, :ibo_item_id],
        where: "ibo_is_active",
        name: :ibo_bom_one_active_version_idx
      )
    )

    # ── ipo_purchase_order — the PO head (E4) ─────────────────────────────
    create table(:ipo_purchase_order, primary_key: false) do
      add(:ipo_vendor_id, :uuid, null: false)
      add(:ipo_number, :text, null: false)
      add(:ipo_order_date, :date, null: false)
      add(:ipo_memo, :text)
      add(:ipo_status, :text, null: false, default: "draft")
      add(:ipo_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:ipo_org_id, :uuid, null: false)
      add(:ipo_inserted_at, :utc_datetime, null: false)
      add(:ipo_updated_at, :utc_datetime, null: false)

      add(
        :ipo_warehouse_id,
        references(:inw_warehouse,
          column: :inw_id,
          name: "ipo_purchase_order_ipo_warehouse_id_fkey",
          type: :uuid
        )
      )
    end

    create(index(:ipo_purchase_order, [:ipo_org_id]))
    create(index(:ipo_purchase_order, [:ipo_org_id, :ipo_number], unique: true))
    create(index(:ipo_purchase_order, [:ipo_org_id, :ipo_vendor_id]))

    create(
      constraint(:ipo_purchase_order, :ipo_status_valid,
        check: "ipo_status IN ('draft','approved','sent','received','closed','void')"
      )
    )

    # ── ipl_po_line — the PO's line row (E4) ──────────────────────────────
    create table(:ipl_po_line, primary_key: false) do
      add(:ipl_qty, :bigint, null: false)
      add(:ipl_unit_cost_cents, :bigint, null: false, default: 0)
      add(:ipl_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:ipl_org_id, :uuid, null: false)
      add(:ipl_inserted_at, :utc_datetime, null: false)
      add(:ipl_updated_at, :utc_datetime, null: false)

      add(
        :ipl_purchase_order_id,
        references(:ipo_purchase_order,
          column: :ipo_id,
          name: "ipl_po_line_ipl_purchase_order_id_fkey",
          type: :uuid
        )
      )

      add(
        :ipl_item_id,
        references(:ini_item,
          column: :ini_id,
          name: "ipl_po_line_ipl_item_id_fkey",
          type: :uuid
        )
      )
    end

    create(index(:ipl_po_line, [:ipl_org_id]))
    create(index(:ipl_po_line, [:ipl_purchase_order_id]))
    create(index(:ipl_po_line, [:ipl_item_id]))

    create(constraint(:ipl_po_line, :ipl_qty_positive, check: "ipl_qty > 0"))

    create(
      constraint(:ipl_po_line, :ipl_unit_cost_non_negative, check: "ipl_unit_cost_cents >= 0")
    )

    # ── iwo_work_order — the manufacturing order (E6) ─────────────────────
    create table(:iwo_work_order, primary_key: false) do
      add(:iwo_number, :text, null: false)
      add(:iwo_qty, :integer, null: false)
      add(:iwo_scheduled_for, :date)
      add(:iwo_memo, :text)
      add(:iwo_status, :text, null: false, default: "draft")
      add(:iwo_bom_snapshot, :jsonb, null: false, default: "[]")
      add(:iwo_actual_material_cents, :bigint)
      add(:iwo_actual_unit_cost_cents, :bigint)
      add(:iwo_bom_version, :integer)
      add(:iwo_released_at, :utc_datetime)
      add(:iwo_completed_at, :utc_datetime)
      add(:iwo_labor_cents, :bigint, null: false, default: 0)
      add(:iwo_overhead_cents, :bigint, null: false, default: 0)
      add(:iwo_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:iwo_org_id, :uuid, null: false)
      add(:iwo_inserted_at, :utc_datetime, null: false)
      add(:iwo_updated_at, :utc_datetime, null: false)

      add(
        :iwo_item_id,
        references(:ini_item,
          column: :ini_id,
          name: "iwo_work_order_iwo_item_id_fkey",
          type: :uuid
        )
      )

      add(
        :iwo_bom_id,
        references(:ibo_bom, column: :ibo_id, name: "iwo_work_order_iwo_bom_id_fkey", type: :uuid)
      )

      add(
        :iwo_warehouse_id,
        references(:inw_warehouse,
          column: :inw_id,
          name: "iwo_work_order_iwo_warehouse_id_fkey",
          type: :uuid
        )
      )
    end

    create(index(:iwo_work_order, [:iwo_org_id]))
    create(index(:iwo_work_order, [:iwo_org_id, :iwo_number], unique: true))
    create(index(:iwo_work_order, [:iwo_org_id, :iwo_item_id]))
    create(index(:iwo_work_order, [:iwo_bom_id]))
    create(index(:iwo_work_order, [:iwo_status]))

    create(
      constraint(:iwo_work_order, :iwo_status_valid,
        check: "iwo_status IN ('draft','released','completed','cancelled')"
      )
    )

    create(constraint(:iwo_work_order, :iwo_qty_positive, check: "iwo_qty > 0"))

    create(
      constraint(:iwo_work_order, :iwo_costs_non_negative,
        check: "iwo_labor_cents >= 0 AND iwo_overhead_cents >= 0"
      )
    )

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    drop(table(:iwo_work_order))
    drop(table(:ipl_po_line))
    drop(table(:ipo_purchase_order))
    drop(table(:ibo_bom))
    drop(table(:inw_warehouse))
    drop(table(:ini_item))
    drop(table(:fai_ap_invoice))
    drop(table(:fjl_journal_line))
    drop(table(:fje_journal_entry))
    drop(table(:fca_account))
  end
end
