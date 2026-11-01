defmodule SamenCore.TestRepo.Migrations.AddFinanceAssets do
  @moduledoc """
  WS-ACCT Phase 8 (ADR-054 D9) — the asset register in the `samen_core` test
  fixture (`SamenCore.Support.FinanceFixture`, asset `fsf`, posting `fsp`):

    * `fsf_asset` — one capitalized intangible or piece of equipment and the
      contract that amortizes it. There is NO schedule table: the term is
      `life_months` from `acquired_on`, derived at read time.
    * `fsp_asset_posting` — one period's posted slice, naming the expense and
      contra accounts it paid and anchored to its entry
      (`source_key = 'asset_posting'`, `source_id = <this row>`). Append-only:
      the trigger refuses UPDATE and DELETE outright.

  DB belts (over the Ash-side braces):

    * `fsf_code_unique` — one code per org, like a CoA code;
    * `fsf_amounts_valid` — positive cost/life, non-negative salvage, and
      `cost − salvage >= life` (at least one cent per month);
    * `fsf_disposal_valid` — `disposed` iff dated, and never before acquisition;
    * `fsf_kind_valid` / `fsf_method_valid` / `fsf_status_valid` /
      `fsf_dimension_key_valid` — the closed enums at the DB layer;
    * `fsp_period_unique` — UNIQUE on `{org, asset, period}`: one period
      amortizes once, even if two runs race (the exactly-once anchor);
    * `fsp_amount_positive` / `fsp_period_valid` — the slice shape.

  Catalog rows via `catalog_sync/1` in the same transaction (ADR-004).
  """

  use Samen.Migration

  @resources [
    SamenCore.Support.FinanceFixture.Asset,
    SamenCore.Support.FinanceFixture.AssetPosting
  ]

  def up do
    create table(:fsf_asset, primary_key: false) do
      add(:fsf_code, :text, null: false)
      add(:fsf_name, :text, null: false)
      add(:fsf_memo, :text)
      add(:fsf_kind, :text, null: false)
      add(:fsf_cost_cents, :bigint, null: false)
      add(:fsf_acquired_on, :date, null: false)
      add(:fsf_method, :text, null: false, default: "straight_line")
      add(:fsf_life_months, :integer, null: false)
      add(:fsf_salvage_cents, :bigint, null: false, default: 0)
      add(:fsf_status, :text, null: false, default: "active")
      add(:fsf_disposed_on, :date)
      add(:fsf_dimension_key, :text, null: false, default: "project")

      add(
        :fsf_cost_object_id,
        references(:cob_cost_object,
          column: :cob_id,
          name: "fsf_asset_fsf_cost_object_id_fkey",
          type: :uuid
        )
      )

      add(:fsf_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:fsf_org_id, :uuid, null: false)
      add(:fsf_inserted_at, :utc_datetime, null: false)
      add(:fsf_updated_at, :utc_datetime, null: false)
    end

    create(index(:fsf_asset, [:fsf_org_id]))
    create(index(:fsf_asset, [:fsf_cost_object_id]))

    create(unique_index(:fsf_asset, [:fsf_org_id, :fsf_code], name: :fsf_code_unique))

    create(
      constraint(:fsf_asset, :fsf_kind_valid, check: "fsf_kind IN ('intangible','equipment')")
    )

    create(constraint(:fsf_asset, :fsf_method_valid, check: "fsf_method IN ('straight_line')"))

    create(
      constraint(:fsf_asset, :fsf_status_valid, check: "fsf_status IN ('active','disposed')")
    )

    create(
      constraint(:fsf_asset, :fsf_dimension_key_valid,
        check: "fsf_dimension_key IN ('project','lot','fund','cost_pool')"
      )
    )

    create(
      constraint(:fsf_asset, :fsf_amounts_valid,
        check:
          "fsf_cost_cents > 0 AND fsf_life_months > 0 AND fsf_salvage_cents >= 0 " <>
            "AND fsf_cost_cents - fsf_salvage_cents >= fsf_life_months"
      )
    )

    create(
      constraint(:fsf_asset, :fsf_disposal_valid,
        check: """
        ((fsf_status = 'disposed' AND fsf_disposed_on IS NOT NULL) OR
         (fsf_status = 'active' AND fsf_disposed_on IS NULL)) AND
        (fsf_disposed_on IS NULL OR fsf_disposed_on >= fsf_acquired_on)
        """
      )
    )

    create table(:fsp_asset_posting, primary_key: false) do
      add(:fsp_period_key, :text, null: false)
      add(:fsp_amount_cents, :bigint, null: false)
      add(:fsp_depreciated_on, :date, null: false)

      add(
        :fsp_expense_account_id,
        references(:sac_account,
          column: :sac_id,
          name: "fsp_asset_posting_fsp_expense_account_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(
        :fsp_contra_account_id,
        references(:sac_account,
          column: :sac_id,
          name: "fsp_asset_posting_fsp_contra_account_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(
        :fsp_asset_id,
        references(:fsf_asset,
          column: :fsf_id,
          name: "fsp_asset_posting_fsp_asset_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(:fsp_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:fsp_org_id, :uuid, null: false)
      add(:fsp_inserted_at, :utc_datetime, null: false)
      add(:fsp_updated_at, :utc_datetime, null: false)
    end

    create(index(:fsp_asset_posting, [:fsp_org_id]))
    create(index(:fsp_asset_posting, [:fsp_asset_id]))
    create(index(:fsp_asset_posting, [:fsp_period_key]))

    # The exactly-once anchor: one period amortizes once.
    create(
      unique_index(:fsp_asset_posting, [:fsp_org_id, :fsp_asset_id, :fsp_period_key],
        name: :fsp_period_unique
      )
    )

    create(constraint(:fsp_asset_posting, :fsp_amount_positive, check: "fsp_amount_cents > 0"))

    create(
      constraint(:fsp_asset_posting, :fsp_period_valid,
        check: "fsp_period_key ~ '^[0-9]{4}-(0[1-9]|1[0-2])$'"
      )
    )

    execute(
      """
      CREATE FUNCTION fsp_asset_posting_append_only() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        RAISE EXCEPTION 'fsp_asset_posting: % is refused — a depreciation slice is an '
          'append-only fact; a correction is a reversing entry, never a rewrite. '
          'Posting id: %', TG_OP, OLD.fsp_id;
      END;
      $$;
      """,
      "DROP FUNCTION IF EXISTS fsp_asset_posting_append_only()"
    )

    execute(
      """
      CREATE TRIGGER fsp_asset_posting_append_only_tg
      BEFORE UPDATE OR DELETE ON fsp_asset_posting
      FOR EACH ROW EXECUTE FUNCTION fsp_asset_posting_append_only()
      """,
      "DROP TRIGGER IF EXISTS fsp_asset_posting_append_only_tg ON fsp_asset_posting"
    )

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    execute("DROP TRIGGER IF EXISTS fsp_asset_posting_append_only_tg ON fsp_asset_posting")

    execute("DROP FUNCTION IF EXISTS fsp_asset_posting_append_only()")

    drop(table(:fsp_asset_posting))
    drop(table(:fsf_asset))
  end
end
