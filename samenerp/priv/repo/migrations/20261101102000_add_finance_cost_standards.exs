defmodule Samenerp.Repo.Migrations.AddFinanceCostStandards do
  @moduledoc """
  WS-ACCT Phase 7 (ADR-054 D4) — standard costing and its variance layer on the
  Kubeworkz host (`Samenerp.Erp`, card `esc`, line `esm`, variance `esv`).

  The cards are HOST DATA, not seed data: the manual's standards (per chip, per
  board) are the operator's numbers, so the Phase 2 books seed deliberately
  creates none. What the seed DOES provide is the posting map the variance
  cascade resolves: the four variance family accounts and the two disposition
  targets (`cogs`, `rd_expense`) — see `Samenerp.Kubeworkz.Books`.

  Same shape and belts as the `samen_core` fixture leg: one card per cost object
  per effective date, the line-shape checks, exactly-once per
  `{cost object, period, type}`, the amount-ties check and the append-only
  trigger.

  Catalog rows via `catalog_sync/1` in the same transaction (ADR-004).
  """

  use Samen.Migration

  @resources [
    Samenerp.Erp.CostStandard,
    Samenerp.Erp.CostStandardLine,
    Samenerp.Erp.CostVariance
  ]

  def up do
    create table(:esc_cost_standard, primary_key: false) do
      add(:esc_code, :text, null: false)
      add(:esc_output_item_id, :uuid)
      add(:esc_effective_on, :date, null: false)
      add(:esc_memo, :text)
      add(:esc_dimension_key, :text, null: false, default: "project")

      add(
        :esc_cost_object_id,
        references(:eco_cost_object,
          column: :eco_id,
          name: "esc_cost_standard_esc_cost_object_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(:esc_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:esc_org_id, :uuid, null: false)
      add(:esc_inserted_at, :utc_datetime, null: false)
      add(:esc_updated_at, :utc_datetime, null: false)
    end

    create(index(:esc_cost_standard, [:esc_org_id]))
    create(index(:esc_cost_standard, [:esc_cost_object_id]))

    create(
      unique_index(:esc_cost_standard, [:esc_org_id, :esc_cost_object_id, :esc_effective_on],
        name: :esc_card_period_unique
      )
    )

    create(
      constraint(:esc_cost_standard, :esc_dimension_key_valid,
        check: "esc_dimension_key IN ('project','lot','fund','cost_pool')"
      )
    )

    create table(:esm_cost_standard_line, primary_key: false) do
      add(:esm_element, :text, null: false)
      add(:esm_item_id, :uuid)
      add(:esm_standard_qty, :bigint, null: false)
      add(:esm_standard_unit_price_cents, :bigint, null: false)
      add(:esm_expected_yield_bp, :integer, null: false, default: 10_000)
      add(:esm_usage_basis, :text, null: false, default: "yield")

      add(
        :esm_standard_id,
        references(:esc_cost_standard,
          column: :esc_id,
          name: "esm_cost_standard_line_esm_standard_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(:esm_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:esm_org_id, :uuid, null: false)
      add(:esm_inserted_at, :utc_datetime, null: false)
      add(:esm_updated_at, :utc_datetime, null: false)
    end

    create(index(:esm_cost_standard_line, [:esm_org_id]))
    create(index(:esm_cost_standard_line, [:esm_standard_id]))

    create(
      unique_index(
        :esm_cost_standard_line,
        [:esm_org_id, :esm_standard_id, :esm_element, :esm_item_id], name: :esm_line_unique)
    )

    create(
      unique_index(
        :esm_cost_standard_line,
        [:esm_org_id, :esm_standard_id, :esm_element],
        name: :esm_line_no_item_unique,
        where: "esm_item_id IS NULL"
      )
    )

    create(
      constraint(:esm_cost_standard_line, :esm_element_valid,
        check: "esm_element IN ('material','labor','overhead')"
      )
    )

    create(
      constraint(:esm_cost_standard_line, :esm_usage_basis_valid,
        check: "esm_usage_basis IN ('yield','bom','none')"
      )
    )

    create(
      constraint(:esm_cost_standard_line, :esm_amounts_valid,
        check: "esm_standard_qty > 0 AND esm_standard_unit_price_cents >= 0"
      )
    )

    create(
      constraint(:esm_cost_standard_line, :esm_yield_valid,
        check: "esm_expected_yield_bp > 0 AND esm_expected_yield_bp <= 10000"
      )
    )

    create(
      constraint(:esm_cost_standard_line, :esm_shape_valid,
        check: """
        (esm_element = 'material' AND esm_item_id IS NOT NULL) OR
        (esm_element IN ('labor','overhead') AND esm_item_id IS NULL)
        """
      )
    )

    create(
      constraint(:esm_cost_standard_line, :esm_usage_valid,
        check: """
        (esm_element IN ('labor','overhead') AND esm_usage_basis = 'none') OR
        (esm_element = 'material')
        """
      )
    )

    create(
      constraint(:esm_cost_standard_line, :esm_bom_yield_valid,
        check: "esm_usage_basis <> 'bom' OR esm_expected_yield_bp = 10000"
      )
    )

    create table(:esv_cost_variance, primary_key: false) do
      add(:esv_period_key, :text, null: false)
      add(:esv_type, :text, null: false)
      add(:esv_amount_cents, :bigint, null: false)
      add(:esv_actual_amount_cents, :bigint, null: false)
      add(:esv_standard_amount_cents, :bigint, null: false)
      add(:esv_disposition, :text)
      add(:esv_inputs, :map, null: false)
      add(:esv_posted_at, :utc_datetime)

      add(
        :esv_variance_account_id,
        references(:eca_account,
          column: :eca_id,
          name: "esv_cost_variance_esv_variance_account_id_fkey",
          type: :uuid
        )
      )

      add(
        :esv_disposition_account_id,
        references(:eca_account,
          column: :eca_id,
          name: "esv_cost_variance_esv_disposition_account_id_fkey",
          type: :uuid
        )
      )

      add(
        :esv_entry_id,
        references(:ecj_journal_entry,
          column: :ecj_id,
          name: "esv_cost_variance_esv_entry_id_fkey",
          type: :uuid
        )
      )

      add(
        :esv_standard_id,
        references(:esc_cost_standard,
          column: :esc_id,
          name: "esv_cost_variance_esv_standard_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(
        :esv_cost_object_id,
        references(:eco_cost_object,
          column: :eco_id,
          name: "esv_cost_variance_esv_cost_object_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(:esv_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:esv_org_id, :uuid, null: false)
      add(:esv_inserted_at, :utc_datetime, null: false)
      add(:esv_updated_at, :utc_datetime, null: false)
    end

    create(index(:esv_cost_variance, [:esv_org_id]))
    create(index(:esv_cost_variance, [:esv_cost_object_id]))
    create(index(:esv_cost_variance, [:esv_period_key]))
    create(index(:esv_cost_variance, [:esv_standard_id]))
    create(index(:esv_cost_variance, [:esv_entry_id]))

    create(
      unique_index(
        :esv_cost_variance,
        [:esv_org_id, :esv_cost_object_id, :esv_period_key, :esv_type],
        name: :esv_variance_unique
      )
    )

    create(
      constraint(:esv_cost_variance, :esv_type_valid,
        check:
          "esv_type IN ('ppv','yield','bom','labor_rate','labor_efficiency','overhead_spending','overhead_volume')"
      )
    )

    create(
      constraint(:esv_cost_variance, :esv_disposition_valid,
        check:
          "esv_disposition IS NULL OR esv_disposition IN ('absorb_inventory','write_off_cogs','write_off_rd')"
      )
    )

    create(
      constraint(:esv_cost_variance, :esv_amount_ties,
        check: "esv_amount_cents = esv_actual_amount_cents - esv_standard_amount_cents"
      )
    )

    create(
      constraint(:esv_cost_variance, :esv_period_valid,
        check: "esv_period_key ~ '^[0-9]{4}-(0[1-9]|1[0-2])$'"
      )
    )

    execute(
      """
      CREATE FUNCTION esv_cost_variance_append_only() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        RAISE EXCEPTION 'esv_cost_variance: % is refused — a variance is an append-only fact; '
          'a correction is a reversing entry, never a rewrite. Variance id: %', TG_OP, OLD.esv_id;
      END;
      $$;
      """,
      "DROP FUNCTION IF EXISTS esv_cost_variance_append_only()"
    )

    execute(
      """
      CREATE TRIGGER esv_cost_variance_append_only_tg
      BEFORE UPDATE OR DELETE ON esv_cost_variance
      FOR EACH ROW EXECUTE FUNCTION esv_cost_variance_append_only()
      """,
      "DROP TRIGGER IF EXISTS esv_cost_variance_append_only_tg ON esv_cost_variance"
    )

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    execute("DROP TRIGGER IF EXISTS esv_cost_variance_append_only_tg ON esv_cost_variance")

    execute("DROP FUNCTION IF EXISTS esv_cost_variance_append_only()")

    drop(table(:esv_cost_variance))
    drop(table(:esm_cost_standard_line))
    drop(table(:esc_cost_standard))
  end
end
