defmodule SamenCore.TestRepo.Migrations.AddFinancePrepaids do
  @moduledoc """
  WS-ACCT prepaid expense slice — the prepaid contract and its release facts in
  the `samen_core` fixture (`PrepaidSchedule` `spf`, `PrepaidRelease` `psf`).

    * `spf_prepaid_schedule` — one prepaid total, its term and the two accounts
      every release uses. No schedule table: the month slices are derived from
      `{total_cents, months, start_on}`.
    * `psf_prepaid_release` — one period's released slice, naming the accounts
      it paid and anchored to its entry, append-only.

  The unique index on `{org, schedule, period}` is the exactly-once anchor.
  """

  use Samen.Migration

  @resources [
    SamenCore.Support.FinanceFixture.PrepaidSchedule,
    SamenCore.Support.FinanceFixture.PrepaidRelease
  ]

  def up do
    create table(:spf_prepaid_schedule, primary_key: false) do
      add(:spf_code, :text, null: false)
      add(:spf_name, :text, null: false)
      add(:spf_memo, :text)
      add(:spf_source_key, :text)
      add(:spf_source_id, :uuid)
      add(:spf_total_cents, :bigint, null: false)
      add(:spf_start_on, :date, null: false)
      add(:spf_months, :integer, null: false)
      add(:spf_method, :text, null: false, default: "straight_line")
      add(:spf_dimension_key, :text, null: false, default: "project")

      add(
        :spf_prepaid_account_id,
        references(:sac_account,
          column: :sac_id,
          name: "spf_prepaid_schedule_spf_prepaid_account_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(
        :spf_expense_account_id,
        references(:sac_account,
          column: :sac_id,
          name: "spf_prepaid_schedule_spf_expense_account_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(
        :spf_cost_object_id,
        references(:cob_cost_object,
          column: :cob_id,
          name: "spf_prepaid_schedule_spf_cost_object_id_fkey",
          type: :uuid
        )
      )

      add(:spf_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:spf_org_id, :uuid, null: false)
      add(:spf_inserted_at, :utc_datetime, null: false)
      add(:spf_updated_at, :utc_datetime, null: false)
    end

    create(index(:spf_prepaid_schedule, [:spf_org_id]))
    create(index(:spf_prepaid_schedule, [:spf_prepaid_account_id]))
    create(index(:spf_prepaid_schedule, [:spf_expense_account_id]))
    create(index(:spf_prepaid_schedule, [:spf_cost_object_id]))

    create(unique_index(:spf_prepaid_schedule, [:spf_org_id, :spf_code], name: :spf_code_unique))

    create(
      constraint(:spf_prepaid_schedule, :spf_method_valid,
        check: "spf_method IN ('straight_line')"
      )
    )

    create(
      constraint(:spf_prepaid_schedule, :spf_dimension_key_valid,
        check: "spf_dimension_key IN ('project','lot','fund','cost_pool')"
      )
    )

    create(
      constraint(:spf_prepaid_schedule, :spf_amounts_valid,
        check: "spf_total_cents > 0 AND spf_months > 0 AND spf_total_cents >= spf_months"
      )
    )

    create(
      constraint(:spf_prepaid_schedule, :spf_source_pair_valid,
        check: "(spf_source_key IS NULL) = (spf_source_id IS NULL)"
      )
    )

    create table(:psf_prepaid_release, primary_key: false) do
      add(:psf_period_key, :text, null: false)
      add(:psf_amount_cents, :bigint, null: false)
      add(:psf_released_on, :date, null: false)

      add(
        :psf_prepaid_account_id,
        references(:sac_account,
          column: :sac_id,
          name: "psf_prepaid_release_psf_prepaid_account_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(
        :psf_expense_account_id,
        references(:sac_account,
          column: :sac_id,
          name: "psf_prepaid_release_psf_expense_account_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(
        :psf_schedule_id,
        references(:spf_prepaid_schedule,
          column: :spf_id,
          name: "psf_prepaid_release_psf_schedule_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(:psf_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:psf_org_id, :uuid, null: false)
      add(:psf_inserted_at, :utc_datetime, null: false)
      add(:psf_updated_at, :utc_datetime, null: false)
    end

    create(index(:psf_prepaid_release, [:psf_org_id]))
    create(index(:psf_prepaid_release, [:psf_schedule_id]))
    create(index(:psf_prepaid_release, [:psf_period_key]))

    create(
      unique_index(:psf_prepaid_release, [:psf_org_id, :psf_schedule_id, :psf_period_key],
        name: :psf_period_unique
      )
    )

    create(constraint(:psf_prepaid_release, :psf_amount_positive, check: "psf_amount_cents > 0"))

    create(
      constraint(:psf_prepaid_release, :psf_period_valid,
        check: "psf_period_key ~ '^[0-9]{4}-(0[1-9]|1[0-2])$'"
      )
    )

    execute(
      """
      CREATE FUNCTION psf_prepaid_release_append_only() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        RAISE EXCEPTION 'psf_prepaid_release: % is refused — a prepaid release is an '
          'append-only fact; a correction is a reversing entry, never a rewrite. '
          'Release id: %', TG_OP, OLD.psf_id;
      END;
      $$;
      """,
      "DROP FUNCTION IF EXISTS psf_prepaid_release_append_only()"
    )

    execute(
      """
      CREATE TRIGGER psf_prepaid_release_append_only_tg
      BEFORE UPDATE OR DELETE ON psf_prepaid_release
      FOR EACH ROW EXECUTE FUNCTION psf_prepaid_release_append_only()
      """,
      "DROP TRIGGER IF EXISTS psf_prepaid_release_append_only_tg ON psf_prepaid_release"
    )

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    execute("DROP TRIGGER IF EXISTS psf_prepaid_release_append_only_tg ON psf_prepaid_release")
    execute("DROP FUNCTION IF EXISTS psf_prepaid_release_append_only()")

    drop(table(:psf_prepaid_release))
    drop(table(:spf_prepaid_schedule))
  end
end
