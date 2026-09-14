defmodule SamenCore.TestRepo.Migrations.InventoryE6ManufacturingFixture do
  @moduledoc """
  Tables + belt for the Inventory scope fixture's Manufacturing documents
  (WS-ERP E6; design §4), mounted by the SAME
  `test/support/inventory_fixture.ex` domain as E3/E4/E5 (the BASE mount —
  the posting facade needs no cross-scope wiring).

  Tables: `sbm_bom`, `sbl_bom_line`, `swk_work_order`,
  `spg_production_log` (every column `<abbrev>_<name>`).

  The belt (defense in depth over the Ash guards):

    * `sbm_bom` admits only ONE ACTIVE version per {org, item} (the
      partial unique index; superseded versions stay queryable).
    * `sbl_bom_line` is FROZEN while any released/completed work order
      references its BOM (UPDATE/DELETE refused) — R4 reconciles the bill
      that produced the facts. A BOM with no in-flight WO may
      re-materialize freely (orders carry their own snapshot).
    * `swk_work_order` enforces the state machine at the DB: born a
      draft; `→released` and `→completed` require the transaction-local
      `samen.finance_posting` marker (the `:release`/`:complete`
      cascades arm it — a raw-SQL stamp cannot land); `→cancelled` is
      refused once completed (a completed WO's stock facts are facts).
    * `spg_production_log` is APPEND-ONLY: UPDATE/DELETE refused
      outright (the E4 ReceiptLine shape) — the R4 join rows are facts.

  Catalog rows come from `catalog_sync/1` (the E1 helper), so
  `mix samen.verify.catalog_parity` sees the fixture tables fully
  catalogued.
  """

  use Samen.Migration

  @resources [
    SamenCore.Support.InventoryFixture.Bom,
    SamenCore.Support.InventoryFixture.BomLine,
    SamenCore.Support.InventoryFixture.WorkOrder,
    SamenCore.Support.InventoryFixture.ProductionLog
  ]

  def up do
    # ── Bom — the bill of materials (versioned; ONE active per {org, item}) ──
    create table(:sbm_bom, primary_key: false) do
      add(:sbm_version, :integer, null: false)
      add(:sbm_is_active, :boolean, null: false, default: true)
      add(:sbm_name, :text, null: false)
      add(:sbm_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:sbm_org_id, :uuid, null: false)
      add(:sbm_inserted_at, :utc_datetime, null: false)
      add(:sbm_updated_at, :utc_datetime, null: false)

      add(
        :sbm_item_id,
        references(:sit_item, column: :sit_id,
          name: "sbm_bom_sbm_item_id_fkey",
          type: :uuid
        )
      )
    end

    create(index(:sbm_bom, [:sbm_org_id]))
    create(index(:sbm_bom, [:sbm_org_id, :sbm_item_id, :sbm_version], unique: true))

    # ONE ACTIVE version per {org, item} — the blueprint's invariant.
    execute """
            CREATE UNIQUE INDEX sbm_bom_one_active_version_idx
            ON sbm_bom (sbm_org_id, sbm_item_id) WHERE sbm_is_active
            """,
            "DROP INDEX IF EXISTS sbm_bom_one_active_version_idx"

    # ── BomLine — the component row (frozen under an in-flight WO) ─────────
    create table(:sbl_bom_line, primary_key: false) do
      add(:sbl_qty_per, :bigint, null: false)
      add(:sbl_scrap_pct, :integer, null: false, default: 0)
      add(:sbl_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:sbl_org_id, :uuid, null: false)
      add(:sbl_inserted_at, :utc_datetime, null: false)
      add(:sbl_updated_at, :utc_datetime, null: false)

      add(
        :sbl_bom_id,
        references(:sbm_bom, column: :sbm_id,
          name: "sbl_bom_line_sbl_bom_id_fkey",
          type: :uuid
        )
      )

      add(
        :sbl_item_id,
        references(:sit_item, column: :sit_id,
          name: "sbl_bom_line_sbl_item_id_fkey",
          type: :uuid
        )
      )
    end

    create(index(:sbl_bom_line, [:sbl_org_id]))
    create(index(:sbl_bom_line, [:sbl_bom_id]))
    create(index(:sbl_bom_line, [:sbl_item_id]))

    execute """
            ALTER TABLE sbl_bom_line
              ADD CONSTRAINT sbl_qty_per_positive CHECK (sbl_qty_per > 0)
            """,
            "ALTER TABLE sbl_bom_line DROP CONSTRAINT sbl_qty_per_positive"

    execute """
            ALTER TABLE sbl_bom_line
              ADD CONSTRAINT sbl_scrap_pct_bounded
              CHECK (sbl_scrap_pct >= 0 AND sbl_scrap_pct <= 100)
            """,
            "ALTER TABLE sbl_bom_line DROP CONSTRAINT sbl_scrap_pct_bounded"

    # Frozen bill: a BOM's lines are immutable while any released/completed
    # work order references it — R4 reads the bill that produced the facts
    # (new versions, not rewrites). A WO carries its own snapshot, so a
    # BOM with no in-flight orders may re-materialize freely.
    execute """
            CREATE FUNCTION sbl_bom_line_enforce_frozen() RETURNS trigger LANGUAGE plpgsql AS $$
            DECLARE
              in_flight boolean;
              line_id text := COALESCE(OLD.sbl_id::text, NEW.sbl_id::text, 'n/a');
            BEGIN
              SELECT EXISTS (
                SELECT 1 FROM swk_work_order wo
                WHERE wo.swk_bom_id = COALESCE(NEW.sbl_bom_id, OLD.sbl_bom_id)
                  AND wo.swk_status IN ('released', 'completed')
              ) INTO in_flight;

              IF in_flight THEN
                RAISE EXCEPTION 'sbl_bom_line: % is refused — a released/completed work order '
                  'references this BOM; its lines are frozen (new versions, not rewrites) '
                  '(line: %)',
                  TG_OP, line_id;
              END IF;

              RETURN COALESCE(NEW, OLD);
            END;
            $$
            """,
            "DROP FUNCTION IF EXISTS sbl_bom_line_enforce_frozen()"

    execute """
            CREATE TRIGGER sbl_bom_line_frozen_tg
            BEFORE UPDATE OR DELETE ON sbl_bom_line
            FOR EACH ROW EXECUTE FUNCTION sbl_bom_line_enforce_frozen()
            """,
            "DROP TRIGGER IF EXISTS sbl_bom_line_frozen_tg ON sbl_bom_line"

    # ── WorkOrder — the manufacturing order (snapshot at release) ──────────
    create table(:swk_work_order, primary_key: false) do
      add(:swk_number, :text, null: false)
      add(:swk_qty, :integer, null: false)
      add(:swk_scheduled_for, :date)
      add(:swk_memo, :text)
      add(:swk_status, :text, null: false, default: "draft")
      add(:swk_bom_snapshot, :jsonb, null: false, default: "[]")
      add(:swk_actual_material_cents, :bigint)
      add(:swk_actual_unit_cost_cents, :bigint)
      add(:swk_bom_version, :integer)
      add(:swk_released_at, :utc_datetime)
      add(:swk_completed_at, :utc_datetime)
      add(:swk_labor_cents, :bigint, null: false, default: 0)
      add(:swk_overhead_cents, :bigint, null: false, default: 0)
      add(:swk_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:swk_org_id, :uuid, null: false)
      add(:swk_inserted_at, :utc_datetime, null: false)
      add(:swk_updated_at, :utc_datetime, null: false)

      add(
        :swk_item_id,
        references(:sit_item, column: :sit_id,
          name: "swk_work_order_swk_item_id_fkey",
          type: :uuid
        )
      )

      add(
        :swk_bom_id,
        references(:sbm_bom, column: :sbm_id,
          name: "swk_work_order_swk_bom_id_fkey",
          type: :uuid
        )
      )

      add(
        :swk_warehouse_id,
        references(:swh_warehouse, column: :swh_id,
          name: "swk_work_order_swk_warehouse_id_fkey",
          type: :uuid
        )
      )
    end

    create(index(:swk_work_order, [:swk_org_id]))
    create(index(:swk_work_order, [:swk_org_id, :swk_number], unique: true))
    create(index(:swk_work_order, [:swk_org_id, :swk_item_id]))
    create(index(:swk_work_order, [:swk_bom_id]))
    create(index(:swk_work_order, [:swk_status]))

    execute """
            ALTER TABLE swk_work_order
              ADD CONSTRAINT swk_status_valid CHECK (swk_status IN
                ('draft','released','completed','cancelled'))
            """,
            "ALTER TABLE swk_work_order DROP CONSTRAINT swk_status_valid"

    execute """
            ALTER TABLE swk_work_order
              ADD CONSTRAINT swk_qty_positive CHECK (swk_qty > 0)
            """,
            "ALTER TABLE swk_work_order DROP CONSTRAINT swk_qty_positive"

    execute """
            ALTER TABLE swk_work_order
              ADD CONSTRAINT swk_costs_non_negative
              CHECK (swk_labor_cents >= 0 AND swk_overhead_cents >= 0)
            """,
            "ALTER TABLE swk_work_order DROP CONSTRAINT swk_costs_non_negative"

    # The WO state machine at the DB (WoState's raw-SQL twin, plus the
    # marker gates the Ash layer cannot express): born a draft; →released
    # and →completed are marker-gated (the :release/:complete cascades are
    # the only armed writers); →cancelled is refused once completed.
    execute """
            CREATE FUNCTION swk_work_order_enforce_state() RETURNS trigger LANGUAGE plpgsql AS $$
            DECLARE
              armed boolean := COALESCE(current_setting('samen.finance_posting', true) = 'on', false);
            BEGIN
              IF TG_OP = 'INSERT' THEN
                IF NEW.swk_status IS DISTINCT FROM 'draft' THEN
                  RAISE EXCEPTION 'swk_work_order: a WO is born a draft (got %) — the only '
                    'route to any other state is a governed transition (wo: %)',
                    NEW.swk_status, NEW.swk_id;
                END IF;
                RETURN NEW;
              END IF;

              IF NEW.swk_status = OLD.swk_status THEN
                RETURN NEW;
              END IF;

              IF NEW.swk_status = 'released' THEN
                IF NOT armed THEN
                  RAISE EXCEPTION 'swk_work_order: →released requires the transaction-local '
                    'posting marker (samen.finance_posting) — a WO releases only through the '
                    'governed :release action (wo: %, % → %)',
                    OLD.swk_id, OLD.swk_status, NEW.swk_status;
                END IF;

                IF OLD.swk_status IS DISTINCT FROM 'draft' THEN
                  RAISE EXCEPTION 'swk_work_order: illegal →released transition from % (wo: %)',
                    OLD.swk_status, OLD.swk_id;
                END IF;

                RETURN NEW;
              END IF;

              IF NEW.swk_status = 'completed' THEN
                IF NOT armed THEN
                  RAISE EXCEPTION 'swk_work_order: →completed requires the transaction-local '
                    'posting marker — a WO completes only through the governed :complete '
                    'facade (wo: %, % → %)',
                    OLD.swk_id, OLD.swk_status, NEW.swk_status;
                END IF;

                IF OLD.swk_status IS DISTINCT FROM 'released' THEN
                  RAISE EXCEPTION 'swk_work_order: illegal →completed transition from % (wo: %)',
                    OLD.swk_status, OLD.swk_id;
                END IF;

                RETURN NEW;
              END IF;

              IF NEW.swk_status = 'cancelled' THEN
                IF OLD.swk_status NOT IN ('draft', 'released') THEN
                  RAISE EXCEPTION 'swk_work_order: illegal →cancelled transition from % — a '
                    'completed WO''s stock facts are facts (wo: %)',
                    OLD.swk_status, OLD.swk_id;
                END IF;

                RETURN NEW;
              END IF;

              RAISE EXCEPTION 'swk_work_order: unknown status % (wo: %)',
                NEW.swk_status, OLD.swk_id;
            END;
            $$
            """,
            "DROP FUNCTION IF EXISTS swk_work_order_enforce_state()"

    execute """
            CREATE TRIGGER swk_work_order_enforce_state_tg
            BEFORE INSERT OR UPDATE ON swk_work_order
            FOR EACH ROW EXECUTE FUNCTION swk_work_order_enforce_state()
            """,
            "DROP TRIGGER IF EXISTS swk_work_order_enforce_state_tg ON swk_work_order"

    # A non-draft WO's row is frozen against raw edits (the snapshot is the
    # binding contract — WIP never re-prices): without the marker every
    # column update is refused. The governed cascades (marker-armed) keep
    # writing their flips; the STATE trigger above still enforces legal
    # transitions on top of this freeze.
    execute """
            CREATE FUNCTION swk_work_order_enforce_frozen() RETURNS trigger LANGUAGE plpgsql AS $$
            DECLARE
              armed boolean := COALESCE(current_setting('samen.finance_posting', true) = 'on', false);
            BEGIN
              IF OLD.swk_status IS DISTINCT FROM 'draft' AND NOT armed THEN
                IF OLD.swk_status = 'released' AND NEW.swk_status = 'cancelled' THEN
                  -- The governed :cancel of a released WO posts NOTHING (the
                  -- consumed/produced facts only exist once completed) — no
                  -- marker required; the STATE trigger owns its pre-state.
                  RETURN NEW;
                END IF;

                RAISE EXCEPTION 'swk_work_order: % is refused — a non-draft WO is frozen (the '
                  'snapshot is the binding contract; raw edits cannot reach WIP) (wo: %)',
                  TG_OP, OLD.swk_id;
              END IF;

              RETURN NEW;
            END;
            $$
            """,
            "DROP FUNCTION IF EXISTS swk_work_order_enforce_frozen()"

    execute """
            CREATE TRIGGER swk_work_order_frozen_tg
            BEFORE UPDATE ON swk_work_order
            FOR EACH ROW EXECUTE FUNCTION swk_work_order_enforce_frozen()
            """,
            "DROP TRIGGER IF EXISTS swk_work_order_frozen_tg ON swk_work_order"

    # ── ProductionLog — the append-only posting log (the R4 join rows) ─────
    create table(:spg_production_log, primary_key: false) do
      add(:spg_entry_kind, :text, null: false)
      add(:spg_qty, :bigint, null: false)
      add(:spg_unit_cost_cents, :bigint)
      add(:spg_adjustment_cents, :bigint)
      add(:spg_ledger_event_id, :uuid)
      add(:spg_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:spg_org_id, :uuid, null: false)
      add(:spg_inserted_at, :utc_datetime, null: false)
      add(:spg_updated_at, :utc_datetime, null: false)

      add(
        :spg_work_order_id,
        references(:swk_work_order, column: :swk_id,
          name: "spg_production_log_spg_work_order_id_fkey",
          type: :uuid
        )
      )

      add(
        :spg_item_id,
        references(:sit_item, column: :sit_id,
          name: "spg_production_log_spg_item_id_fkey",
          type: :uuid
        )
      )
    end

    create(index(:spg_production_log, [:spg_org_id]))
    create(index(:spg_production_log, [:spg_work_order_id]))
    create(index(:spg_production_log, [:spg_item_id]))
    create(index(:spg_production_log, [:spg_ledger_event_id]))

    execute """
            ALTER TABLE spg_production_log
              ADD CONSTRAINT spg_entry_kind_valid CHECK (spg_entry_kind IN
                ('consume','produce','adjust'))
            """,
            "ALTER TABLE spg_production_log DROP CONSTRAINT spg_entry_kind_valid"

    # Append-only: the posting log is the audit trail of the landed facts —
    # UPDATE/DELETE refused outright (the E4 ReceiptLine shape).
    execute """
            CREATE FUNCTION spg_production_log_enforce_append_only() RETURNS trigger LANGUAGE plpgsql AS $$
            BEGIN
              RAISE EXCEPTION 'spg_production_log: % is refused — the posting log is '
                'append-only (a landed fact is a fact; row: %)',
                TG_OP, COALESCE(OLD.spg_id::text, NEW.spg_id::text, 'n/a');
            END;
            $$
            """,
            "DROP FUNCTION IF EXISTS spg_production_log_enforce_append_only()"

    execute """
            CREATE TRIGGER spg_production_log_append_only_tg
            BEFORE UPDATE OR DELETE ON spg_production_log
            FOR EACH ROW EXECUTE FUNCTION spg_production_log_enforce_append_only()
            """,
            "DROP TRIGGER IF EXISTS spg_production_log_append_only_tg ON spg_production_log"

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    drop(table(:spg_production_log))
    execute "DROP TRIGGER IF EXISTS swk_work_order_frozen_tg ON swk_work_order"
    execute "DROP FUNCTION IF EXISTS swk_work_order_enforce_frozen()"
    execute "DROP TRIGGER IF EXISTS swk_work_order_enforce_state_tg ON swk_work_order"
    execute "DROP FUNCTION IF EXISTS swk_work_order_enforce_state()"
    drop(table(:swk_work_order))
    execute "DROP TRIGGER IF EXISTS sbl_bom_line_frozen_tg ON sbl_bom_line"
    execute "DROP FUNCTION IF EXISTS sbl_bom_line_enforce_frozen()"
    drop(table(:sbl_bom_line))
    execute "DROP INDEX IF EXISTS sbm_bom_one_active_version_idx"
    drop(table(:sbm_bom))
  end
end
