defmodule Samenerp.Repo.Migrations.AddFinanceAssets do
  @moduledoc """
  WS-ACCT Phase 8 (ADR-054 D9) — the asset register on the Kubeworkz books
  (`Samenerp.Erp`, asset `eas`, posting `ead`). Same shape and belts as the
  other hosts:

    * `eas_asset` — the PDK licence and the lab equipment are ROWS here, with
      their cost, acquisition date, life and salvage; the 36-month schedule is
      derived, never stored;
    * `ead_asset_posting` — one period's slice, naming the expense/contra
      accounts it paid (7000/1510 for the licence, 6030/1520 for the equipment)
      and anchored to its entry, append-only (UPDATE/DELETE refused), with
      `ead_period_unique` on `{org, asset, period}` as the exactly-once anchor.

  Catalog rows via `catalog_sync/1` in the same transaction (ADR-004); the
  committed `schema.dict.json` is regenerated in the same change.
  """

  use Samen.Migration

  @resources [
    Samenerp.Erp.Asset,
    Samenerp.Erp.AssetPosting
  ]

  def up do
    create table(:eas_asset, primary_key: false) do
      add(:eas_code, :text, null: false)
      add(:eas_name, :text, null: false)
      add(:eas_memo, :text)
      add(:eas_kind, :text, null: false)
      add(:eas_cost_cents, :bigint, null: false)
      add(:eas_acquired_on, :date, null: false)
      add(:eas_method, :text, null: false, default: "straight_line")
      add(:eas_life_months, :integer, null: false)
      add(:eas_salvage_cents, :bigint, null: false, default: 0)
      add(:eas_status, :text, null: false, default: "active")
      add(:eas_disposed_on, :date)
      add(:eas_dimension_key, :text, null: false, default: "project")

      add(
        :eas_cost_object_id,
        references(:eco_cost_object,
          column: :eco_id,
          name: "eas_asset_eas_cost_object_id_fkey",
          type: :uuid
        )
      )

      add(:eas_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:eas_org_id, :uuid, null: false)
      add(:eas_inserted_at, :utc_datetime, null: false)
      add(:eas_updated_at, :utc_datetime, null: false)
    end

    create(index(:eas_asset, [:eas_org_id]))
    create(index(:eas_asset, [:eas_cost_object_id]))

    create(unique_index(:eas_asset, [:eas_org_id, :eas_code], name: :eas_code_unique))

    create(
      constraint(:eas_asset, :eas_kind_valid, check: "eas_kind IN ('intangible','equipment')")
    )

    create(constraint(:eas_asset, :eas_method_valid, check: "eas_method IN ('straight_line')"))

    create(
      constraint(:eas_asset, :eas_status_valid, check: "eas_status IN ('active','disposed')")
    )

    create(
      constraint(:eas_asset, :eas_dimension_key_valid,
        check: "eas_dimension_key IN ('project','lot','fund','cost_pool')"
      )
    )

    create(
      constraint(:eas_asset, :eas_amounts_valid,
        check:
          "eas_cost_cents > 0 AND eas_life_months > 0 AND eas_salvage_cents >= 0 " <>
            "AND eas_cost_cents - eas_salvage_cents >= eas_life_months"
      )
    )

    create(
      constraint(:eas_asset, :eas_disposal_valid,
        check: """
        ((eas_status = 'disposed' AND eas_disposed_on IS NOT NULL) OR
         (eas_status = 'active' AND eas_disposed_on IS NULL)) AND
        (eas_disposed_on IS NULL OR eas_disposed_on >= eas_acquired_on)
        """
      )
    )

    create table(:ead_asset_posting, primary_key: false) do
      add(:ead_period_key, :text, null: false)
      add(:ead_amount_cents, :bigint, null: false)
      add(:ead_depreciated_on, :date, null: false)

      add(
        :ead_expense_account_id,
        references(:eca_account,
          column: :eca_id,
          name: "ead_asset_posting_ead_expense_account_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(
        :ead_contra_account_id,
        references(:eca_account,
          column: :eca_id,
          name: "ead_asset_posting_ead_contra_account_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(
        :ead_asset_id,
        references(:eas_asset,
          column: :eas_id,
          name: "ead_asset_posting_ead_asset_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(:ead_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:ead_org_id, :uuid, null: false)
      add(:ead_inserted_at, :utc_datetime, null: false)
      add(:ead_updated_at, :utc_datetime, null: false)
    end

    create(index(:ead_asset_posting, [:ead_org_id]))
    create(index(:ead_asset_posting, [:ead_asset_id]))
    create(index(:ead_asset_posting, [:ead_period_key]))

    create(
      unique_index(:ead_asset_posting, [:ead_org_id, :ead_asset_id, :ead_period_key],
        name: :ead_period_unique
      )
    )

    create(constraint(:ead_asset_posting, :ead_amount_positive, check: "ead_amount_cents > 0"))

    create(
      constraint(:ead_asset_posting, :ead_period_valid,
        check: "ead_period_key ~ '^[0-9]{4}-(0[1-9]|1[0-2])$'"
      )
    )

    execute(
      """
      CREATE FUNCTION ead_asset_posting_append_only() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        RAISE EXCEPTION 'ead_asset_posting: % is refused — a depreciation slice is an '
          'append-only fact; a correction is a reversing entry, never a rewrite. '
          'Posting id: %', TG_OP, OLD.ead_id;
      END;
      $$;
      """,
      "DROP FUNCTION IF EXISTS ead_asset_posting_append_only()"
    )

    execute(
      """
      CREATE TRIGGER ead_asset_posting_append_only_tg
      BEFORE UPDATE OR DELETE ON ead_asset_posting
      FOR EACH ROW EXECUTE FUNCTION ead_asset_posting_append_only()
      """,
      "DROP TRIGGER IF EXISTS ead_asset_posting_append_only_tg ON ead_asset_posting"
    )

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    execute("DROP TRIGGER IF EXISTS ead_asset_posting_append_only_tg ON ead_asset_posting")

    execute("DROP FUNCTION IF EXISTS ead_asset_posting_append_only()")

    drop(table(:ead_asset_posting))
    drop(table(:eas_asset))
  end
end
