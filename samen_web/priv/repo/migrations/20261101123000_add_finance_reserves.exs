defmodule Samen.WebTest.Repo.Migrations.AddFinanceReserves do
  @moduledoc """
  WS-ACCT Phase 9 (ADR-054 D10) — the obsolescence / NRV reserve on the
  `samen_web` test host (`Samen.WebTest.Erp`): policy `fro`, write-down `frv`,
  line `frw`. See `samen_core/priv/test_repo/migrations/
  20261101140000_add_finance_reserves.exs` for the shape and the belts; the
  prefixes are the host's allocator-reserved abbrevs.
  """

  use Samen.Migration

  @resources [
    Samen.WebTest.Erp.InventoryReserve,
    Samen.WebTest.Erp.ReserveWriteDown,
    Samen.WebTest.Erp.ReserveWriteDownLine
  ]

  def up do
    create table(:fro_inventory_reserve, primary_key: false) do
      add(:fro_name, :text, null: false)
      add(:fro_basis, :text, null: false)
      add(:fro_age_months, :integer)
      add(:fro_pct, :integer, null: false)

      add(:fro_applies_to, {:array, :uuid},
        null: false,
        default: fragment("'{}'::uuid[]")
      )

      add(:fro_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:fro_org_id, :uuid, null: false)
      add(:fro_inserted_at, :utc_datetime, null: false)
      add(:fro_updated_at, :utc_datetime, null: false)
    end

    create(index(:fro_inventory_reserve, [:fro_org_id]))

    create(unique_index(:fro_inventory_reserve, [:fro_org_id, :fro_name], name: :fro_name_unique))

    create(
      constraint(:fro_inventory_reserve, :fro_basis_valid, check: "fro_basis IN ('age','item')")
    )

    create(
      constraint(:fro_inventory_reserve, :fro_pct_valid, check: "fro_pct > 0 AND fro_pct <= 100")
    )

    create(
      constraint(:fro_inventory_reserve, :fro_shape_valid,
        check: """
        ((fro_basis = 'age' AND fro_age_months IS NOT NULL AND fro_age_months > 0) OR
         (fro_basis = 'item' AND fro_age_months IS NULL AND cardinality(fro_applies_to) > 0))
        """
      )
    )

    create table(:frv_reserve_write_down, primary_key: false) do
      add(:frv_assessed_on, :date, null: false)
      add(:frv_status, :text, null: false, default: "draft")
      add(:frv_amount_cents, :bigint, null: false)
      add(:frv_posted_at, :utc_datetime)

      add(
        :frv_policy_id,
        references(:fro_inventory_reserve,
          column: :fro_id,
          name: "frv_reserve_write_down_frv_policy_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(
        :frv_entry_id,
        references(:fje_journal_entry,
          column: :fje_id,
          name: "frv_reserve_write_down_frv_entry_id_fkey",
          type: :uuid
        )
      )

      add(:frv_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:frv_org_id, :uuid, null: false)
      add(:frv_inserted_at, :utc_datetime, null: false)
      add(:frv_updated_at, :utc_datetime, null: false)
    end

    create(index(:frv_reserve_write_down, [:frv_org_id]))
    create(index(:frv_reserve_write_down, [:frv_policy_id]))
    create(index(:frv_reserve_write_down, [:frv_entry_id]))

    create(
      constraint(:frv_reserve_write_down, :frv_status_valid,
        check: "frv_status IN ('draft','posted')"
      )
    )

    create(
      constraint(:frv_reserve_write_down, :frv_amount_positive, check: "frv_amount_cents > 0")
    )

    create(
      constraint(:frv_reserve_write_down, :frv_posted_complete,
        check: """
        ((frv_status = 'posted' AND frv_entry_id IS NOT NULL AND frv_posted_at IS NOT NULL) OR
         (frv_status = 'draft' AND frv_entry_id IS NULL AND frv_posted_at IS NULL))
        """
      )
    )

    create table(:frw_reserve_write_down_line, primary_key: false) do
      add(:frw_item_id, :uuid, null: false)
      add(:frw_quantity, :integer, null: false)
      add(:frw_cost_cents, :bigint, null: false)
      add(:frw_write_down_cents, :bigint, null: false)

      add(
        :frw_write_down_id,
        references(:frv_reserve_write_down,
          column: :frv_id,
          name: "frw_reserve_line_frw_write_down_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(
        :frw_inventory_account_id,
        references(:fca_account,
          column: :fca_id,
          name: "frw_reserve_line_frw_inventory_account_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(:frw_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:frw_org_id, :uuid, null: false)
      add(:frw_inserted_at, :utc_datetime, null: false)
      add(:frw_updated_at, :utc_datetime, null: false)
    end

    create(index(:frw_reserve_write_down_line, [:frw_org_id]))
    create(index(:frw_reserve_write_down_line, [:frw_write_down_id]))
    create(index(:frw_reserve_write_down_line, [:frw_item_id]))
    create(index(:frw_reserve_write_down_line, [:frw_inventory_account_id]))

    create(
      unique_index(
        :frw_reserve_write_down_line,
        [:frw_org_id, :frw_write_down_id, :frw_item_id],
        name: :frw_item_unique
      )
    )

    create(
      constraint(:frw_reserve_write_down_line, :frw_amount_positive,
        check: "frw_quantity > 0 AND frw_cost_cents > 0 AND frw_write_down_cents > 0"
      )
    )

    execute(
      """
      CREATE FUNCTION frv_reserve_posted_final() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        IF OLD.frv_status = 'posted' THEN
          RAISE EXCEPTION 'frv_reserve_write_down: % is refused — a posted write-down is final; a correction is a new proposal and entry, never a rewrite. Id: %', TG_OP, OLD.frv_id;
        END IF;
        RETURN NEW;
      END;
      $$;
      """,
      "DROP FUNCTION IF EXISTS frv_reserve_posted_final()"
    )

    execute(
      """
      CREATE TRIGGER frv_reserve_posted_final_tg
      BEFORE UPDATE ON frv_reserve_write_down
      FOR EACH ROW EXECUTE FUNCTION frv_reserve_posted_final()
      """,
      "DROP TRIGGER IF EXISTS frv_reserve_posted_final_tg ON frv_reserve_write_down"
    )

    execute(
      """
      CREATE FUNCTION frw_reserve_line_append_only() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        RAISE EXCEPTION 'frw_reserve_write_down_line: % is refused — an assessed line is an append-only fact. Line id: %', TG_OP, OLD.frw_id;
      END;
      $$;
      """,
      "DROP FUNCTION IF EXISTS frw_reserve_line_append_only()"
    )

    execute(
      """
      CREATE TRIGGER frw_reserve_line_append_only_tg
      BEFORE UPDATE OR DELETE ON frw_reserve_write_down_line
      FOR EACH ROW EXECUTE FUNCTION frw_reserve_line_append_only()
      """,
      "DROP TRIGGER IF EXISTS frw_reserve_line_append_only_tg ON frw_reserve_write_down_line"
    )

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    execute(
      "DROP TRIGGER IF EXISTS frw_reserve_line_append_only_tg ON frw_reserve_write_down_line"
    )

    execute("DROP FUNCTION IF EXISTS frw_reserve_line_append_only()")
    execute("DROP TRIGGER IF EXISTS frv_reserve_posted_final_tg ON frv_reserve_write_down")
    execute("DROP FUNCTION IF EXISTS frv_reserve_posted_final()")

    drop(table(:frw_reserve_write_down_line))
    drop(table(:frv_reserve_write_down))
    drop(table(:fro_inventory_reserve))
  end
end
