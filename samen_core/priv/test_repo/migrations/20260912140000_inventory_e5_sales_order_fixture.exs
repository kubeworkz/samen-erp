defmodule SamenCore.TestRepo.Migrations.InventoryE5SalesOrderFixture do
  @moduledoc """
  Tables + belt for the Inventory scope fixture's SalesOrder bridge
  (WS-ERP E5; design §3.3), mounted by the SAME
  `test/support/inventory_fixture.ex` domain as E3/E4 (the `finance:` +
  `billing:` branches add two more resources), plus the E5 invoice-mirror
  table the `billing:` wiring points at.

  Tables: `slo_sales_order`, `sol_so_line`, `sim_invoice_mirror` (every
  column `<abbrev>_<name>`).

  The belt (defense in depth over the Ash guards):

    * `sol_so_line` is FROZEN once its SO leaves draft (UPDATE/DELETE
      refused) — fulfillment consumes the order AS ORDERED. Draft
      re-materialization (delete + re-insert by `SoLinesWriter`) stays
      open.
    * `slo_sales_order` enforces the state machine at the DB: born a
      draft; `→fulfilled` requires the transaction-local
      `samen.finance_posting` marker (the `:fulfill` bridge arms it — a
      raw-SQL fulfillment stamp cannot land); the remaining transitions
      enforce their pre-states.
    * `sim_invoice_mirror` is a plain mirror table (the Billing.Invoice
      contract has no belt of its own — the R2 mirror-leg posture);
      catalogued only.

  Catalog rows come from `catalog_sync/1` (the E1 helper), so
  `mix samen.verify.catalog_parity` sees the fixture tables fully
  catalogued.
  """

  use Samen.Migration

  @resources [
    SamenCore.Support.InventoryFixture.SalesOrder,
    SamenCore.Support.InventoryFixture.SoLine,
    SamenCore.Support.FinanceFixture.InvoiceMirror
  ]

  def up do
    # ── SalesOrder — stock's demand document (posts NOTHING until :fulfill) ──
    create table(:slo_sales_order, primary_key: false) do
      add(:slo_customer_id, :uuid, null: false)
      add(:slo_opportunity_id, :uuid)
      add(:slo_number, :text, null: false)
      add(:slo_order_date, :date, null: false)
      add(:slo_memo, :text)
      add(:slo_status, :text, null: false, default: "draft")
      add(:slo_invoice_key, :text)
      add(:slo_invoice_id, :uuid)
      add(:slo_fulfilled_at, :utc_datetime)
      add(:slo_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:slo_org_id, :uuid, null: false)
      add(:slo_inserted_at, :utc_datetime, null: false)
      add(:slo_updated_at, :utc_datetime, null: false)

      add(
        :slo_warehouse_id,
        references(:swh_warehouse, column: :swh_id,
          name: "slo_sales_order_slo_warehouse_id_fkey",
          type: :uuid
        )
      )
    end

    create(index(:slo_sales_order, [:slo_org_id]))
    create(index(:slo_sales_order, [:slo_org_id, :slo_number], unique: true))
    create(index(:slo_sales_order, [:slo_org_id, :slo_customer_id]))
    create(index(:slo_sales_order, [:slo_invoice_id]))

    execute """
            ALTER TABLE slo_sales_order
              ADD CONSTRAINT slo_status_valid CHECK (slo_status IN
                ('draft','confirmed','fulfilled','cancelled'))
            """,
            "ALTER TABLE slo_sales_order DROP CONSTRAINT slo_status_valid"

    # The SO state machine at the DB (the SoState guard's raw-SQL twin, plus
    # the marker gate the Ash layer cannot express): born a draft; →fulfilled
    # is marker-gated (the :fulfill bridge is the only armed writer — a
    # raw-SQL fulfillment stamp cannot land); the host lifecycle moves
    # (→confirmed/→cancelled) enforce their pre-states.
    execute """
            CREATE FUNCTION slo_sales_order_enforce_state() RETURNS trigger LANGUAGE plpgsql AS $$
            DECLARE
              armed boolean := COALESCE(current_setting('samen.finance_posting', true) = 'on', false);
            BEGIN
              IF TG_OP = 'INSERT' THEN
                IF NEW.slo_status IS DISTINCT FROM 'draft' THEN
                  RAISE EXCEPTION 'slo_sales_order: a SO is born a draft (got %) — the only '
                    'route to any other state is a governed transition (so: %)',
                    NEW.slo_status, NEW.slo_id;
                END IF;
                RETURN NEW;
              END IF;

              IF NEW.slo_status = OLD.slo_status THEN
                RETURN NEW;
              END IF;

              IF NEW.slo_status = 'fulfilled' THEN
                IF NOT armed THEN
                  RAISE EXCEPTION 'slo_sales_order: →fulfilled requires the transaction-local '
                    'posting marker (samen.finance_posting) — a SO fulfills only through the '
                    ':fulfill bridge (so: %, % → %)',
                    OLD.slo_id, OLD.slo_status, NEW.slo_status;
                END IF;

                IF OLD.slo_status IS DISTINCT FROM 'confirmed' THEN
                  RAISE EXCEPTION 'slo_sales_order: illegal →fulfilled transition from % (so: %)',
                    OLD.slo_status, OLD.slo_id;
                END IF;

                RETURN NEW;
              END IF;

              IF NEW.slo_status = 'confirmed' THEN
                IF OLD.slo_status IS DISTINCT FROM 'draft' THEN
                  RAISE EXCEPTION 'slo_sales_order: illegal →confirmed transition from % (so: %)',
                    OLD.slo_status, OLD.slo_id;
                END IF;

                RETURN NEW;
              END IF;

              IF NEW.slo_status = 'cancelled' THEN
                IF OLD.slo_status NOT IN ('draft', 'confirmed') THEN
                  RAISE EXCEPTION 'slo_sales_order: illegal →cancelled transition from % — a '
                    'fulfilled SO''s stock and invoice are facts (so: %)',
                    OLD.slo_status, OLD.slo_id;
                END IF;

                RETURN NEW;
              END IF;

              RAISE EXCEPTION 'slo_sales_order: unknown status % (so: %)', NEW.slo_status, OLD.slo_id;
            END;
            $$
            """,
            "DROP FUNCTION IF EXISTS slo_sales_order_enforce_state()"

    execute """
            CREATE TRIGGER slo_sales_order_enforce_state_tg
            BEFORE INSERT OR UPDATE ON slo_sales_order
            FOR EACH ROW EXECUTE FUNCTION slo_sales_order_enforce_state()
            """,
            "DROP TRIGGER IF EXISTS slo_sales_order_enforce_state_tg ON slo_sales_order"

    # ── SoLine — the SO's line row (frozen once the SO leaves draft) ───────
    create table(:sol_so_line, primary_key: false) do
      add(:sol_qty, :bigint, null: false)
      add(:sol_unit_price_cents, :bigint, null: false, default: 0)
      add(:sol_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:sol_org_id, :uuid, null: false)
      add(:sol_inserted_at, :utc_datetime, null: false)
      add(:sol_updated_at, :utc_datetime, null: false)

      add(
        :sol_sales_order_id,
        references(:slo_sales_order, column: :slo_id,
          name: "sol_so_line_sol_sales_order_id_fkey",
          type: :uuid
        )
      )

      add(
        :sol_item_id,
        references(:sit_item, column: :sit_id,
          name: "sol_so_line_sol_item_id_fkey",
          type: :uuid
        )
      )
    end

    create(index(:sol_so_line, [:sol_org_id]))
    create(index(:sol_so_line, [:sol_sales_order_id]))
    create(index(:sol_so_line, [:sol_item_id]))

    execute """
            ALTER TABLE sol_so_line
              ADD CONSTRAINT sol_qty_positive CHECK (sol_qty > 0)
            """,
            "ALTER TABLE sol_so_line DROP CONSTRAINT sol_qty_positive"

    execute """
            ALTER TABLE sol_so_line
              ADD CONSTRAINT sol_unit_price_non_negative CHECK (sol_unit_price_cents >= 0)
            """,
            "ALTER TABLE sol_so_line DROP CONSTRAINT sol_unit_price_non_negative"

    # Frozen lines: a SO line is immutable once its SO leaves draft —
    # fulfillment consumes the order AS ORDERED. Draft re-materialization
    # (SoLinesWriter's delete + re-insert) stays open: the parent is still a
    # draft then.
    execute """
            CREATE FUNCTION sol_so_line_enforce_frozen() RETURNS trigger LANGUAGE plpgsql AS $$
            DECLARE
              so_status text;
            BEGIN
              IF TG_OP = 'DELETE' THEN
                SELECT so.slo_status INTO so_status
                FROM slo_sales_order so WHERE so.slo_id = OLD.sol_sales_order_id;
              ELSE
                SELECT so.slo_status INTO so_status
                FROM slo_sales_order so WHERE so.slo_id = NEW.sol_sales_order_id;
              END IF;

              IF so_status IS DISTINCT FROM 'draft' THEN
                RAISE EXCEPTION 'sol_so_line: % is refused — a SO line is frozen once its SO leaves '
                  'draft (status: %); fulfillment consumes the order AS ORDERED (line: %)',
                  TG_OP, so_status, COALESCE(OLD.sol_id::text, NEW.sol_id::text, 'n/a');
              END IF;

              RETURN COALESCE(NEW, OLD);
            END;
            $$
            """,
            "DROP FUNCTION IF EXISTS sol_so_line_enforce_frozen()"

    execute """
            CREATE TRIGGER sol_so_line_frozen_tg
            BEFORE UPDATE OR DELETE ON sol_so_line
            FOR EACH ROW EXECUTE FUNCTION sol_so_line_enforce_frozen()
            """,
            "DROP TRIGGER IF EXISTS sol_so_line_frozen_tg ON sol_so_line"

    # ── InvoiceMirror — the E5 emission target (the R2 mirror-leg posture) ──
    create table(:sim_invoice_mirror, primary_key: false) do
      add(:sim_customer_id, :uuid, null: false)

      add(:sim_status, :text, null: false, default: "draft")
      add(:sim_amount_due_cents, :bigint, null: false, default: 0)
      add(:sim_amount_paid_cents, :bigint, null: false, default: 0)
      add(:sim_currency, :text, null: false, default: "USD")
      add(:sim_line_items, :jsonb, null: false, default: "[]")
      add(:sim_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:sim_org_id, :uuid, null: false)
      add(:sim_inserted_at, :utc_datetime, null: false)
      add(:sim_updated_at, :utc_datetime, null: false)
    end

    create(index(:sim_invoice_mirror, [:sim_org_id]))
    create(index(:sim_invoice_mirror, [:sim_org_id, :sim_customer_id]))

    execute """
            ALTER TABLE sim_invoice_mirror
              ADD CONSTRAINT sim_status_valid CHECK (sim_status IN
                ('draft','open','paid','void','uncollectible'))
            """,
            "ALTER TABLE sim_invoice_mirror DROP CONSTRAINT sim_status_valid"

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    drop(table(:sim_invoice_mirror))
    execute "DROP TRIGGER IF EXISTS sol_so_line_frozen_tg ON sol_so_line"
    execute "DROP FUNCTION IF EXISTS sol_so_line_enforce_frozen()"
    execute "DROP TRIGGER IF EXISTS slo_sales_order_enforce_state_tg ON slo_sales_order"
    execute "DROP FUNCTION IF EXISTS slo_sales_order_enforce_state()"
    drop(table(:sol_so_line))
    drop(table(:slo_sales_order))
  end
end
