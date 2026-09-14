defmodule SamenCore.TestRepo.Migrations.InventoryE4ProcurementFixture do
  @moduledoc """
  Tables + belt for the Inventory scope fixture's Procurement documents
  (WS-ERP E4; design §3.2), mounted by the SAME
  `test/support/inventory_fixture.ex` domain as E3 (the `finance:` branch
  adds four resources).

  Tables: `spo_purchase_order`, `spl_po_line`, `sgr_goods_receipt`,
  `srl_receipt_line` (every column `<abbrev>_<name>`).

  The belt (defense in depth over the Ash guards):

    * `spl_po_line` is FROZEN once its PO leaves draft (UPDATE/DELETE
      refused) — receiving reconciles against the order AS ORDERED (R5's
      ordered side). Draft re-materialization (delete + re-insert by
      `PoLinesWriter`) stays open.
    * `spo_purchase_order` enforces the state machine at the DB: born a
      draft; `→approved` and `→received` require the transaction-local
      `samen.finance_posting` marker (the gated `:approve` / the
      `:receive` chokepoint arm it — a raw-SQL approval or receipt stamp
      cannot land); the remaining transitions enforce their pre-states.
    * `sgr_goods_receipt` is born a draft; `draft → posted` requires the
      marker (exactly-once, inside `:receive`); `posted → anything` is
      refused outright.
    * `srl_receipt_line` is APPEND-ONLY at the DB — a received-quantity
      fact is written once by the chokepoint (R5's received side).

  Catalog rows come from `catalog_sync/1` (the E1 helper), so
  `mix samen.verify.catalog_parity` sees the fixture tables fully
  catalogued.
  """

  use Samen.Migration

  @resources [
    SamenCore.Support.InventoryFixture.PurchaseOrder,
    SamenCore.Support.InventoryFixture.PoLine,
    SamenCore.Support.InventoryFixture.GoodsReceipt,
    SamenCore.Support.InventoryFixture.ReceiptLine
  ]

  def up do
    # ── PurchaseOrder — the SCM document pair's head (posts NOTHING) ───────
    create table(:spo_purchase_order, primary_key: false) do
      add(:spo_vendor_id, :uuid, null: false)
      add(:spo_number, :text, null: false)
      add(:spo_order_date, :date, null: false)
      add(:spo_memo, :text)
      add(:spo_status, :text, null: false, default: "draft")
      add(:spo_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:spo_org_id, :uuid, null: false)
      add(:spo_inserted_at, :utc_datetime, null: false)
      add(:spo_updated_at, :utc_datetime, null: false)

      add(
        :spo_warehouse_id,
        references(:swh_warehouse, column: :swh_id,
          name: "spo_purchase_order_spo_warehouse_id_fkey",
          type: :uuid
        )
      )
    end

    create(index(:spo_purchase_order, [:spo_org_id]))
    create(index(:spo_purchase_order, [:spo_org_id, :spo_number], unique: true))
    create(index(:spo_purchase_order, [:spo_org_id, :spo_vendor_id]))

    execute """
            ALTER TABLE spo_purchase_order
              ADD CONSTRAINT spo_status_valid CHECK (spo_status IN
                ('draft','approved','sent','received','closed','void'))
            """,
            "ALTER TABLE spo_purchase_order DROP CONSTRAINT spo_status_valid"

    # The PO state machine at the DB (the PoState guard's raw-SQL twin, plus
    # the marker gates the Ash layer cannot express): a PO is born a draft;
    # →approved and →received are marker-gated (the ADR-040 Gate's decision
    # transaction and the :receive chokepoint are the only armed writers —
    # a raw-SQL approval or a raw-SQL receipt stamp cannot land); the host
    # lifecycle moves (→sent/→void/→closed) enforce their pre-states.
    execute """
            CREATE FUNCTION spo_purchase_order_enforce_state() RETURNS trigger LANGUAGE plpgsql AS $$
            DECLARE
              armed boolean := COALESCE(current_setting('samen.finance_posting', true) = 'on', false);
            BEGIN
              IF TG_OP = 'INSERT' THEN
                IF NEW.spo_status IS DISTINCT FROM 'draft' THEN
                  RAISE EXCEPTION 'spo_purchase_order: a PO is born a draft (got %) — the only '
                    'route to any other state is a governed transition (po: %)',
                    NEW.spo_status, NEW.spo_id;
                END IF;
                RETURN NEW;
              END IF;

              IF NEW.spo_status = OLD.spo_status THEN
                RETURN NEW;
              END IF;

              IF NEW.spo_status = 'received' THEN
                IF NOT armed THEN
                  RAISE EXCEPTION 'spo_purchase_order: →received requires the transaction-local '
                    'posting marker (samen.finance_posting) — a PO is received only inside the '
                    'GoodsReceipt :receive chokepoint (po: %, % → %)',
                    OLD.spo_id, OLD.spo_status, NEW.spo_status;
                END IF;

                IF OLD.spo_status NOT IN ('approved', 'sent') THEN
                  RAISE EXCEPTION 'spo_purchase_order: illegal →received transition from % (po: %)',
                    OLD.spo_status, OLD.spo_id;
                END IF;

                RETURN NEW;
              END IF;

              IF NEW.spo_status = 'approved' THEN
                IF NOT armed THEN
                  RAISE EXCEPTION 'spo_purchase_order: →approved requires the transaction-local '
                    'posting marker (samen.finance_posting) — approval rides the ADR-040 Gate '
                    '(po: %)', OLD.spo_id;
                END IF;

                IF OLD.spo_status IS DISTINCT FROM 'draft' THEN
                  RAISE EXCEPTION 'spo_purchase_order: illegal →approved transition from % (po: %)',
                    OLD.spo_status, OLD.spo_id;
                END IF;

                RETURN NEW;
              END IF;

              IF NEW.spo_status = 'sent' THEN
                IF OLD.spo_status IS DISTINCT FROM 'approved' THEN
                  RAISE EXCEPTION 'spo_purchase_order: illegal →sent transition from % (po: %)',
                    OLD.spo_status, OLD.spo_id;
                END IF;

                RETURN NEW;
              END IF;

              IF NEW.spo_status = 'void' THEN
                IF OLD.spo_status NOT IN ('draft', 'approved', 'sent') THEN
                  RAISE EXCEPTION 'spo_purchase_order: illegal →void transition from % — a received '
                    'PO''s realized stock and GL value need a return receipt, not a void (po: %)',
                    OLD.spo_status, OLD.spo_id;
                END IF;

                RETURN NEW;
              END IF;

              IF NEW.spo_status = 'closed' THEN
                IF OLD.spo_status IS DISTINCT FROM 'received' THEN
                  RAISE EXCEPTION 'spo_purchase_order: illegal →closed transition from % — only a '
                    'received PO closes (po: %)', OLD.spo_status, OLD.spo_id;
                END IF;

                RETURN NEW;
              END IF;

              RAISE EXCEPTION 'spo_purchase_order: unknown status % (po: %)', NEW.spo_status, OLD.spo_id;
            END;
            $$
            """,
            "DROP FUNCTION IF EXISTS spo_purchase_order_enforce_state()"

    execute """
            CREATE TRIGGER spo_purchase_order_enforce_state_tg
            BEFORE INSERT OR UPDATE ON spo_purchase_order
            FOR EACH ROW EXECUTE FUNCTION spo_purchase_order_enforce_state()
            """,
            "DROP TRIGGER IF EXISTS spo_purchase_order_enforce_state_tg ON spo_purchase_order"

    # ── PoLine — the PO's line row (frozen once the PO leaves draft) ───────
    create table(:spl_po_line, primary_key: false) do
      add(:spl_qty, :bigint, null: false)
      add(:spl_unit_cost_cents, :bigint, null: false, default: 0)
      add(:spl_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:spl_org_id, :uuid, null: false)
      add(:spl_inserted_at, :utc_datetime, null: false)
      add(:spl_updated_at, :utc_datetime, null: false)

      add(
        :spl_purchase_order_id,
        references(:spo_purchase_order, column: :spo_id,
          name: "spl_po_line_spl_purchase_order_id_fkey",
          type: :uuid
        )
      )

      add(
        :spl_item_id,
        references(:sit_item, column: :sit_id,
          name: "spl_po_line_spl_item_id_fkey",
          type: :uuid
        )
      )
    end

    create(index(:spl_po_line, [:spl_org_id]))
    create(index(:spl_po_line, [:spl_purchase_order_id]))
    create(index(:spl_po_line, [:spl_item_id]))

    execute """
            ALTER TABLE spl_po_line
              ADD CONSTRAINT spl_qty_positive CHECK (spl_qty > 0)
            """,
            "ALTER TABLE spl_po_line DROP CONSTRAINT spl_qty_positive"

    execute """
            ALTER TABLE spl_po_line
              ADD CONSTRAINT spl_unit_cost_non_negative CHECK (spl_unit_cost_cents >= 0)
            """,
            "ALTER TABLE spl_po_line DROP CONSTRAINT spl_unit_cost_non_negative"

    # Frozen lines: a PO line is immutable once its PO leaves draft — the
    # receiving quantities reconcile against the order AS ORDERED (R5's
    # ordered side). Draft re-materialization (PoLinesWriter's delete +
    # re-insert) stays open: the parent is still a draft then.
    execute """
            CREATE FUNCTION spl_po_line_enforce_frozen() RETURNS trigger LANGUAGE plpgsql AS $$
            DECLARE
              po_status text;
            BEGIN
              IF TG_OP = 'DELETE' THEN
                SELECT po.spo_status INTO po_status
                FROM spo_purchase_order po WHERE po.spo_id = OLD.spl_purchase_order_id;
              ELSE
                SELECT po.spo_status INTO po_status
                FROM spo_purchase_order po WHERE po.spo_id = NEW.spl_purchase_order_id;
              END IF;

              IF po_status IS DISTINCT FROM 'draft' THEN
                RAISE EXCEPTION 'spl_po_line: % is refused — a PO line is frozen once its PO leaves '
                  'draft (status: %); receiving reconciles against the order AS ORDERED (line: %)',
                  TG_OP, po_status, COALESCE(OLD.spl_id::text, NEW.spl_id::text, 'n/a');
              END IF;

              RETURN COALESCE(NEW, OLD);
            END;
            $$
            """,
            "DROP FUNCTION IF EXISTS spl_po_line_enforce_frozen()"

    execute """
            CREATE TRIGGER spl_po_line_frozen_tg
            BEFORE UPDATE OR DELETE ON spl_po_line
            FOR EACH ROW EXECUTE FUNCTION spl_po_line_enforce_frozen()
            """,
            "DROP TRIGGER IF EXISTS spl_po_line_frozen_tg ON spl_po_line"

    # ── GoodsReceipt — the ONE-TRANSACTION chokepoint's document ───────────
    create table(:sgr_goods_receipt, primary_key: false) do
      add(:sgr_number, :text, null: false)
      add(:sgr_received_date, :date, null: false)
      add(:sgr_memo, :text)
      add(:sgr_status, :text, null: false, default: "draft")
      add(:sgr_posted_entry_id, :uuid)
      add(:sgr_received_at, :utc_datetime)
      add(:sgr_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:sgr_org_id, :uuid, null: false)
      add(:sgr_inserted_at, :utc_datetime, null: false)
      add(:sgr_updated_at, :utc_datetime, null: false)

      add(
        :sgr_purchase_order_id,
        references(:spo_purchase_order, column: :spo_id,
          name: "sgr_goods_receipt_sgr_purchase_order_id_fkey",
          type: :uuid
        )
      )

      add(
        :sgr_warehouse_id,
        references(:swh_warehouse, column: :swh_id,
          name: "sgr_goods_receipt_sgr_warehouse_id_fkey",
          type: :uuid
        )
      )
    end

    create(index(:sgr_goods_receipt, [:sgr_org_id]))
    create(index(:sgr_goods_receipt, [:sgr_org_id, :sgr_number], unique: true))
    create(index(:sgr_goods_receipt, [:sgr_purchase_order_id]))
    create(index(:sgr_goods_receipt, [:sgr_posted_entry_id]))

    execute """
            ALTER TABLE sgr_goods_receipt
              ADD CONSTRAINT sgr_status_valid CHECK (sgr_status IN ('draft', 'posted'))
            """,
            "ALTER TABLE sgr_goods_receipt DROP CONSTRAINT sgr_status_valid"

    # The receipt's own state belt: born a draft; draft → posted requires the
    # marker (the :receive chokepoint arms it — exactly-once); posted →
    # anything is refused outright (a posted receipt is a fact).
    execute """
            CREATE FUNCTION sgr_goods_receipt_enforce_state() RETURNS trigger LANGUAGE plpgsql AS $$
            DECLARE
              armed boolean := COALESCE(current_setting('samen.finance_posting', true) = 'on', false);
            BEGIN
              IF TG_OP = 'INSERT' THEN
                IF NEW.sgr_status IS DISTINCT FROM 'draft' THEN
                  RAISE EXCEPTION 'sgr_goods_receipt: a receipt is born a draft (got %) — the only '
                    'route to :posted is the :receive chokepoint (receipt: %)',
                    NEW.sgr_status, NEW.sgr_id;
                END IF;

                RETURN NEW;
              END IF;

              IF NEW.sgr_status = OLD.sgr_status THEN
                RETURN NEW;
              END IF;

              IF OLD.sgr_status = 'draft' AND NEW.sgr_status = 'posted' AND armed THEN
                RETURN NEW;
              END IF;

              RAISE EXCEPTION 'sgr_goods_receipt: illegal status transition % → % (marker armed: %) — '
                'a receipt posts exactly once, inside the :receive chokepoint (receipt: %)',
                OLD.sgr_status, NEW.sgr_status, armed, OLD.sgr_id;
            END;
            $$
            """,
            "DROP FUNCTION IF EXISTS sgr_goods_receipt_enforce_state()"

    execute """
            CREATE TRIGGER sgr_goods_receipt_enforce_state_tg
            BEFORE INSERT OR UPDATE ON sgr_goods_receipt
            FOR EACH ROW EXECUTE FUNCTION sgr_goods_receipt_enforce_state()
            """,
            "DROP TRIGGER IF EXISTS sgr_goods_receipt_enforce_state_tg ON sgr_goods_receipt"

    # ── ReceiptLine — the materialized received-quantity fact (R5) ─────────
    create table(:srl_receipt_line, primary_key: false) do
      add(:srl_qty, :bigint, null: false)
      add(:srl_unit_cost_cents, :bigint, null: false, default: 0)
      add(:srl_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:srl_org_id, :uuid, null: false)
      add(:srl_inserted_at, :utc_datetime, null: false)
      add(:srl_updated_at, :utc_datetime, null: false)

      add(
        :srl_goods_receipt_id,
        references(:sgr_goods_receipt, column: :sgr_id,
          name: "srl_receipt_line_srl_goods_receipt_id_fkey",
          type: :uuid
        )
      )

      add(
        :srl_po_line_id,
        references(:spl_po_line, column: :spl_id,
          name: "srl_receipt_line_srl_po_line_id_fkey",
          type: :uuid
        )
      )
    end

    create(index(:srl_receipt_line, [:srl_org_id]))
    create(index(:srl_receipt_line, [:srl_goods_receipt_id]))
    create(index(:srl_receipt_line, [:srl_po_line_id]))

    execute """
            ALTER TABLE srl_receipt_line
              ADD CONSTRAINT srl_qty_positive CHECK (srl_qty > 0)
            """,
            "ALTER TABLE srl_receipt_line DROP CONSTRAINT srl_qty_positive"

    execute """
            ALTER TABLE srl_receipt_line
              ADD CONSTRAINT srl_unit_cost_non_negative CHECK (srl_unit_cost_cents >= 0)
            """,
            "ALTER TABLE srl_receipt_line DROP CONSTRAINT srl_unit_cost_non_negative"

    # Append-only: a received-quantity fact is written once by the chokepoint
    # (the over-receipt floor and R5's received side read these rows).
    execute """
            CREATE FUNCTION srl_receipt_line_enforce_append_only() RETURNS trigger LANGUAGE plpgsql AS $$
            BEGIN
              RAISE EXCEPTION 'srl_receipt_line is append-only: % is refused — a received-quantity '
                'fact is written once by the :receive chokepoint (row: %)',
                TG_OP, COALESCE(OLD.srl_id::text, 'n/a');
            END;
            $$
            """,
            "DROP FUNCTION IF EXISTS srl_receipt_line_enforce_append_only()"

    execute """
            CREATE TRIGGER srl_receipt_line_append_only_tg
            BEFORE UPDATE OR DELETE ON srl_receipt_line
            FOR EACH ROW EXECUTE FUNCTION srl_receipt_line_enforce_append_only()
            """,
            "DROP TRIGGER IF EXISTS srl_receipt_line_append_only_tg ON srl_receipt_line"

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    execute "DROP TRIGGER IF EXISTS srl_receipt_line_append_only_tg ON srl_receipt_line"
    execute "DROP FUNCTION IF EXISTS srl_receipt_line_enforce_append_only()"
    execute "DROP TRIGGER IF EXISTS sgr_goods_receipt_enforce_state_tg ON sgr_goods_receipt"
    execute "DROP FUNCTION IF EXISTS sgr_goods_receipt_enforce_state()"
    execute "DROP TRIGGER IF EXISTS spl_po_line_frozen_tg ON spl_po_line"
    execute "DROP FUNCTION IF EXISTS spl_po_line_enforce_frozen()"
    execute "DROP TRIGGER IF EXISTS spo_purchase_order_enforce_state_tg ON spo_purchase_order"
    execute "DROP FUNCTION IF EXISTS spo_purchase_order_enforce_state()"
    drop(table(:srl_receipt_line))
    drop(table(:sgr_goods_receipt))
    drop(table(:spl_po_line))
    drop(table(:spo_purchase_order))
  end
end
