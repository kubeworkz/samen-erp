defmodule Samenerp.Repo.Migrations.AddFinancePrepaids do
  @moduledoc """
  WS-ACCT prepaid expense slice on the Kubeworkz books (`Samenerp.Erp`,
  `PrepaidSchedule` `sep`, `PrepaidRelease` `spe`). Same derived contract and
  exactly-once/append-only belts as the core fixture; the schedule names the
  host's `1200`/`1210` prepaid accounts directly.
  """

  use Samen.Migration

  @resources [
    Samenerp.Erp.PrepaidSchedule,
    Samenerp.Erp.PrepaidRelease
  ]

  def up do
    create table(:sep_prepaid_schedule, primary_key: false) do
      add(:sep_code, :text, null: false)
      add(:sep_name, :text, null: false)
      add(:sep_memo, :text)
      add(:sep_source_key, :text)
      add(:sep_source_id, :uuid)
      add(:sep_total_cents, :bigint, null: false)
      add(:sep_start_on, :date, null: false)
      add(:sep_months, :integer, null: false)
      add(:sep_method, :text, null: false, default: "straight_line")
      add(:sep_dimension_key, :text, null: false, default: "project")

      add(
        :sep_prepaid_account_id,
        references(:eca_account,
          column: :eca_id,
          name: "sep_prepaid_schedule_sep_prepaid_account_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(
        :sep_expense_account_id,
        references(:eca_account,
          column: :eca_id,
          name: "sep_prepaid_schedule_sep_expense_account_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(
        :sep_cost_object_id,
        references(:eco_cost_object,
          column: :eco_id,
          name: "sep_prepaid_schedule_sep_cost_object_id_fkey",
          type: :uuid
        )
      )

      add(:sep_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:sep_org_id, :uuid, null: false)
      add(:sep_inserted_at, :utc_datetime, null: false)
      add(:sep_updated_at, :utc_datetime, null: false)
    end

    create(index(:sep_prepaid_schedule, [:sep_org_id]))
    create(index(:sep_prepaid_schedule, [:sep_prepaid_account_id]))
    create(index(:sep_prepaid_schedule, [:sep_expense_account_id]))
    create(index(:sep_prepaid_schedule, [:sep_cost_object_id]))

    create(unique_index(:sep_prepaid_schedule, [:sep_org_id, :sep_code], name: :sep_code_unique))

    create(
      constraint(:sep_prepaid_schedule, :sep_method_valid,
        check: "sep_method IN ('straight_line')"
      )
    )

    create(
      constraint(:sep_prepaid_schedule, :sep_dimension_key_valid,
        check: "sep_dimension_key IN ('project','lot','fund','cost_pool')"
      )
    )

    create(
      constraint(:sep_prepaid_schedule, :sep_amounts_valid,
        check: "sep_total_cents > 0 AND sep_months > 0 AND sep_total_cents >= sep_months"
      )
    )

    create(
      constraint(:sep_prepaid_schedule, :sep_source_pair_valid,
        check: "(sep_source_key IS NULL) = (sep_source_id IS NULL)"
      )
    )

    create table(:spe_prepaid_release, primary_key: false) do
      add(:spe_period_key, :text, null: false)
      add(:spe_amount_cents, :bigint, null: false)
      add(:spe_released_on, :date, null: false)

      add(
        :spe_prepaid_account_id,
        references(:eca_account,
          column: :eca_id,
          name: "spe_prepaid_release_spe_prepaid_account_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(
        :spe_expense_account_id,
        references(:eca_account,
          column: :eca_id,
          name: "spe_prepaid_release_spe_expense_account_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(
        :spe_schedule_id,
        references(:sep_prepaid_schedule,
          column: :sep_id,
          name: "spe_prepaid_release_spe_schedule_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(:spe_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:spe_org_id, :uuid, null: false)
      add(:spe_inserted_at, :utc_datetime, null: false)
      add(:spe_updated_at, :utc_datetime, null: false)
    end

    create(index(:spe_prepaid_release, [:spe_org_id]))
    create(index(:spe_prepaid_release, [:spe_schedule_id]))
    create(index(:spe_prepaid_release, [:spe_period_key]))

    create(
      unique_index(:spe_prepaid_release, [:spe_org_id, :spe_schedule_id, :spe_period_key],
        name: :spe_period_unique
      )
    )

    create(constraint(:spe_prepaid_release, :spe_amount_positive, check: "spe_amount_cents > 0"))

    create(
      constraint(:spe_prepaid_release, :spe_period_valid,
        check: "spe_period_key ~ '^[0-9]{4}-(0[1-9]|1[0-2])$'"
      )
    )

    execute(
      """
      CREATE FUNCTION spe_prepaid_release_append_only() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        RAISE EXCEPTION 'spe_prepaid_release: % is refused — a prepaid release is an '
          'append-only fact; a correction is a reversing entry, never a rewrite. '
          'Release id: %', TG_OP, OLD.spe_id;
      END;
      $$;
      """,
      "DROP FUNCTION IF EXISTS spe_prepaid_release_append_only()"
    )

    execute(
      """
      CREATE TRIGGER spe_prepaid_release_append_only_tg
      BEFORE UPDATE OR DELETE ON spe_prepaid_release
      FOR EACH ROW EXECUTE FUNCTION spe_prepaid_release_append_only()
      """,
      "DROP TRIGGER IF EXISTS spe_prepaid_release_append_only_tg ON spe_prepaid_release"
    )

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    execute("DROP TRIGGER IF EXISTS spe_prepaid_release_append_only_tg ON spe_prepaid_release")
    execute("DROP FUNCTION IF EXISTS spe_prepaid_release_append_only()")

    drop(table(:spe_prepaid_release))
    drop(table(:sep_prepaid_schedule))
  end
end
