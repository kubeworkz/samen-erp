defmodule Samen.WebTest.Repo.Migrations.AddFinanceAssets do
  @moduledoc """
  WS-ACCT Phase 8 (ADR-054 D9) — the asset register on the `samen_web` test host
  (`Samen.WebTest.Erp`, asset `fas`, posting `fad`). Same shape and belts as the
  `samen_core` fixture leg:

    * `fas_asset` — one intangible/equipment contract; the schedule stays
      derived (`life_months` from `acquired_on`), never a table;
    * `fad_asset_posting` — one period's slice, naming the two accounts it paid
      and anchored to its entry, append-only (UPDATE/DELETE refused), with
      `fad_period_unique` on `{org, asset, period}` as the exactly-once anchor.

  Catalog rows via `catalog_sync/1` in the same transaction (ADR-004).
  """

  use Samen.Migration

  @resources [
    Samen.WebTest.Erp.Asset,
    Samen.WebTest.Erp.AssetPosting
  ]

  def up do
    create table(:fas_asset, primary_key: false) do
      add(:fas_code, :text, null: false)
      add(:fas_name, :text, null: false)
      add(:fas_memo, :text)
      add(:fas_kind, :text, null: false)
      add(:fas_cost_cents, :bigint, null: false)
      add(:fas_acquired_on, :date, null: false)
      add(:fas_method, :text, null: false, default: "straight_line")
      add(:fas_life_months, :integer, null: false)
      add(:fas_salvage_cents, :bigint, null: false, default: 0)
      add(:fas_status, :text, null: false, default: "active")
      add(:fas_disposed_on, :date)
      add(:fas_dimension_key, :text, null: false, default: "project")

      add(
        :fas_cost_object_id,
        references(:fco_cost_object,
          column: :fco_id,
          name: "fas_asset_fas_cost_object_id_fkey",
          type: :uuid
        )
      )

      add(:fas_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:fas_org_id, :uuid, null: false)
      add(:fas_inserted_at, :utc_datetime, null: false)
      add(:fas_updated_at, :utc_datetime, null: false)
    end

    create(index(:fas_asset, [:fas_org_id]))
    create(index(:fas_asset, [:fas_cost_object_id]))

    create(unique_index(:fas_asset, [:fas_org_id, :fas_code], name: :fas_code_unique))

    create(
      constraint(:fas_asset, :fas_kind_valid, check: "fas_kind IN ('intangible','equipment')")
    )

    create(constraint(:fas_asset, :fas_method_valid, check: "fas_method IN ('straight_line')"))

    create(
      constraint(:fas_asset, :fas_status_valid, check: "fas_status IN ('active','disposed')")
    )

    create(
      constraint(:fas_asset, :fas_dimension_key_valid,
        check: "fas_dimension_key IN ('project','lot','fund','cost_pool')"
      )
    )

    create(
      constraint(:fas_asset, :fas_amounts_valid,
        check:
          "fas_cost_cents > 0 AND fas_life_months > 0 AND fas_salvage_cents >= 0 " <>
            "AND fas_cost_cents - fas_salvage_cents >= fas_life_months"
      )
    )

    create(
      constraint(:fas_asset, :fas_disposal_valid,
        check: """
        ((fas_status = 'disposed' AND fas_disposed_on IS NOT NULL) OR
         (fas_status = 'active' AND fas_disposed_on IS NULL)) AND
        (fas_disposed_on IS NULL OR fas_disposed_on >= fas_acquired_on)
        """
      )
    )

    create table(:fad_asset_posting, primary_key: false) do
      add(:fad_period_key, :text, null: false)
      add(:fad_amount_cents, :bigint, null: false)
      add(:fad_depreciated_on, :date, null: false)

      add(
        :fad_expense_account_id,
        references(:fca_account,
          column: :fca_id,
          name: "fad_asset_posting_fad_expense_account_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(
        :fad_contra_account_id,
        references(:fca_account,
          column: :fca_id,
          name: "fad_asset_posting_fad_contra_account_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(
        :fad_asset_id,
        references(:fas_asset,
          column: :fas_id,
          name: "fad_asset_posting_fad_asset_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(:fad_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:fad_org_id, :uuid, null: false)
      add(:fad_inserted_at, :utc_datetime, null: false)
      add(:fad_updated_at, :utc_datetime, null: false)
    end

    create(index(:fad_asset_posting, [:fad_org_id]))
    create(index(:fad_asset_posting, [:fad_asset_id]))
    create(index(:fad_asset_posting, [:fad_period_key]))

    create(
      unique_index(:fad_asset_posting, [:fad_org_id, :fad_asset_id, :fad_period_key],
        name: :fad_period_unique
      )
    )

    create(constraint(:fad_asset_posting, :fad_amount_positive, check: "fad_amount_cents > 0"))

    create(
      constraint(:fad_asset_posting, :fad_period_valid,
        check: "fad_period_key ~ '^[0-9]{4}-(0[1-9]|1[0-2])$'"
      )
    )

    execute(
      """
      CREATE FUNCTION fad_asset_posting_append_only() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        RAISE EXCEPTION 'fad_asset_posting: % is refused — a depreciation slice is an '
          'append-only fact; a correction is a reversing entry, never a rewrite. '
          'Posting id: %', TG_OP, OLD.fad_id;
      END;
      $$;
      """,
      "DROP FUNCTION IF EXISTS fad_asset_posting_append_only()"
    )

    execute(
      """
      CREATE TRIGGER fad_asset_posting_append_only_tg
      BEFORE UPDATE OR DELETE ON fad_asset_posting
      FOR EACH ROW EXECUTE FUNCTION fad_asset_posting_append_only()
      """,
      "DROP TRIGGER IF EXISTS fad_asset_posting_append_only_tg ON fad_asset_posting"
    )

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    execute("DROP TRIGGER IF EXISTS fad_asset_posting_append_only_tg ON fad_asset_posting")

    execute("DROP FUNCTION IF EXISTS fad_asset_posting_append_only()")

    drop(table(:fad_asset_posting))
    drop(table(:fas_asset))
  end
end
