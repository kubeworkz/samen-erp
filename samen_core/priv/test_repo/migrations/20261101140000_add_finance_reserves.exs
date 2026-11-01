defmodule SamenCore.TestRepo.Migrations.AddFinanceReserves do
  @moduledoc """
  WS-ACCT Phase 9 (ADR-054 D10) — the obsolescence / NRV reserve in the
  `samen_core` test fixture (`SamenCore.Support.FinanceFixture`): policy `fsr`,
  write-down `fsq`, line `fsz`.

    * `fsr_inventory_reserve` — the POLICY: basis (`age`/`item`), the age
      threshold, the write-down percentage, and the item ids it covers. It is a
      rule, not a balance; nothing posts when a policy is created.
    * `fsq_reserve_write_down` — one proposal and, once the ADR-040 Gate
      approves it, its posting (`entry_id`, `posted_at`).
    * `fsz_reserve_write_down_line` — the per-item assessment the proposal was
      built from: quantity, carrying cost, write-down cents, and the inventory
      account the credit leg pays.

  DB belts (over the Ash-side braces):

    * `fsr_name_unique` — one policy name per org;
    * `fsr_shape_valid` — `:age` needs a positive threshold; `:item` is
      age-independent and must name at least one item;
    * `fsr_pct_valid` — 1..100 (a write-down of nothing or of more than the
      carrying value is not an estimate);
    * `fsq_posted_complete` — `posted` iff dated and anchored to an entry;
    * `fsq_posted_final` trigger — a posted row can never be updated again;
    * `fsz_item_unique` — one line per item per proposal;
    * `fsz_amount_positive` — a zero-cent line is not a fact;
    * `fsz_reserve_line_append_only` trigger — lines are never rewritten.

  Catalog rows via `catalog_sync/1` in the same transaction (ADR-004).
  """

  use Samen.Migration

  @resources [
    SamenCore.Support.FinanceFixture.InventoryReserve,
    SamenCore.Support.FinanceFixture.ReserveWriteDown,
    SamenCore.Support.FinanceFixture.ReserveWriteDownLine
  ]

  def up do
    create table(:fsr_inventory_reserve, primary_key: false) do
      add(:fsr_name, :text, null: false)
      add(:fsr_basis, :text, null: false)
      add(:fsr_age_months, :integer)
      add(:fsr_pct, :integer, null: false)

      add(:fsr_applies_to, {:array, :uuid},
        null: false,
        default: fragment("'{}'::uuid[]")
      )

      add(:fsr_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:fsr_org_id, :uuid, null: false)
      add(:fsr_inserted_at, :utc_datetime, null: false)
      add(:fsr_updated_at, :utc_datetime, null: false)
    end

    create(index(:fsr_inventory_reserve, [:fsr_org_id]))

    create(unique_index(:fsr_inventory_reserve, [:fsr_org_id, :fsr_name], name: :fsr_name_unique))

    create(
      constraint(:fsr_inventory_reserve, :fsr_basis_valid, check: "fsr_basis IN ('age','item')")
    )

    create(
      constraint(:fsr_inventory_reserve, :fsr_pct_valid, check: "fsr_pct > 0 AND fsr_pct <= 100")
    )

    create(
      constraint(:fsr_inventory_reserve, :fsr_shape_valid,
        check: """
        ((fsr_basis = 'age' AND fsr_age_months IS NOT NULL AND fsr_age_months > 0) OR
         (fsr_basis = 'item' AND fsr_age_months IS NULL AND cardinality(fsr_applies_to) > 0))
        """
      )
    )

    create table(:fsq_reserve_write_down, primary_key: false) do
      add(:fsq_assessed_on, :date, null: false)
      add(:fsq_status, :text, null: false, default: "draft")
      add(:fsq_amount_cents, :bigint, null: false)
      add(:fsq_posted_at, :utc_datetime)

      add(
        :fsq_policy_id,
        references(:fsr_inventory_reserve,
          column: :fsr_id,
          name: "fsq_reserve_write_down_fsq_policy_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(
        :fsq_entry_id,
        references(:sje_journal_entry,
          column: :sje_id,
          name: "fsq_reserve_write_down_fsq_entry_id_fkey",
          type: :uuid
        )
      )

      add(:fsq_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:fsq_org_id, :uuid, null: false)
      add(:fsq_inserted_at, :utc_datetime, null: false)
      add(:fsq_updated_at, :utc_datetime, null: false)
    end

    create(index(:fsq_reserve_write_down, [:fsq_org_id]))
    create(index(:fsq_reserve_write_down, [:fsq_policy_id]))
    create(index(:fsq_reserve_write_down, [:fsq_entry_id]))

    create(
      constraint(:fsq_reserve_write_down, :fsq_status_valid,
        check: "fsq_status IN ('draft','posted')"
      )
    )

    create(
      constraint(:fsq_reserve_write_down, :fsq_amount_positive, check: "fsq_amount_cents > 0")
    )

    create(
      constraint(:fsq_reserve_write_down, :fsq_posted_complete,
        check: """
        ((fsq_status = 'posted' AND fsq_entry_id IS NOT NULL AND fsq_posted_at IS NOT NULL) OR
         (fsq_status = 'draft' AND fsq_entry_id IS NULL AND fsq_posted_at IS NULL))
        """
      )
    )

    create table(:fsz_reserve_write_down_line, primary_key: false) do
      add(:fsz_item_id, :uuid, null: false)
      add(:fsz_quantity, :integer, null: false)
      add(:fsz_cost_cents, :bigint, null: false)
      add(:fsz_write_down_cents, :bigint, null: false)

      add(
        :fsz_write_down_id,
        references(:fsq_reserve_write_down,
          column: :fsq_id,
          name: "fsz_reserve_line_fsz_write_down_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(
        :fsz_inventory_account_id,
        references(:sac_account,
          column: :sac_id,
          name: "fsz_reserve_line_fsz_inventory_account_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(:fsz_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:fsz_org_id, :uuid, null: false)
      add(:fsz_inserted_at, :utc_datetime, null: false)
      add(:fsz_updated_at, :utc_datetime, null: false)
    end

    create(index(:fsz_reserve_write_down_line, [:fsz_org_id]))
    create(index(:fsz_reserve_write_down_line, [:fsz_write_down_id]))
    create(index(:fsz_reserve_write_down_line, [:fsz_item_id]))
    create(index(:fsz_reserve_write_down_line, [:fsz_inventory_account_id]))

    create(
      unique_index(
        :fsz_reserve_write_down_line,
        [:fsz_org_id, :fsz_write_down_id, :fsz_item_id],
        name: :fsz_item_unique
      )
    )

    create(
      constraint(:fsz_reserve_write_down_line, :fsz_amount_positive,
        check: "fsz_quantity > 0 AND fsz_cost_cents > 0 AND fsz_write_down_cents > 0"
      )
    )

    execute(
      """
      CREATE FUNCTION fsq_reserve_posted_final() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        IF OLD.fsq_status = 'posted' THEN
          RAISE EXCEPTION 'fsq_reserve_write_down: % is refused — a posted write-down is final; a correction is a new proposal and entry, never a rewrite. Id: %', TG_OP, OLD.fsq_id;
        END IF;
        RETURN NEW;
      END;
      $$;
      """,
      "DROP FUNCTION IF EXISTS fsq_reserve_posted_final()"
    )

    execute(
      """
      CREATE TRIGGER fsq_reserve_posted_final_tg
      BEFORE UPDATE ON fsq_reserve_write_down
      FOR EACH ROW EXECUTE FUNCTION fsq_reserve_posted_final()
      """,
      "DROP TRIGGER IF EXISTS fsq_reserve_posted_final_tg ON fsq_reserve_write_down"
    )

    execute(
      """
      CREATE FUNCTION fsz_reserve_line_append_only() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        RAISE EXCEPTION 'fsz_reserve_write_down_line: % is refused — an assessed line is an append-only fact. Line id: %', TG_OP, OLD.fsz_id;
      END;
      $$;
      """,
      "DROP FUNCTION IF EXISTS fsz_reserve_line_append_only()"
    )

    execute(
      """
      CREATE TRIGGER fsz_reserve_line_append_only_tg
      BEFORE UPDATE OR DELETE ON fsz_reserve_write_down_line
      FOR EACH ROW EXECUTE FUNCTION fsz_reserve_line_append_only()
      """,
      "DROP TRIGGER IF EXISTS fsz_reserve_line_append_only_tg ON fsz_reserve_write_down_line"
    )

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    execute(
      "DROP TRIGGER IF EXISTS fsz_reserve_line_append_only_tg ON fsz_reserve_write_down_line"
    )

    execute("DROP FUNCTION IF EXISTS fsz_reserve_line_append_only()")
    execute("DROP TRIGGER IF EXISTS fsq_reserve_posted_final_tg ON fsq_reserve_write_down")
    execute("DROP FUNCTION IF EXISTS fsq_reserve_posted_final()")

    drop(table(:fsz_reserve_write_down_line))
    drop(table(:fsq_reserve_write_down))
    drop(table(:fsr_inventory_reserve))
  end
end
