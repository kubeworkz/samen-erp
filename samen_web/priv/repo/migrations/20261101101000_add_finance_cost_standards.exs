defmodule Samen.WebTest.Repo.Migrations.AddFinanceCostStandards do
  @moduledoc """
  WS-ACCT Phase 7 (ADR-054 D4) — standard costing and its variance layer on the
  `samen_web` test host (`Samen.WebTest.Erp`, card `fst`, line `fsu`, variance
  `fsw`). Same shape and belts as the `samen_core` fixture leg:

    * `fst_cost_standard` — the effective-dated card, one per cost object per
      date, with the dimension axis its variance entries carry;
    * `fsu_cost_standard_line` — one element's standard qty/price/yield, with
      the cardinality and cross-field belts;
    * `fsw_cost_variance` — one posted variance fact, exactly-once per
      `{cost object, period, type}`, naming the accounts it landed on and
      append-only (UPDATE/DELETE refused by trigger).

  Catalog rows via `catalog_sync/1` in the same transaction (ADR-004).
  """

  use Samen.Migration

  @resources [
    Samen.WebTest.Erp.CostStandard,
    Samen.WebTest.Erp.CostStandardLine,
    Samen.WebTest.Erp.CostVariance
  ]

  def up do
    create table(:fst_cost_standard, primary_key: false) do
      add(:fst_code, :text, null: false)
      add(:fst_output_item_id, :uuid)
      add(:fst_effective_on, :date, null: false)
      add(:fst_memo, :text)
      add(:fst_dimension_key, :text, null: false, default: "project")

      add(
        :fst_cost_object_id,
        references(:fco_cost_object,
          column: :fco_id,
          name: "fst_cost_standard_fst_cost_object_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(:fst_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:fst_org_id, :uuid, null: false)
      add(:fst_inserted_at, :utc_datetime, null: false)
      add(:fst_updated_at, :utc_datetime, null: false)
    end

    create(index(:fst_cost_standard, [:fst_org_id]))
    create(index(:fst_cost_standard, [:fst_cost_object_id]))

    create(
      unique_index(:fst_cost_standard, [:fst_org_id, :fst_cost_object_id, :fst_effective_on],
        name: :fst_card_period_unique
      )
    )

    create(
      constraint(:fst_cost_standard, :fst_dimension_key_valid,
        check: "fst_dimension_key IN ('project','lot','fund','cost_pool')"
      )
    )

    create table(:fsu_cost_standard_line, primary_key: false) do
      add(:fsu_element, :text, null: false)
      add(:fsu_item_id, :uuid)
      add(:fsu_standard_qty, :bigint, null: false)
      add(:fsu_standard_unit_price_cents, :bigint, null: false)
      add(:fsu_expected_yield_bp, :integer, null: false, default: 10_000)
      add(:fsu_usage_basis, :text, null: false, default: "yield")

      add(
        :fsu_standard_id,
        references(:fst_cost_standard,
          column: :fst_id,
          name: "fsu_cost_standard_line_fsu_standard_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(:fsu_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:fsu_org_id, :uuid, null: false)
      add(:fsu_inserted_at, :utc_datetime, null: false)
      add(:fsu_updated_at, :utc_datetime, null: false)
    end

    create(index(:fsu_cost_standard_line, [:fsu_org_id]))
    create(index(:fsu_cost_standard_line, [:fsu_standard_id]))

    create(
      unique_index(
        :fsu_cost_standard_line,
        [:fsu_org_id, :fsu_standard_id, :fsu_element, :fsu_item_id], name: :fsu_line_unique)
    )

    create(
      unique_index(
        :fsu_cost_standard_line,
        [:fsu_org_id, :fsu_standard_id, :fsu_element],
        name: :fsu_line_no_item_unique,
        where: "fsu_item_id IS NULL"
      )
    )

    create(
      constraint(:fsu_cost_standard_line, :fsu_element_valid,
        check: "fsu_element IN ('material','labor','overhead')"
      )
    )

    create(
      constraint(:fsu_cost_standard_line, :fsu_usage_basis_valid,
        check: "fsu_usage_basis IN ('yield','bom','none')"
      )
    )

    create(
      constraint(:fsu_cost_standard_line, :fsu_amounts_valid,
        check: "fsu_standard_qty > 0 AND fsu_standard_unit_price_cents >= 0"
      )
    )

    create(
      constraint(:fsu_cost_standard_line, :fsu_yield_valid,
        check: "fsu_expected_yield_bp > 0 AND fsu_expected_yield_bp <= 10000"
      )
    )

    create(
      constraint(:fsu_cost_standard_line, :fsu_shape_valid,
        check: """
        (fsu_element = 'material' AND fsu_item_id IS NOT NULL) OR
        (fsu_element IN ('labor','overhead') AND fsu_item_id IS NULL)
        """
      )
    )

    create(
      constraint(:fsu_cost_standard_line, :fsu_usage_valid,
        check: """
        (fsu_element IN ('labor','overhead') AND fsu_usage_basis = 'none') OR
        (fsu_element = 'material')
        """
      )
    )

    create(
      constraint(:fsu_cost_standard_line, :fsu_bom_yield_valid,
        check: "fsu_usage_basis <> 'bom' OR fsu_expected_yield_bp = 10000"
      )
    )

    create table(:fsw_cost_variance, primary_key: false) do
      add(:fsw_period_key, :text, null: false)
      add(:fsw_type, :text, null: false)
      add(:fsw_amount_cents, :bigint, null: false)
      add(:fsw_actual_amount_cents, :bigint, null: false)
      add(:fsw_standard_amount_cents, :bigint, null: false)
      add(:fsw_disposition, :text)
      add(:fsw_inputs, :map, null: false)
      add(:fsw_posted_at, :utc_datetime)

      add(
        :fsw_variance_account_id,
        references(:fca_account,
          column: :fca_id,
          name: "fsw_cost_variance_fsw_variance_account_id_fkey",
          type: :uuid
        )
      )

      add(
        :fsw_disposition_account_id,
        references(:fca_account,
          column: :fca_id,
          name: "fsw_cost_variance_fsw_disposition_account_id_fkey",
          type: :uuid
        )
      )

      add(
        :fsw_entry_id,
        references(:fje_journal_entry,
          column: :fje_id,
          name: "fsw_cost_variance_fsw_entry_id_fkey",
          type: :uuid
        )
      )

      add(
        :fsw_standard_id,
        references(:fst_cost_standard,
          column: :fst_id,
          name: "fsw_cost_variance_fsw_standard_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(
        :fsw_cost_object_id,
        references(:fco_cost_object,
          column: :fco_id,
          name: "fsw_cost_variance_fsw_cost_object_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(:fsw_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:fsw_org_id, :uuid, null: false)
      add(:fsw_inserted_at, :utc_datetime, null: false)
      add(:fsw_updated_at, :utc_datetime, null: false)
    end

    create(index(:fsw_cost_variance, [:fsw_org_id]))
    create(index(:fsw_cost_variance, [:fsw_cost_object_id]))
    create(index(:fsw_cost_variance, [:fsw_period_key]))
    create(index(:fsw_cost_variance, [:fsw_standard_id]))
    create(index(:fsw_cost_variance, [:fsw_entry_id]))

    create(
      unique_index(
        :fsw_cost_variance,
        [:fsw_org_id, :fsw_cost_object_id, :fsw_period_key, :fsw_type],
        name: :fsw_variance_unique
      )
    )

    create(
      constraint(:fsw_cost_variance, :fsw_type_valid,
        check:
          "fsw_type IN ('ppv','yield','bom','labor_rate','labor_efficiency','overhead_spending','overhead_volume')"
      )
    )

    create(
      constraint(:fsw_cost_variance, :fsw_disposition_valid,
        check:
          "fsw_disposition IS NULL OR fsw_disposition IN ('absorb_inventory','write_off_cogs','write_off_rd')"
      )
    )

    create(
      constraint(:fsw_cost_variance, :fsw_amount_ties,
        check: "fsw_amount_cents = fsw_actual_amount_cents - fsw_standard_amount_cents"
      )
    )

    create(
      constraint(:fsw_cost_variance, :fsw_period_valid,
        check: "fsw_period_key ~ '^[0-9]{4}-(0[1-9]|1[0-2])$'"
      )
    )

    execute(
      """
      CREATE FUNCTION fsw_cost_variance_append_only() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        RAISE EXCEPTION 'fsw_cost_variance: % is refused — a variance is an append-only fact; '
          'a correction is a reversing entry, never a rewrite. Variance id: %', TG_OP, OLD.fsw_id;
      END;
      $$;
      """,
      "DROP FUNCTION IF EXISTS fsw_cost_variance_append_only()"
    )

    execute(
      """
      CREATE TRIGGER fsw_cost_variance_append_only_tg
      BEFORE UPDATE OR DELETE ON fsw_cost_variance
      FOR EACH ROW EXECUTE FUNCTION fsw_cost_variance_append_only()
      """,
      "DROP TRIGGER IF EXISTS fsw_cost_variance_append_only_tg ON fsw_cost_variance"
    )

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    execute("DROP TRIGGER IF EXISTS fsw_cost_variance_append_only_tg ON fsw_cost_variance")

    execute("DROP FUNCTION IF EXISTS fsw_cost_variance_append_only()")

    drop(table(:fsw_cost_variance))
    drop(table(:fsu_cost_standard_line))
    drop(table(:fst_cost_standard))
  end
end
