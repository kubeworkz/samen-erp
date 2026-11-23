defmodule SamenCore.TestRepo.Migrations.AddInventoryLogisticsFixture do
  @moduledoc """
  WS-LOG L1.2 fixture support for the Inventory scope's `logistics:` branch:

    * `sis_shipment` / `ssi_shipment_line` — the shipment document pair the
      `:ship` posting path consumes (the `sis`/`ssi` abbrevs are this
      fixture host's own; `shp`/`shm` belong to the samenerp host).
    * the sales-order status check and trigger admit the marker-armed
      `confirmed -> partially_fulfilled` and `partially_fulfilled -> fulfilled`
      transitions while retaining the legacy `confirmed -> fulfilled` bridge.

  Catalog rows are written in the same transaction as the DDL.
  """

  use Samen.Migration

  @resources [
    SamenCore.Support.InventoryFixture.Shipment,
    SamenCore.Support.InventoryFixture.ShipmentLine
  ]

  @old_status_check """
  ALTER TABLE slo_sales_order
    ADD CONSTRAINT slo_status_valid CHECK (slo_status IN
      ('draft','confirmed','fulfilled','cancelled'))
  """

  @new_status_check """
  ALTER TABLE slo_sales_order
    ADD CONSTRAINT slo_status_valid CHECK (slo_status IN
      ('draft','confirmed','partially_fulfilled','fulfilled','cancelled'))
  """

  @old_state_function """
  CREATE OR REPLACE FUNCTION slo_sales_order_enforce_state() RETURNS trigger LANGUAGE plpgsql AS $$
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
  """

  @new_state_function """
  CREATE OR REPLACE FUNCTION slo_sales_order_enforce_state() RETURNS trigger LANGUAGE plpgsql AS $$
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
          'governed posting path (so: %, % → %)',
          OLD.slo_id, OLD.slo_status, NEW.slo_status;
      END IF;

      IF OLD.slo_status NOT IN ('confirmed', 'partially_fulfilled') THEN
        RAISE EXCEPTION 'slo_sales_order: illegal →fulfilled transition from % (so: %)',
          OLD.slo_status, OLD.slo_id;
      END IF;

      RETURN NEW;
    END IF;

    IF NEW.slo_status = 'partially_fulfilled' THEN
      IF NOT armed THEN
        RAISE EXCEPTION 'slo_sales_order: →partially_fulfilled requires the '
          'transaction-local posting marker (samen.finance_posting) — a partial '
          'fulfillment lands only through the shipment posting path (so: %, % → %)',
          OLD.slo_id, OLD.slo_status, NEW.slo_status;
      END IF;

      IF OLD.slo_status IS DISTINCT FROM 'confirmed' THEN
        RAISE EXCEPTION 'slo_sales_order: illegal →partially_fulfilled transition from % '
          '(so: %)', OLD.slo_status, OLD.slo_id;
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
  """

  def up do
    create table(:sis_shipment, primary_key: false) do
      add(:sis_number, :text, null: false)
      add(:sis_status, :text, null: false, default: "draft")
      add(:sis_shipped_at, :utc_datetime)
      add(:sis_invoice_key, :text)
      add(:sis_invoice_id, :uuid)
      add(:sis_memo, :text)
      add(:sis_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:sis_org_id, :uuid, null: false)
      add(:sis_inserted_at, :utc_datetime, null: false)
      add(:sis_updated_at, :utc_datetime, null: false)

      add(
        :sis_sales_order_id,
        references(:slo_sales_order,
          column: :slo_id,
          name: "sis_shipment_sis_sales_order_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(
        :sis_warehouse_id,
        references(:swh_warehouse,
          column: :swh_id,
          name: "sis_shipment_sis_warehouse_id_fkey",
          type: :uuid
        ),
        null: false
      )
    end

    create(index(:sis_shipment, [:sis_org_id]))
    create(unique_index(:sis_shipment, [:sis_org_id, :sis_number]))
    create(index(:sis_shipment, [:sis_sales_order_id]))
    create(index(:sis_shipment, [:sis_warehouse_id]))

    create(
      constraint(:sis_shipment, :sis_status_valid, check: "sis_status IN ('draft', 'shipped')")
    )

    create table(:ssi_shipment_line, primary_key: false) do
      add(:ssi_qty, :bigint, null: false)
      add(:ssi_unit_price_cents, :bigint, null: false, default: 0)
      add(:ssi_unit_cost_cents, :bigint)
      add(:ssi_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:ssi_org_id, :uuid, null: false)
      add(:ssi_inserted_at, :utc_datetime, null: false)
      add(:ssi_updated_at, :utc_datetime, null: false)

      add(
        :ssi_shipment_id,
        references(:sis_shipment,
          column: :sis_id,
          name: "ssi_shipment_line_ssi_shipment_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(
        :ssi_so_line_id,
        references(:sol_so_line,
          column: :sol_id,
          name: "ssi_shipment_line_ssi_so_line_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(
        :ssi_item_id,
        references(:sit_item,
          column: :sit_id,
          name: "ssi_shipment_line_ssi_item_id_fkey",
          type: :uuid
        ),
        null: false
      )
    end

    create(index(:ssi_shipment_line, [:ssi_org_id]))
    create(index(:ssi_shipment_line, [:ssi_shipment_id]))
    create(index(:ssi_shipment_line, [:ssi_so_line_id]))
    create(index(:ssi_shipment_line, [:ssi_item_id]))

    create(
      unique_index(:ssi_shipment_line, [:ssi_shipment_id, :ssi_so_line_id],
        name: :ssi_shipment_line_shipment_so_line_unique
      )
    )

    create(constraint(:ssi_shipment_line, :ssi_qty_positive, check: "ssi_qty > 0"))

    create(
      constraint(:ssi_shipment_line, :ssi_unit_costs_non_negative,
        check: "ssi_unit_price_cents >= 0 AND ssi_unit_cost_cents >= 0"
      )
    )

    execute("ALTER TABLE slo_sales_order DROP CONSTRAINT slo_status_valid")
    execute(@new_status_check)
    execute(@new_state_function)

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    execute("ALTER TABLE slo_sales_order DROP CONSTRAINT slo_status_valid")
    execute(@old_status_check)
    execute(@old_state_function)

    drop(table(:ssi_shipment_line))
    drop(table(:sis_shipment))
  end
end
