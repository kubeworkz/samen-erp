defmodule SamenCore.TestRepo.Migrations.AddFinanceRevenueSchedules do
  @moduledoc """
  WS-ACCT Phase 6 (ADR-054 D5) — deferred revenue and its recognition schedules
  in the `samen_core` test fixture (`SamenCore.Support.FinanceFixture`, schedule
  abbrev `fsd`, recognition `frc`):

    * `fsd_revenue_schedule` — one contract's deferred amount, its term and the
      method that releases it (`straight_line` / `cost_incurred`), plus the
      `PostingAccount` meaning that holds the deferred balance and (for
      incurred-cost schedules) the cost object whose incurred cost drives the
      recognition. `recognized_to_date` is NOT a column: it is the Σ of the
      recognitions, read as an aggregate (the design's derived field).
    * `frc_revenue_recognition` — one period's released slice, anchored to the
      journal entry it posted (`source_key = 'revenue_recognition'`,
      `source_id = <this row>`). Append-only: the trigger below refuses UPDATE
      and DELETE outright — a mistake is corrected with a reversing entry, not
      by rewriting the record of what was recognized.

  DB belts (over the Ash-side braces):

    * `frc_period_unique` — UNIQUE on `{org, schedule, period_key}`: one
      period releases once, even if two runs race (the exactly-once anchor).
    * `frc_amount_positive` / `fsd_amounts_positive` — a slice is a positive
      integer, and a straight-line term is at least one cent per period.
    * `fsd_method_valid` / `fsd_deferred_key_valid` — the closed enums at the
      DB layer.

  Catalog rows via `catalog_sync/1` in the same transaction (ADR-004).
  """

  use Samen.Migration

  @resources [
    SamenCore.Support.FinanceFixture.RevenueSchedule,
    SamenCore.Support.FinanceFixture.RevenueRecognition
  ]

  def up do
    create table(:fsd_revenue_schedule, primary_key: false) do
      add(:fsd_source_key, :text)
      add(:fsd_source_id, :uuid)
      add(:fsd_memo, :text)
      add(:fsd_total_cents, :bigint, null: false)
      add(:fsd_start_on, :date, null: false)
      add(:fsd_months, :integer, null: false)
      add(:fsd_method, :text, null: false, default: "straight_line")
      add(:fsd_deferred_key, :text, null: false, default: "deferred_revenue")

      add(
        :fsd_cost_object_id,
        references(:cob_cost_object,
          column: :cob_id,
          name: "fsd_revenue_schedule_fsd_cost_object_id_fkey",
          type: :uuid
        )
      )

      add(:fsd_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:fsd_org_id, :uuid, null: false)
      add(:fsd_inserted_at, :utc_datetime, null: false)
      add(:fsd_updated_at, :utc_datetime, null: false)
    end

    create(index(:fsd_revenue_schedule, [:fsd_org_id]))
    create(index(:fsd_revenue_schedule, [:fsd_cost_object_id]))

    create(
      constraint(:fsd_revenue_schedule, :fsd_method_valid,
        check: "fsd_method IN ('straight_line','cost_incurred')"
      )
    )

    create(
      constraint(:fsd_revenue_schedule, :fsd_deferred_key_valid,
        check: "fsd_deferred_key IN ('deferred_revenue','grant_deferred')"
      )
    )

    create(
      constraint(:fsd_revenue_schedule, :fsd_amounts_positive,
        check: "fsd_total_cents > 0 AND fsd_months > 0 AND fsd_total_cents >= fsd_months"
      )
    )

    create table(:frc_revenue_recognition, primary_key: false) do
      add(:frc_period_key, :text, null: false)
      add(:frc_amount_cents, :bigint, null: false)
      add(:frc_recognized_on, :date, null: false)
      add(:frc_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:frc_org_id, :uuid, null: false)
      add(:frc_inserted_at, :utc_datetime, null: false)
      add(:frc_updated_at, :utc_datetime, null: false)

      add(
        :frc_schedule_id,
        references(:fsd_revenue_schedule,
          column: :fsd_id,
          name: "frc_revenue_recognition_frc_schedule_id_fkey",
          type: :uuid
        ),
        null: false
      )
    end

    create(index(:frc_revenue_recognition, [:frc_org_id]))
    create(index(:frc_revenue_recognition, [:frc_schedule_id]))

    # R9's exactly-once anchor: one period releases once.
    create(
      unique_index(:frc_revenue_recognition, [:frc_org_id, :frc_schedule_id, :frc_period_key],
        name: :frc_period_unique
      )
    )

    create(
      constraint(:frc_revenue_recognition, :frc_amount_positive, check: "frc_amount_cents > 0")
    )

    execute(
      """
      CREATE FUNCTION frc_revenue_recognition_append_only() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        RAISE EXCEPTION 'frc_revenue_recognition: % is refused — a recognition is an '
          'append-only fact; a correction is a reversing entry, never a rewrite. '
          'Recognition id: %', TG_OP, OLD.frc_id;
      END;
      $$;
      """,
      "DROP FUNCTION IF EXISTS frc_revenue_recognition_append_only()"
    )

    execute(
      """
      CREATE TRIGGER frc_revenue_recognition_append_only_tg
      BEFORE UPDATE OR DELETE ON frc_revenue_recognition
      FOR EACH ROW EXECUTE FUNCTION frc_revenue_recognition_append_only()
      """,
      "DROP TRIGGER IF EXISTS frc_revenue_recognition_append_only_tg ON frc_revenue_recognition"
    )

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    execute(
      "DROP TRIGGER IF EXISTS frc_revenue_recognition_append_only_tg ON frc_revenue_recognition"
    )

    execute("DROP FUNCTION IF EXISTS frc_revenue_recognition_append_only()")

    drop(table(:frc_revenue_recognition))
    drop(table(:fsd_revenue_schedule))
  end
end
