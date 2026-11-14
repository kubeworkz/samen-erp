defmodule Samen.WebTest.Repo.Migrations.AddFinancePrepaids do
  @moduledoc """
  WS-ACCT prepaid expense slice on the `samen_web` test host
  (`Samen.WebTest.Erp`, `PrepaidSchedule` `wep`, `PrepaidRelease` `ewp`).
  Same derived contract and exactly-once/append-only belts as the core fixture.
  """

  use Samen.Migration

  @resources [
    Samen.WebTest.Erp.PrepaidSchedule,
    Samen.WebTest.Erp.PrepaidRelease
  ]

  def up do
    create table(:wep_prepaid_schedule, primary_key: false) do
      add(:wep_code, :text, null: false)
      add(:wep_name, :text, null: false)
      add(:wep_memo, :text)
      add(:wep_source_key, :text)
      add(:wep_source_id, :uuid)
      add(:wep_total_cents, :bigint, null: false)
      add(:wep_start_on, :date, null: false)
      add(:wep_months, :integer, null: false)
      add(:wep_method, :text, null: false, default: "straight_line")
      add(:wep_dimension_key, :text, null: false, default: "project")

      add(
        :wep_prepaid_account_id,
        references(:fca_account,
          column: :fca_id,
          name: "wep_prepaid_schedule_wep_prepaid_account_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(
        :wep_expense_account_id,
        references(:fca_account,
          column: :fca_id,
          name: "wep_prepaid_schedule_wep_expense_account_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(
        :wep_cost_object_id,
        references(:fco_cost_object,
          column: :fco_id,
          name: "wep_prepaid_schedule_wep_cost_object_id_fkey",
          type: :uuid
        )
      )

      add(:wep_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:wep_org_id, :uuid, null: false)
      add(:wep_inserted_at, :utc_datetime, null: false)
      add(:wep_updated_at, :utc_datetime, null: false)
    end

    create(index(:wep_prepaid_schedule, [:wep_org_id]))
    create(index(:wep_prepaid_schedule, [:wep_prepaid_account_id]))
    create(index(:wep_prepaid_schedule, [:wep_expense_account_id]))
    create(index(:wep_prepaid_schedule, [:wep_cost_object_id]))

    create(unique_index(:wep_prepaid_schedule, [:wep_org_id, :wep_code], name: :wep_code_unique))

    create(
      constraint(:wep_prepaid_schedule, :wep_method_valid,
        check: "wep_method IN ('straight_line')"
      )
    )

    create(
      constraint(:wep_prepaid_schedule, :wep_dimension_key_valid,
        check: "wep_dimension_key IN ('project','lot','fund','cost_pool')"
      )
    )

    create(
      constraint(:wep_prepaid_schedule, :wep_amounts_valid,
        check: "wep_total_cents > 0 AND wep_months > 0 AND wep_total_cents >= wep_months"
      )
    )

    create(
      constraint(:wep_prepaid_schedule, :wep_source_pair_valid,
        check: "(wep_source_key IS NULL) = (wep_source_id IS NULL)"
      )
    )

    create table(:ewp_prepaid_release, primary_key: false) do
      add(:ewp_period_key, :text, null: false)
      add(:ewp_amount_cents, :bigint, null: false)
      add(:ewp_released_on, :date, null: false)

      add(
        :ewp_prepaid_account_id,
        references(:fca_account,
          column: :fca_id,
          name: "ewp_prepaid_release_ewp_prepaid_account_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(
        :ewp_expense_account_id,
        references(:fca_account,
          column: :fca_id,
          name: "ewp_prepaid_release_ewp_expense_account_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(
        :ewp_schedule_id,
        references(:wep_prepaid_schedule,
          column: :wep_id,
          name: "ewp_prepaid_release_ewp_schedule_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(:ewp_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:ewp_org_id, :uuid, null: false)
      add(:ewp_inserted_at, :utc_datetime, null: false)
      add(:ewp_updated_at, :utc_datetime, null: false)
    end

    create(index(:ewp_prepaid_release, [:ewp_org_id]))
    create(index(:ewp_prepaid_release, [:ewp_schedule_id]))
    create(index(:ewp_prepaid_release, [:ewp_period_key]))

    create(
      unique_index(:ewp_prepaid_release, [:ewp_org_id, :ewp_schedule_id, :ewp_period_key],
        name: :ewp_period_unique
      )
    )

    create(constraint(:ewp_prepaid_release, :ewp_amount_positive, check: "ewp_amount_cents > 0"))

    create(
      constraint(:ewp_prepaid_release, :ewp_period_valid,
        check: "ewp_period_key ~ '^[0-9]{4}-(0[1-9]|1[0-2])$'"
      )
    )

    execute(
      """
      CREATE FUNCTION ewp_prepaid_release_append_only() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        RAISE EXCEPTION 'ewp_prepaid_release: % is refused — a prepaid release is an '
          'append-only fact; a correction is a reversing entry, never a rewrite. '
          'Release id: %', TG_OP, OLD.ewp_id;
      END;
      $$;
      """,
      "DROP FUNCTION IF EXISTS ewp_prepaid_release_append_only()"
    )

    execute(
      """
      CREATE TRIGGER ewp_prepaid_release_append_only_tg
      BEFORE UPDATE OR DELETE ON ewp_prepaid_release
      FOR EACH ROW EXECUTE FUNCTION ewp_prepaid_release_append_only()
      """,
      "DROP TRIGGER IF EXISTS ewp_prepaid_release_append_only_tg ON ewp_prepaid_release"
    )

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    execute("DROP TRIGGER IF EXISTS ewp_prepaid_release_append_only_tg ON ewp_prepaid_release")
    execute("DROP FUNCTION IF EXISTS ewp_prepaid_release_append_only()")

    drop(table(:ewp_prepaid_release))
    drop(table(:wep_prepaid_schedule))
  end
end
