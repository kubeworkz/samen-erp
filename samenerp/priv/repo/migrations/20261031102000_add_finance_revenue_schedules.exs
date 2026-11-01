defmodule Samenerp.Repo.Migrations.AddFinanceRevenueSchedules do
  @moduledoc """
  WS-ACCT Phase 6 (ADR-054 D5) — deferred revenue and its recognition schedules
  on the Kubeworkz books (`Samenerp.Erp`, schedule abbrev `esd`, recognition
  `esg`). Same shape and belts as the other hosts:

    * `esd_revenue_schedule` — the contract's deferred amount, term, method,
      deferred-account meaning (`deferred_revenue` for customer contracts,
      `grant_deferred` for award revenue) and (for `cost_incurred`) the
      `eco_cost_object` whose incurred cost drives the release.
      `recognized_to_date` stays derived (Σ recognitions), never a column.
    * `esg_revenue_recognition` — one period's released slice, append-only
      (UPDATE/DELETE refused by trigger), with `esg_period_unique` on
      `{org, schedule, period}` as the exactly-once anchor.

  Catalog rows via `catalog_sync/1` in the same transaction (ADR-004); the
  committed `schema.dict.json` is regenerated in the same change.
  """

  use Samen.Migration

  @resources [
    Samenerp.Erp.RevenueSchedule,
    Samenerp.Erp.RevenueRecognition
  ]

  def up do
    create table(:esd_revenue_schedule, primary_key: false) do
      add(:esd_source_key, :text)
      add(:esd_source_id, :uuid)
      add(:esd_memo, :text)
      add(:esd_total_cents, :bigint, null: false)
      add(:esd_start_on, :date, null: false)
      add(:esd_months, :integer, null: false)
      add(:esd_method, :text, null: false, default: "straight_line")
      add(:esd_deferred_key, :text, null: false, default: "deferred_revenue")

      add(
        :esd_cost_object_id,
        references(:eco_cost_object,
          column: :eco_id,
          name: "esd_revenue_schedule_esd_cost_object_id_fkey",
          type: :uuid
        )
      )

      add(:esd_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:esd_org_id, :uuid, null: false)
      add(:esd_inserted_at, :utc_datetime, null: false)
      add(:esd_updated_at, :utc_datetime, null: false)
    end

    create(index(:esd_revenue_schedule, [:esd_org_id]))
    create(index(:esd_revenue_schedule, [:esd_cost_object_id]))

    create(
      constraint(:esd_revenue_schedule, :esd_method_valid,
        check: "esd_method IN ('straight_line','cost_incurred')"
      )
    )

    create(
      constraint(:esd_revenue_schedule, :esd_deferred_key_valid,
        check: "esd_deferred_key IN ('deferred_revenue','grant_deferred')"
      )
    )

    create(
      constraint(:esd_revenue_schedule, :esd_amounts_positive,
        check: "esd_total_cents > 0 AND esd_months > 0 AND esd_total_cents >= esd_months"
      )
    )

    create table(:esg_revenue_recognition, primary_key: false) do
      add(:esg_period_key, :text, null: false)
      add(:esg_amount_cents, :bigint, null: false)
      add(:esg_recognized_on, :date, null: false)
      add(:esg_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:esg_org_id, :uuid, null: false)
      add(:esg_inserted_at, :utc_datetime, null: false)
      add(:esg_updated_at, :utc_datetime, null: false)

      add(
        :esg_schedule_id,
        references(:esd_revenue_schedule,
          column: :esd_id,
          name: "esg_revenue_recognition_esg_schedule_id_fkey",
          type: :uuid
        ),
        null: false
      )
    end

    create(index(:esg_revenue_recognition, [:esg_org_id]))
    create(index(:esg_revenue_recognition, [:esg_schedule_id]))

    create(
      unique_index(:esg_revenue_recognition, [:esg_org_id, :esg_schedule_id, :esg_period_key],
        name: :esg_period_unique
      )
    )

    create(
      constraint(:esg_revenue_recognition, :esg_amount_positive, check: "esg_amount_cents > 0")
    )

    execute(
      """
      CREATE FUNCTION esg_revenue_recognition_append_only() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        RAISE EXCEPTION 'esg_revenue_recognition: % is refused — a recognition is an '
          'append-only fact; a correction is a reversing entry, never a rewrite. '
          'Recognition id: %', TG_OP, OLD.esg_id;
      END;
      $$;
      """,
      "DROP FUNCTION IF EXISTS esg_revenue_recognition_append_only()"
    )

    execute(
      """
      CREATE TRIGGER esg_revenue_recognition_append_only_tg
      BEFORE UPDATE OR DELETE ON esg_revenue_recognition
      FOR EACH ROW EXECUTE FUNCTION esg_revenue_recognition_append_only()
      """,
      "DROP TRIGGER IF EXISTS esg_revenue_recognition_append_only_tg ON esg_revenue_recognition"
    )

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    execute(
      "DROP TRIGGER IF EXISTS esg_revenue_recognition_append_only_tg ON esg_revenue_recognition"
    )

    execute("DROP FUNCTION IF EXISTS esg_revenue_recognition_append_only()")

    drop(table(:esg_revenue_recognition))
    drop(table(:esd_revenue_schedule))
  end
end
