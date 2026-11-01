defmodule Samenerp.Repo.Migrations.AddFinanceReserves do
  @moduledoc """
  WS-ACCT Phase 9 (ADR-054 D10) — the obsolescence / NRV reserve on the
  `samenerp` host (`Samenerp.Erp`): policy `ear`, write-down `eav`, line
  `eaw`. See `samen_core/priv/test_repo/migrations/
  20261101140000_add_finance_reserves.exs` for the shape and the belts; the
  prefixes are the host's allocator-reserved abbrevs.
  """

  use Samen.Migration

  @resources [
    Samenerp.Erp.InventoryReserve,
    Samenerp.Erp.ReserveWriteDown,
    Samenerp.Erp.ReserveWriteDownLine
  ]

  def up do
    create table(:ear_inventory_reserve, primary_key: false) do
      add(:ear_name, :text, null: false)
      add(:ear_basis, :text, null: false)
      add(:ear_age_months, :integer)
      add(:ear_pct, :integer, null: false)

      add(:ear_applies_to, {:array, :uuid},
        null: false,
        default: fragment("'{}'::uuid[]")
      )

      add(:ear_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:ear_org_id, :uuid, null: false)
      add(:ear_inserted_at, :utc_datetime, null: false)
      add(:ear_updated_at, :utc_datetime, null: false)
    end

    create(index(:ear_inventory_reserve, [:ear_org_id]))

    create(unique_index(:ear_inventory_reserve, [:ear_org_id, :ear_name], name: :ear_name_unique))

    create(
      constraint(:ear_inventory_reserve, :ear_basis_valid, check: "ear_basis IN ('age','item')")
    )

    create(
      constraint(:ear_inventory_reserve, :ear_pct_valid, check: "ear_pct > 0 AND ear_pct <= 100")
    )

    create(
      constraint(:ear_inventory_reserve, :ear_shape_valid,
        check: """
        ((ear_basis = 'age' AND ear_age_months IS NOT NULL AND ear_age_months > 0) OR
         (ear_basis = 'item' AND ear_age_months IS NULL AND cardinality(ear_applies_to) > 0))
        """
      )
    )

    create table(:eav_reserve_write_down, primary_key: false) do
      add(:eav_assessed_on, :date, null: false)
      add(:eav_status, :text, null: false, default: "draft")
      add(:eav_amount_cents, :bigint, null: false)
      add(:eav_posted_at, :utc_datetime)

      add(
        :eav_policy_id,
        references(:ear_inventory_reserve,
          column: :ear_id,
          name: "eav_reserve_write_down_eav_policy_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(
        :eav_entry_id,
        references(:ecj_journal_entry,
          column: :ecj_id,
          name: "eav_reserve_write_down_eav_entry_id_fkey",
          type: :uuid
        )
      )

      add(:eav_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:eav_org_id, :uuid, null: false)
      add(:eav_inserted_at, :utc_datetime, null: false)
      add(:eav_updated_at, :utc_datetime, null: false)
    end

    create(index(:eav_reserve_write_down, [:eav_org_id]))
    create(index(:eav_reserve_write_down, [:eav_policy_id]))
    create(index(:eav_reserve_write_down, [:eav_entry_id]))

    create(
      constraint(:eav_reserve_write_down, :eav_status_valid,
        check: "eav_status IN ('draft','posted')"
      )
    )

    create(
      constraint(:eav_reserve_write_down, :eav_amount_positive, check: "eav_amount_cents > 0")
    )

    create(
      constraint(:eav_reserve_write_down, :eav_posted_complete,
        check: """
        ((eav_status = 'posted' AND eav_entry_id IS NOT NULL AND eav_posted_at IS NOT NULL) OR
         (eav_status = 'draft' AND eav_entry_id IS NULL AND eav_posted_at IS NULL))
        """
      )
    )

    create table(:eaw_reserve_write_down_line, primary_key: false) do
      add(:eaw_item_id, :uuid, null: false)
      add(:eaw_quantity, :integer, null: false)
      add(:eaw_cost_cents, :bigint, null: false)
      add(:eaw_write_down_cents, :bigint, null: false)

      add(
        :eaw_write_down_id,
        references(:eav_reserve_write_down,
          column: :eav_id,
          name: "eaw_reserve_line_eaw_write_down_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(
        :eaw_inventory_account_id,
        references(:eca_account,
          column: :eca_id,
          name: "eaw_reserve_line_eaw_inventory_account_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(:eaw_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:eaw_org_id, :uuid, null: false)
      add(:eaw_inserted_at, :utc_datetime, null: false)
      add(:eaw_updated_at, :utc_datetime, null: false)
    end

    create(index(:eaw_reserve_write_down_line, [:eaw_org_id]))
    create(index(:eaw_reserve_write_down_line, [:eaw_write_down_id]))
    create(index(:eaw_reserve_write_down_line, [:eaw_item_id]))
    create(index(:eaw_reserve_write_down_line, [:eaw_inventory_account_id]))

    create(
      unique_index(
        :eaw_reserve_write_down_line,
        [:eaw_org_id, :eaw_write_down_id, :eaw_item_id],
        name: :eaw_item_unique
      )
    )

    create(
      constraint(:eaw_reserve_write_down_line, :eaw_amount_positive,
        check: "eaw_quantity > 0 AND eaw_cost_cents > 0 AND eaw_write_down_cents > 0"
      )
    )

    execute(
      """
      CREATE FUNCTION eav_reserve_posted_final() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        IF OLD.eav_status = 'posted' THEN
          RAISE EXCEPTION 'eav_reserve_write_down: % is refused — a posted write-down is final; a correction is a new proposal and entry, never a rewrite. Id: %', TG_OP, OLD.eav_id;
        END IF;
        RETURN NEW;
      END;
      $$;
      """,
      "DROP FUNCTION IF EXISTS eav_reserve_posted_final()"
    )

    execute(
      """
      CREATE TRIGGER eav_reserve_posted_final_tg
      BEFORE UPDATE ON eav_reserve_write_down
      FOR EACH ROW EXECUTE FUNCTION eav_reserve_posted_final()
      """,
      "DROP TRIGGER IF EXISTS eav_reserve_posted_final_tg ON eav_reserve_write_down"
    )

    execute(
      """
      CREATE FUNCTION eaw_reserve_line_append_only() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        RAISE EXCEPTION 'eaw_reserve_write_down_line: % is refused — an assessed line is an append-only fact. Line id: %', TG_OP, OLD.eaw_id;
      END;
      $$;
      """,
      "DROP FUNCTION IF EXISTS eaw_reserve_line_append_only()"
    )

    execute(
      """
      CREATE TRIGGER eaw_reserve_line_append_only_tg
      BEFORE UPDATE OR DELETE ON eaw_reserve_write_down_line
      FOR EACH ROW EXECUTE FUNCTION eaw_reserve_line_append_only()
      """,
      "DROP TRIGGER IF EXISTS eaw_reserve_line_append_only_tg ON eaw_reserve_write_down_line"
    )

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    execute(
      "DROP TRIGGER IF EXISTS eaw_reserve_line_append_only_tg ON eaw_reserve_write_down_line"
    )

    execute("DROP FUNCTION IF EXISTS eaw_reserve_line_append_only()")
    execute("DROP TRIGGER IF EXISTS eav_reserve_posted_final_tg ON eav_reserve_write_down")
    execute("DROP FUNCTION IF EXISTS eav_reserve_posted_final()")

    drop(table(:eaw_reserve_write_down_line))
    drop(table(:eav_reserve_write_down))
    drop(table(:ear_inventory_reserve))
  end
end
