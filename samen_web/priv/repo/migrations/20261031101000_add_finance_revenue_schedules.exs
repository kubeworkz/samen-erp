defmodule Samen.WebTest.Repo.Migrations.AddFinanceRevenueSchedules do
  @moduledoc """
  WS-ACCT Phase 6 (ADR-054 D5) — deferred revenue and its recognition schedules
  on the `samen_web` test host (`Samen.WebTest.Erp`, schedule abbrev `frs`,
  recognition `frn`). Same shape and belts as the `samen_core` fixture leg:

    * `frs_revenue_schedule` — the contract's deferred amount, term, method,
      deferred-account meaning and (for `cost_incurred`) the `fco_cost_object`
      whose incurred cost drives it. `recognized_to_date` stays derived.
    * `frn_revenue_recognition` — one period's released slice, append-only
      (UPDATE/DELETE refused by trigger), with `frn_period_unique` on
      `{org, schedule, period}` as the exactly-once anchor.

  Catalog rows via `catalog_sync/1,2` in the same transaction (ADR-004).
  """

  use Samen.Migration

  @resources [
    Samen.WebTest.Erp.RevenueSchedule,
    Samen.WebTest.Erp.RevenueRecognition
  ]

  def up do
    create table(:frs_revenue_schedule, primary_key: false) do
      add(:frs_source_key, :text)
      add(:frs_source_id, :uuid)
      add(:frs_memo, :text)
      add(:frs_total_cents, :bigint, null: false)
      add(:frs_start_on, :date, null: false)
      add(:frs_months, :integer, null: false)
      add(:frs_method, :text, null: false, default: "straight_line")
      add(:frs_deferred_key, :text, null: false, default: "deferred_revenue")

      add(
        :frs_cost_object_id,
        references(:fco_cost_object,
          column: :fco_id,
          name: "frs_revenue_schedule_frs_cost_object_id_fkey",
          type: :uuid
        )
      )

      add(:frs_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:frs_org_id, :uuid, null: false)
      add(:frs_inserted_at, :utc_datetime, null: false)
      add(:frs_updated_at, :utc_datetime, null: false)
    end

    create(index(:frs_revenue_schedule, [:frs_org_id]))
    create(index(:frs_revenue_schedule, [:frs_cost_object_id]))

    create(
      constraint(:frs_revenue_schedule, :frs_method_valid,
        check: "frs_method IN ('straight_line','cost_incurred')"
      )
    )

    create(
      constraint(:frs_revenue_schedule, :frs_deferred_key_valid,
        check: "frs_deferred_key IN ('deferred_revenue','grant_deferred')"
      )
    )

    create(
      constraint(:frs_revenue_schedule, :frs_amounts_positive,
        check: "frs_total_cents > 0 AND frs_months > 0 AND frs_total_cents >= frs_months"
      )
    )

    create table(:frn_revenue_recognition, primary_key: false) do
      add(:frn_period_key, :text, null: false)
      add(:frn_amount_cents, :bigint, null: false)
      add(:frn_recognized_on, :date, null: false)
      add(:frn_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:frn_org_id, :uuid, null: false)
      add(:frn_inserted_at, :utc_datetime, null: false)
      add(:frn_updated_at, :utc_datetime, null: false)

      add(
        :frn_schedule_id,
        references(:frs_revenue_schedule,
          column: :frs_id,
          name: "frn_revenue_recognition_frn_schedule_id_fkey",
          type: :uuid
        ),
        null: false
      )
    end

    create(index(:frn_revenue_recognition, [:frn_org_id]))
    create(index(:frn_revenue_recognition, [:frn_schedule_id]))

    create(
      unique_index(:frn_revenue_recognition, [:frn_org_id, :frn_schedule_id, :frn_period_key],
        name: :frn_period_unique
      )
    )

    create(
      constraint(:frn_revenue_recognition, :frn_amount_positive, check: "frn_amount_cents > 0")
    )

    execute(
      """
      CREATE FUNCTION frn_revenue_recognition_append_only() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        RAISE EXCEPTION 'frn_revenue_recognition: % is refused — a recognition is an '
          'append-only fact; a correction is a reversing entry, never a rewrite. '
          'Recognition id: %', TG_OP, OLD.frn_id;
      END;
      $$;
      """,
      "DROP FUNCTION IF EXISTS frn_revenue_recognition_append_only()"
    )

    execute(
      """
      CREATE TRIGGER frn_revenue_recognition_append_only_tg
      BEFORE UPDATE OR DELETE ON frn_revenue_recognition
      FOR EACH ROW EXECUTE FUNCTION frn_revenue_recognition_append_only()
      """,
      "DROP TRIGGER IF EXISTS frn_revenue_recognition_append_only_tg ON frn_revenue_recognition"
    )

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    execute(
      "DROP TRIGGER IF EXISTS frn_revenue_recognition_append_only_tg ON frn_revenue_recognition"
    )

    execute("DROP FUNCTION IF EXISTS frn_revenue_recognition_append_only()")

    drop(table(:frn_revenue_recognition))
    drop(table(:frs_revenue_schedule))
  end
end
