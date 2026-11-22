defmodule Samenerp.Repo.Migrations.MountInventoryLogistics do
  @moduledoc """
  WS-LOG L1 — mount the partial-shipment document pair and the maintained
  lot-tracked flag on the real host (`Samenerp.Erp`):

    * `eni_item.eni_lot_tracked` (logical `lot_tracked`) is initialized from
      existing `elt_lot` rows. The live preflights remain authoritative; this
      migration only seeds the flag and the post-deploy reconciliation can
      re-run the predicate.
    * `shp_shipment` / `shm_shipment_line` are the L1 header and line tables.
      `shp` is reserved for `Samenerp.Erp.Shipment`; `shm` is the free
      shipment-line prefix (the documented `shl` candidate is already owned by
      `Samenerp.Hr.LeaveRequest`).
    * the sales-order status check and trigger admit the two marker-armed
      partial-fulfillment transitions while retaining the legacy
      `confirmed -> fulfilled` bridge.

  This is an additive `:expand` migration with an explicit `down/0`; the
  catalog rows are written in the same transaction as the DDL.
  """

  use Samen.Migration, phase: :expand

  @shipment_resources [Samenerp.Erp.Shipment, Samenerp.Erp.ShipmentLine]

  @old_status_check """
  ALTER TABLE eso_sales_order
    ADD CONSTRAINT eso_status_valid CHECK (eso_status IN
      ('draft','confirmed','fulfilled','cancelled'))
  """

  @new_status_check """
  ALTER TABLE eso_sales_order
    ADD CONSTRAINT eso_status_valid CHECK (eso_status IN
      ('draft','confirmed','partially_fulfilled','fulfilled','cancelled'))
  """

  @old_state_function """
  CREATE OR REPLACE FUNCTION eso_sales_order_enforce_state() RETURNS trigger LANGUAGE plpgsql AS $$
  DECLARE
    armed boolean := COALESCE(current_setting('samen.finance_posting', true) = 'on', false);
  BEGIN
    IF TG_OP = 'INSERT' THEN
      IF NEW.eso_status IS DISTINCT FROM 'draft' THEN
        RAISE EXCEPTION 'eso_sales_order: a SO is born a draft (got %) — the only '
          'route to any other state is a governed transition (so: %)',
          NEW.eso_status, NEW.eso_id;
      END IF;
      RETURN NEW;
    END IF;

    IF NEW.eso_status = OLD.eso_status THEN
      RETURN NEW;
    END IF;

    IF NEW.eso_status = 'fulfilled' THEN
      IF NOT armed THEN
        RAISE EXCEPTION 'eso_sales_order: →fulfilled requires the transaction-local '
          'posting marker (samen.finance_posting) — a SO fulfills only through the '
          ':fulfill bridge (so: %, % → %)',
          OLD.eso_id, OLD.eso_status, NEW.eso_status;
      END IF;

      IF OLD.eso_status IS DISTINCT FROM 'confirmed' THEN
        RAISE EXCEPTION 'eso_sales_order: illegal →fulfilled transition from % (so: %)',
          OLD.eso_status, OLD.eso_id;
      END IF;

      RETURN NEW;
    END IF;

    IF NEW.eso_status = 'confirmed' THEN
      IF OLD.eso_status IS DISTINCT FROM 'draft' THEN
        RAISE EXCEPTION 'eso_sales_order: illegal →confirmed transition from % (so: %)',
          OLD.eso_status, OLD.eso_id;
      END IF;

      RETURN NEW;
    END IF;

    IF NEW.eso_status = 'cancelled' THEN
      IF OLD.eso_status NOT IN ('draft', 'confirmed') THEN
        RAISE EXCEPTION 'eso_sales_order: illegal →cancelled transition from % — a '
          'fulfilled SO''s stock and invoice are facts (so: %)',
          OLD.eso_status, OLD.eso_id;
      END IF;

      RETURN NEW;
    END IF;

    RAISE EXCEPTION 'eso_sales_order: unknown status % (so: %)', NEW.eso_status, OLD.eso_id;
  END;
  $$
  """

  @new_state_function """
  CREATE OR REPLACE FUNCTION eso_sales_order_enforce_state() RETURNS trigger LANGUAGE plpgsql AS $$
  DECLARE
    armed boolean := COALESCE(current_setting('samen.finance_posting', true) = 'on', false);
  BEGIN
    IF TG_OP = 'INSERT' THEN
      IF NEW.eso_status IS DISTINCT FROM 'draft' THEN
        RAISE EXCEPTION 'eso_sales_order: a SO is born a draft (got %) — the only '
          'route to any other state is a governed transition (so: %)',
          NEW.eso_status, NEW.eso_id;
      END IF;
      RETURN NEW;
    END IF;

    IF NEW.eso_status = OLD.eso_status THEN
      RETURN NEW;
    END IF;

    IF NEW.eso_status = 'fulfilled' THEN
      IF NOT armed THEN
        RAISE EXCEPTION 'eso_sales_order: →fulfilled requires the transaction-local '
          'posting marker (samen.finance_posting) — a SO fulfills only through the '
          'governed posting path (so: %, % → %)',
          OLD.eso_id, OLD.eso_status, NEW.eso_status;
      END IF;

      IF OLD.eso_status NOT IN ('confirmed', 'partially_fulfilled') THEN
        RAISE EXCEPTION 'eso_sales_order: illegal →fulfilled transition from % (so: %)',
          OLD.eso_status, OLD.eso_id;
      END IF;

      RETURN NEW;
    END IF;

    IF NEW.eso_status = 'partially_fulfilled' THEN
      IF NOT armed THEN
        RAISE EXCEPTION 'eso_sales_order: →partially_fulfilled requires the '
          'transaction-local posting marker (samen.finance_posting) — a partial '
          'fulfillment lands only through the shipment posting path (so: %, % → %)',
          OLD.eso_id, OLD.eso_status, NEW.eso_status;
      END IF;

      IF OLD.eso_status IS DISTINCT FROM 'confirmed' THEN
        RAISE EXCEPTION 'eso_sales_order: illegal →partially_fulfilled transition from % '
          '(so: %)', OLD.eso_status, OLD.eso_id;
      END IF;

      RETURN NEW;
    END IF;

    IF NEW.eso_status = 'confirmed' THEN
      IF OLD.eso_status IS DISTINCT FROM 'draft' THEN
        RAISE EXCEPTION 'eso_sales_order: illegal →confirmed transition from % (so: %)',
          OLD.eso_status, OLD.eso_id;
      END IF;

      RETURN NEW;
    END IF;

    IF NEW.eso_status = 'cancelled' THEN
      IF OLD.eso_status NOT IN ('draft', 'confirmed') THEN
        RAISE EXCEPTION 'eso_sales_order: illegal →cancelled transition from % — a '
          'fulfilled SO''s stock and invoice are facts (so: %)',
          OLD.eso_status, OLD.eso_id;
      END IF;

      RETURN NEW;
    END IF;

    RAISE EXCEPTION 'eso_sales_order: unknown status % (so: %)', NEW.eso_status, OLD.eso_id;
  END;
  $$
  """

  def up do
    alter table(:eni_item) do
      add(:eni_lot_tracked, :boolean, null: false, default: false)
    end

    execute("""
    UPDATE eni_item i
       SET eni_lot_tracked = true
     WHERE EXISTS (
       SELECT 1 FROM elt_lot l WHERE l.elt_item_id = i.eni_id
     )
    """)

    create table(:shp_shipment, primary_key: false) do
      add(:shp_number, :text, null: false)
      add(:shp_status, :text, null: false, default: "draft")
      add(:shp_shipped_at, :utc_datetime)
      add(:shp_invoice_key, :text)
      add(:shp_invoice_id, :uuid)
      add(:shp_memo, :text)
      add(:shp_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:shp_org_id, :uuid, null: false)
      add(:shp_inserted_at, :utc_datetime, null: false)
      add(:shp_updated_at, :utc_datetime, null: false)

      add(
        :shp_sales_order_id,
        references(:eso_sales_order,
          column: :eso_id,
          name: "shp_shipment_shp_sales_order_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(
        :shp_warehouse_id,
        references(:enw_warehouse,
          column: :enw_id,
          name: "shp_shipment_shp_warehouse_id_fkey",
          type: :uuid
        ),
        null: false
      )
    end

    create(index(:shp_shipment, [:shp_org_id]))
    create(index(:shp_shipment, [:shp_org_id, :shp_number], unique: true))
    create(index(:shp_shipment, [:shp_sales_order_id]))
    create(index(:shp_shipment, [:shp_warehouse_id]))

    create(
      constraint(:shp_shipment, :shp_status_valid, check: "shp_status IN ('draft', 'shipped')")
    )

    create table(:shm_shipment_line, primary_key: false) do
      add(:shm_qty, :bigint, null: false)
      add(:shm_unit_price_cents, :bigint, null: false, default: 0)
      add(:shm_unit_cost_cents, :bigint)
      add(:shm_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:shm_org_id, :uuid, null: false)
      add(:shm_inserted_at, :utc_datetime, null: false)
      add(:shm_updated_at, :utc_datetime, null: false)

      add(
        :shm_shipment_id,
        references(:shp_shipment,
          column: :shp_id,
          name: "shm_shipment_line_shm_shipment_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(
        :shm_so_line_id,
        references(:esl_so_line,
          column: :esl_id,
          name: "shm_shipment_line_shm_so_line_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(
        :shm_item_id,
        references(:eni_item,
          column: :eni_id,
          name: "shm_shipment_line_shm_item_id_fkey",
          type: :uuid
        ),
        null: false
      )
    end

    create(index(:shm_shipment_line, [:shm_org_id]))
    create(index(:shm_shipment_line, [:shm_shipment_id]))
    create(index(:shm_shipment_line, [:shm_so_line_id]))
    create(index(:shm_shipment_line, [:shm_item_id]))

    create(
      unique_index(:shm_shipment_line, [:shm_shipment_id, :shm_so_line_id],
        name: :shm_shipment_line_shipment_so_line_unique
      )
    )

    create(constraint(:shm_shipment_line, :shm_qty_positive, check: "shm_qty > 0"))

    create(
      constraint(:shm_shipment_line, :shm_unit_costs_non_negative,
        check: "shm_unit_price_cents >= 0 AND shm_unit_cost_cents >= 0"
      )
    )

    execute("ALTER TABLE eso_sales_order DROP CONSTRAINT eso_status_valid")
    execute(@new_status_check)
    execute(@new_state_function)

    catalog_sync([Samenerp.Erp.Item], only: [:lot_tracked])
    catalog_sync(@shipment_resources)
  end

  def down do
    catalog_sync_down(@shipment_resources)
    catalog_sync_down([Samenerp.Erp.Item], only: [:lot_tracked])

    execute("ALTER TABLE eso_sales_order DROP CONSTRAINT eso_status_valid")
    execute(@old_status_check)
    execute(@old_state_function)

    drop(table(:shm_shipment_line))
    drop(table(:shp_shipment))

    alter table(:eni_item) do
      remove(:eni_lot_tracked)
    end
  end
end
