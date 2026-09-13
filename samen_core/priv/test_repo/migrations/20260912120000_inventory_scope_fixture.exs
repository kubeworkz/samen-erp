defmodule SamenCore.TestRepo.Migrations.InventoryScopeFixture do
  @moduledoc """
  Tables + belt for the Inventory scope fixture (WS-ERP E3; ADR-049 §3),
  mounted in `test/support/inventory_fixture.ex` — the E1/E2 migration
  shape applied to stock.

  Tables: `sit_item`, `swh_warehouse`, `skl_stock_ledger`, `slv_stock_level`
  (every column `<abbrev>_<name>`). `swh_address` is the vaulted composite
  column (composite routing convention: an opaque `vt_*` token, never
  plaintext — the Locations.Location posture).

  The belt (defense in depth over the Ash guards):

    * `skl_stock_ledger` is APPEND-ONLY at the DB (UPDATE/DELETE refused
      outright) — a stock event is a fact.
    * `skl_stock_ledger` enforces the NegativeStock floor at the DB: an
      INSERT that would take the (item, warehouse) pair below zero is
      refused unless the warehouse row says `swh_allow_negative` (the
      per-warehouse opt-out, read from the SAME column the Ash guard
      reads — fail-closed on a missing warehouse row).
    * `slv_stock_level` refuses every write WITHOUT the transaction-local
      `samen.stock_sync` marker (the rollup is written only by
      `StockLevelSync`), and — when armed — RE-DERIVES the ledger truth
      and refuses a write whose qty/value diverge from it: the rollup is
      derived, never asserted. Even a marker-armed hand-edit cannot land.

  Catalog rows come from `catalog_sync/1` (the E1 helper), so
  `mix samen.verify.catalog_parity` sees the fixture tables fully
  catalogued.
  """

  use Samen.Migration

  @resources [
    SamenCore.Support.InventoryFixture.Item,
    SamenCore.Support.InventoryFixture.Warehouse,
    SamenCore.Support.InventoryFixture.StockLedger,
    SamenCore.Support.InventoryFixture.StockLevel
  ]

  def up do
    # ── Item — the item master ────────────────────────────────────────────
    create table(:sit_item, primary_key: false) do
      add(:sit_sku, :text, null: false)
      add(:sit_name, :text, null: false)
      add(:sit_kind, :text, null: false, default: "stocked")
      add(:sit_uom, :text, null: false, default: "unit")
      add(:sit_reorder_point, :integer)
      add(:sit_default_income_account_id, :uuid)
      add(:sit_default_expense_account_id, :uuid)
      add(:sit_default_inventory_account_id, :uuid)
      add(:sit_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:sit_org_id, :uuid, null: false)
      add(:sit_inserted_at, :utc_datetime, null: false)
      add(:sit_updated_at, :utc_datetime, null: false)
    end

    create(index(:sit_item, [:sit_org_id]))
    create(index(:sit_item, [:sit_org_id, :sit_sku], unique: true))

    # ── Warehouse — a stock location with real quantity semantics ─────────
    create table(:swh_warehouse, primary_key: false) do
      add(:swh_code, :text, null: false)
      add(:swh_name, :text, null: false)
      # The per-warehouse NegativeStock opt-out — fail-closed default.
      add(:swh_allow_negative, :boolean, null: false, default: false)
      add(:swh_is_sellable, :boolean, null: false, default: true)
      # Vaulted composite (composite routing convention): opaque vt_* token.
      add(:swh_address, :text)
      add(:swh_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:swh_org_id, :uuid, null: false)
      add(:swh_inserted_at, :utc_datetime, null: false)
      add(:swh_updated_at, :utc_datetime, null: false)
    end

    create(index(:swh_warehouse, [:swh_org_id]))
    create(index(:swh_warehouse, [:swh_org_id, :swh_code], unique: true))

    # ── StockLedger — THE append-only movement event ──────────────────────
    create table(:skl_stock_ledger, primary_key: false) do
      add(:skl_kind, :text, null: false)
      add(:skl_qty, :bigint, null: false)
      add(:skl_unit_cost_cents, :bigint, null: false, default: 0)
      add(:skl_source_key, :text)
      add(:skl_source_id, :uuid)
      add(:skl_note, :text)
      add(:skl_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:skl_org_id, :uuid, null: false)
      add(:skl_inserted_at, :utc_datetime, null: false)
      add(:skl_updated_at, :utc_datetime, null: false)

      add(
        :skl_item_id,
        references(:sit_item, column: :sit_id, name: "skl_stock_ledger_skl_item_id_fkey", type: :uuid)
      )

      add(
        :skl_warehouse_id,
        references(:swh_warehouse, column: :swh_id, name: "skl_stock_ledger_skl_warehouse_id_fkey", type: :uuid)
      )
    end

    create(index(:skl_stock_ledger, [:skl_org_id]))
    create(index(:skl_stock_ledger, [:skl_item_id]))
    create(index(:skl_stock_ledger, [:skl_warehouse_id]))
    create(index(:skl_stock_ledger, [:skl_org_id, :skl_item_id, :skl_warehouse_id]))

    execute """
            ALTER TABLE skl_stock_ledger
              ADD CONSTRAINT skl_kind_valid CHECK (skl_kind IN
                ('receipt','issue','transfer_out','transfer_in','adjust','sale','production_in','production_consume'))
            """,
            "ALTER TABLE skl_stock_ledger DROP CONSTRAINT skl_kind_valid"

    execute """
            ALTER TABLE skl_stock_ledger
              ADD CONSTRAINT skl_unit_cost_non_negative CHECK (skl_unit_cost_cents >= 0)
            """,
            "ALTER TABLE skl_stock_ledger DROP CONSTRAINT skl_unit_cost_non_negative"

    # APPEND-ONLY at the DB: a stock event is a fact. No UPDATE, no DELETE —
    # corrections are NEW `:adjust` events.
    execute """
            CREATE FUNCTION skl_stock_ledger_enforce_append_only() RETURNS trigger LANGUAGE plpgsql AS $$
            BEGIN
              RAISE EXCEPTION 'skl_stock_ledger is append-only: % is refused — a stock event is a '
                'fact; corrections are new :adjust events (event id: %)',
                TG_OP, COALESCE(OLD.skl_id::text, 'n/a');
            END;
            $$
            """,
            "DROP FUNCTION IF EXISTS skl_stock_ledger_enforce_append_only()"

    execute """
            CREATE TRIGGER skl_stock_ledger_append_only_tg
            BEFORE UPDATE OR DELETE ON skl_stock_ledger
            FOR EACH ROW EXECUTE FUNCTION skl_stock_ledger_enforce_append_only()
            """,
            "DROP TRIGGER IF EXISTS skl_stock_ledger_append_only_tg ON skl_stock_ledger"

    # The NegativeStock floor at the DB: live sum + NEW.qty >= 0 unless the
    # warehouse opts out. `allow IS DISTINCT FROM TRUE` fails CLOSED on a
    # missing warehouse row (a NULL/absent opt-out is never an opt-IN).
    execute """
            CREATE FUNCTION skl_stock_ledger_enforce_negative_stock() RETURNS trigger LANGUAGE plpgsql AS $$
            DECLARE
              on_hand bigint;
              allow boolean;
            BEGIN
              SELECT COALESCE(SUM(skl.skl_qty), 0) INTO on_hand
              FROM skl_stock_ledger skl
              WHERE skl.skl_org_id = NEW.skl_org_id
                AND skl.skl_item_id = NEW.skl_item_id
                AND skl.skl_warehouse_id = NEW.skl_warehouse_id;

              SELECT swh.swh_allow_negative INTO allow
              FROM swh_warehouse swh
              WHERE swh.swh_id = NEW.skl_warehouse_id;

              IF allow IS DISTINCT FROM TRUE AND on_hand + NEW.skl_qty < 0 THEN
                RAISE EXCEPTION 'skl_stock_ledger: negative stock refused — the (item, warehouse) '
                  'pair would go to % (floor is 0; the warehouse has not opted out via '
                  'allow_negative). Event qty: %, item: %, warehouse: %',
                  on_hand + NEW.skl_qty, NEW.skl_qty, NEW.skl_item_id, NEW.skl_warehouse_id;
              END IF;

              RETURN NEW;
            END;
            $$
            """,
            "DROP FUNCTION IF EXISTS skl_stock_ledger_enforce_negative_stock()"

    execute """
            CREATE TRIGGER skl_stock_ledger_negative_stock_tg
            BEFORE INSERT ON skl_stock_ledger
            FOR EACH ROW EXECUTE FUNCTION skl_stock_ledger_enforce_negative_stock()
            """,
            "DROP TRIGGER IF EXISTS skl_stock_ledger_negative_stock_tg ON skl_stock_ledger"

    # ── StockLevel — the derived rollup ───────────────────────────────────
    create table(:slv_stock_level, primary_key: false) do
      add(:slv_qty_on_hand, :bigint, null: false, default: 0)
      add(:slv_qty_on_order, :bigint, null: false, default: 0)
      add(:slv_avg_unit_cost_cents, :bigint)
      add(:slv_stock_value_cents, :bigint, null: false, default: 0)
      add(:slv_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:slv_org_id, :uuid, null: false)
      add(:slv_inserted_at, :utc_datetime, null: false)
      add(:slv_updated_at, :utc_datetime, null: false)

      add(
        :slv_item_id,
        references(:sit_item, column: :sit_id, name: "slv_stock_level_slv_item_id_fkey", type: :uuid)
      )

      add(
        :slv_warehouse_id,
        references(:swh_warehouse, column: :swh_id, name: "slv_stock_level_slv_warehouse_id_fkey", type: :uuid)
      )
    end

    create(index(:slv_stock_level, [:slv_org_id]))
    create(index(:slv_stock_level, [:slv_item_id]))
    create(index(:slv_stock_level, [:slv_warehouse_id]))

    create(
      unique_index(:slv_stock_level, [:slv_org_id, :slv_item_id, :slv_warehouse_id],
        name: :slv_stock_level_unique_level
      )
    )

    # The rollup belt: every write needs the transaction-local
    # `samen.stock_sync` marker (only StockLevelSync arms it), and an armed
    # write must MATCH the ledger's own sums — the belt re-derives the truth
    # and refuses divergence. The rollup is derived, never asserted: even a
    # marker-armed hand-edit cannot land a wrong number.
    execute """
            CREATE FUNCTION slv_stock_level_enforce_derived() RETURNS trigger LANGUAGE plpgsql AS $$
            DECLARE
              armed boolean := COALESCE(
                current_setting('samen.stock_sync', true) = 'on', false
              );
              on_hand bigint;
              value bigint;
            BEGIN
              IF TG_OP = 'DELETE' THEN
                RAISE EXCEPTION 'slv_stock_level: DELETE is refused — the rollup row is derived '
                  'state; it lives and dies with its (item, warehouse) pair. Level id: %',
                  OLD.slv_id;
              END IF;

              IF NOT armed THEN
                RAISE EXCEPTION 'slv_stock_level: write requires the transaction-local sync marker '
                  '(samen.stock_sync) — the rollup is written only by StockLevelSync, inside the '
                  'ledger event''s transaction. Operation: %, level id: %',
                  TG_OP, COALESCE(NEW.slv_id::text, 'n/a');
              END IF;

              SELECT COALESCE(SUM(skl.skl_qty), 0),
                     COALESCE(SUM(skl.skl_qty * skl.skl_unit_cost_cents), 0)
                INTO on_hand, value
              FROM skl_stock_ledger skl
              WHERE skl.skl_org_id = NEW.slv_org_id
                AND skl.skl_item_id = NEW.slv_item_id
                AND skl.skl_warehouse_id = NEW.slv_warehouse_id;

              IF NEW.slv_qty_on_hand IS DISTINCT FROM on_hand
                 OR NEW.slv_stock_value_cents IS DISTINCT FROM value THEN
                RAISE EXCEPTION 'slv_stock_level: the rollup write DIVERGES from the ledger '
                  '(qty: % vs %, value: % vs %) — the rollup is derived from the ledger, '
                  'never asserted over it',
                  NEW.slv_qty_on_hand, on_hand, NEW.slv_stock_value_cents, value;
              END IF;

              RETURN COALESCE(NEW, OLD);
            END;
            $$
            """,
            "DROP FUNCTION IF EXISTS slv_stock_level_enforce_derived()"

    execute """
            CREATE TRIGGER slv_stock_level_derived_tg
            BEFORE INSERT OR UPDATE OR DELETE ON slv_stock_level
            FOR EACH ROW EXECUTE FUNCTION slv_stock_level_enforce_derived()
            """,
            "DROP TRIGGER IF EXISTS slv_stock_level_derived_tg ON slv_stock_level"

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    execute "DROP TRIGGER IF EXISTS slv_stock_level_derived_tg ON slv_stock_level"
    execute "DROP FUNCTION IF EXISTS slv_stock_level_enforce_derived()"
    execute "DROP TRIGGER IF EXISTS skl_stock_ledger_negative_stock_tg ON skl_stock_ledger"
    execute "DROP FUNCTION IF EXISTS skl_stock_ledger_enforce_negative_stock()"
    execute "DROP TRIGGER IF EXISTS skl_stock_ledger_append_only_tg ON skl_stock_ledger"
    execute "DROP FUNCTION IF EXISTS skl_stock_ledger_enforce_append_only()"
    drop(table(:slv_stock_level))
    drop(table(:skl_stock_ledger))
    drop(table(:swh_warehouse))
    drop(table(:sit_item))
  end
end
