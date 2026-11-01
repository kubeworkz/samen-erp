defmodule SamenCore.TestRepo.Migrations.AddFinanceCostStandards do
  @moduledoc """
  WS-ACCT Phase 7 (ADR-054 D4) — standard costing and its variance layer in the
  `samen_core` test fixture (`SamenCore.Support.FinanceFixture`, card `fsx`,
  line `fsy`, variance `fsv`):

    * `fsx_cost_standard` — one output item's effective-dated standard for a
      cost object, plus the dimension axis its variance entries use;
    * `fsy_cost_standard_line` — one element's standard qty/price/yield;
    * `fsv_cost_variance` — one posted variance fact, naming the variance and
      disposition accounts it landed on, the card it was priced from and the
      exact inputs it was computed from.

  DB belts (over the Ash-side braces):

    * `fsx_card_period_unique` — one card governs a cost object per effective
      date, so "the card in force" is never ambiguous;
    * `fsy_line_unique` + `fsy_line_no_item_unique` — no duplicate element on a
      card (the second covers the NULL-item labour/overhead lines, which a plain
      unique index would let through);
    * `fsy_*` shape checks — material names its item, labour/overhead carry
      none, labour/overhead are usage-basis `none`, and a BOM line is 100 %
      yield;
    * `fsv_variance_unique` — exactly-once per `{cost object, period, type}`;
    * `fsv_amount_ties` — the stored variance IS actual − standard, below Ash;
    * `fsv_period_valid` / `fsv_type_valid` / `fsv_disposition_valid` — the
      shapes at the DB layer;
    * `fsv_cost_variance_append_only` — UPDATE and DELETE refused outright; a
      wrong variance is corrected with a reversing entry, never rewritten.

  Catalog rows via `catalog_sync/1` in the same transaction (ADR-004).
  """

  use Samen.Migration

  @resources [
    SamenCore.Support.FinanceFixture.CostStandard,
    SamenCore.Support.FinanceFixture.CostStandardLine,
    SamenCore.Support.FinanceFixture.CostVariance
  ]

  def up do
    create table(:fsx_cost_standard, primary_key: false) do
      add(:fsx_code, :text, null: false)
      add(:fsx_output_item_id, :uuid)
      add(:fsx_effective_on, :date, null: false)
      add(:fsx_memo, :text)
      add(:fsx_dimension_key, :text, null: false, default: "project")

      add(
        :fsx_cost_object_id,
        references(:cob_cost_object,
          column: :cob_id,
          name: "fsx_cost_standard_fsx_cost_object_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(:fsx_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:fsx_org_id, :uuid, null: false)
      add(:fsx_inserted_at, :utc_datetime, null: false)
      add(:fsx_updated_at, :utc_datetime, null: false)
    end

    create(index(:fsx_cost_standard, [:fsx_org_id]))
    create(index(:fsx_cost_standard, [:fsx_cost_object_id]))

    create(
      unique_index(:fsx_cost_standard, [:fsx_org_id, :fsx_cost_object_id, :fsx_effective_on],
        name: :fsx_card_period_unique
      )
    )

    create(
      constraint(:fsx_cost_standard, :fsx_dimension_key_valid,
        check: "fsx_dimension_key IN ('project','lot','fund','cost_pool')"
      )
    )

    create table(:fsy_cost_standard_line, primary_key: false) do
      add(:fsy_element, :text, null: false)
      add(:fsy_item_id, :uuid)
      add(:fsy_standard_qty, :bigint, null: false)
      add(:fsy_standard_unit_price_cents, :bigint, null: false)
      add(:fsy_expected_yield_bp, :integer, null: false, default: 10_000)
      add(:fsy_usage_basis, :text, null: false, default: "yield")

      add(
        :fsy_standard_id,
        references(:fsx_cost_standard,
          column: :fsx_id,
          name: "fsy_cost_standard_line_fsy_standard_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(:fsy_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:fsy_org_id, :uuid, null: false)
      add(:fsy_inserted_at, :utc_datetime, null: false)
      add(:fsy_updated_at, :utc_datetime, null: false)
    end

    create(index(:fsy_cost_standard_line, [:fsy_org_id]))
    create(index(:fsy_cost_standard_line, [:fsy_standard_id]))

    create(
      unique_index(
        :fsy_cost_standard_line,
        [:fsy_org_id, :fsy_standard_id, :fsy_element, :fsy_item_id], name: :fsy_line_unique)
    )

    create(
      unique_index(
        :fsy_cost_standard_line,
        [:fsy_org_id, :fsy_standard_id, :fsy_element],
        name: :fsy_line_no_item_unique,
        where: "fsy_item_id IS NULL"
      )
    )

    create(
      constraint(:fsy_cost_standard_line, :fsy_element_valid,
        check: "fsy_element IN ('material','labor','overhead')"
      )
    )

    create(
      constraint(:fsy_cost_standard_line, :fsy_usage_basis_valid,
        check: "fsy_usage_basis IN ('yield','bom','none')"
      )
    )

    create(
      constraint(:fsy_cost_standard_line, :fsy_amounts_valid,
        check: "fsy_standard_qty > 0 AND fsy_standard_unit_price_cents >= 0"
      )
    )

    create(
      constraint(:fsy_cost_standard_line, :fsy_yield_valid,
        check: "fsy_expected_yield_bp > 0 AND fsy_expected_yield_bp <= 10000"
      )
    )

    create(
      constraint(:fsy_cost_standard_line, :fsy_shape_valid,
        check: """
        (fsy_element = 'material' AND fsy_item_id IS NOT NULL) OR
        (fsy_element IN ('labor','overhead') AND fsy_item_id IS NULL)
        """
      )
    )

    create(
      constraint(:fsy_cost_standard_line, :fsy_usage_valid,
        check: """
        (fsy_element IN ('labor','overhead') AND fsy_usage_basis = 'none') OR
        (fsy_element = 'material')
        """
      )
    )

    create(
      constraint(:fsy_cost_standard_line, :fsy_bom_yield_valid,
        check: "fsy_usage_basis <> 'bom' OR fsy_expected_yield_bp = 10000"
      )
    )

    create table(:fsv_cost_variance, primary_key: false) do
      add(:fsv_period_key, :text, null: false)
      add(:fsv_type, :text, null: false)
      add(:fsv_amount_cents, :bigint, null: false)
      add(:fsv_actual_amount_cents, :bigint, null: false)
      add(:fsv_standard_amount_cents, :bigint, null: false)
      add(:fsv_disposition, :text)
      add(:fsv_inputs, :map, null: false)
      add(:fsv_posted_at, :utc_datetime)

      add(
        :fsv_variance_account_id,
        references(:sac_account,
          column: :sac_id,
          name: "fsv_cost_variance_fsv_variance_account_id_fkey",
          type: :uuid
        )
      )

      add(
        :fsv_disposition_account_id,
        references(:sac_account,
          column: :sac_id,
          name: "fsv_cost_variance_fsv_disposition_account_id_fkey",
          type: :uuid
        )
      )

      add(
        :fsv_entry_id,
        references(:sje_journal_entry,
          column: :sje_id,
          name: "fsv_cost_variance_fsv_entry_id_fkey",
          type: :uuid
        )
      )

      add(
        :fsv_standard_id,
        references(:fsx_cost_standard,
          column: :fsx_id,
          name: "fsv_cost_variance_fsv_standard_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(
        :fsv_cost_object_id,
        references(:cob_cost_object,
          column: :cob_id,
          name: "fsv_cost_variance_fsv_cost_object_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(:fsv_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:fsv_org_id, :uuid, null: false)
      add(:fsv_inserted_at, :utc_datetime, null: false)
      add(:fsv_updated_at, :utc_datetime, null: false)
    end

    create(index(:fsv_cost_variance, [:fsv_org_id]))
    create(index(:fsv_cost_variance, [:fsv_cost_object_id]))
    create(index(:fsv_cost_variance, [:fsv_period_key]))
    create(index(:fsv_cost_variance, [:fsv_standard_id]))
    create(index(:fsv_cost_variance, [:fsv_entry_id]))

    create(
      unique_index(
        :fsv_cost_variance,
        [:fsv_org_id, :fsv_cost_object_id, :fsv_period_key, :fsv_type],
        name: :fsv_variance_unique
      )
    )

    create(
      constraint(:fsv_cost_variance, :fsv_type_valid,
        check:
          "fsv_type IN ('ppv','yield','bom','labor_rate','labor_efficiency','overhead_spending','overhead_volume')"
      )
    )

    create(
      constraint(:fsv_cost_variance, :fsv_disposition_valid,
        check:
          "fsv_disposition IS NULL OR fsv_disposition IN ('absorb_inventory','write_off_cogs','write_off_rd')"
      )
    )

    create(
      constraint(:fsv_cost_variance, :fsv_amount_ties,
        check: "fsv_amount_cents = fsv_actual_amount_cents - fsv_standard_amount_cents"
      )
    )

    create(
      constraint(:fsv_cost_variance, :fsv_period_valid,
        check: "fsv_period_key ~ '^[0-9]{4}-(0[1-9]|1[0-2])$'"
      )
    )

    execute(
      """
      CREATE FUNCTION fsv_cost_variance_append_only() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        RAISE EXCEPTION 'fsv_cost_variance: % is refused — a variance is an append-only fact; '
          'a correction is a reversing entry, never a rewrite. Variance id: %', TG_OP, OLD.fsv_id;
      END;
      $$;
      """,
      "DROP FUNCTION IF EXISTS fsv_cost_variance_append_only()"
    )

    execute(
      """
      CREATE TRIGGER fsv_cost_variance_append_only_tg
      BEFORE UPDATE OR DELETE ON fsv_cost_variance
      FOR EACH ROW EXECUTE FUNCTION fsv_cost_variance_append_only()
      """,
      "DROP TRIGGER IF EXISTS fsv_cost_variance_append_only_tg ON fsv_cost_variance"
    )

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    execute("DROP TRIGGER IF EXISTS fsv_cost_variance_append_only_tg ON fsv_cost_variance")

    execute("DROP FUNCTION IF EXISTS fsv_cost_variance_append_only()")

    drop(table(:fsv_cost_variance))
    drop(table(:fsy_cost_standard_line))
    drop(table(:fsx_cost_standard))
  end
end
