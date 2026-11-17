defmodule Samen.WebTest.Repo.Migrations.AddErpPayrollSettlement do
  @moduledoc """
  The Finance scope's payroll settlement batch on the `samen_web` test host
  (`Samen.WebTest.Erp.PayrollSettlement`, abbrev `pst`). It links one posted
  payroll import to a cash account and the draft settlement entries.
  """

  use Samen.Migration

  @resources [Samen.WebTest.Erp.PayrollSettlement]

  def up do
    create table(:pst_payroll_settlement, primary_key: false) do
      add(:pst_settlement_date, :date, null: false)
      add(:pst_status, :text, null: false, default: "draft")
      add(:pst_total_cents, :bigint, null: false, default: 0)
      add(:pst_payment_count, :integer, null: false, default: 0)
      add(:pst_entry_ids, {:array, :uuid}, null: false, default: [])
      add(:pst_reference, :text)
      add(:pst_prepared_by, :text, null: false)
      add(:pst_prepared_at, :utc_datetime, null: false)
      add(:pst_posted_by, :text)
      add(:pst_posted_at, :utc_datetime)
      add(:pst_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:pst_org_id, :uuid, null: false)
      add(:pst_inserted_at, :utc_datetime, null: false)
      add(:pst_updated_at, :utc_datetime, null: false)

      add(
        :pst_payroll_import_id,
        references(:epw_payroll_import,
          column: :epw_id,
          name: "pst_payroll_settlement_pst_payroll_import_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(
        :pst_cash_account_id,
        references(:fca_account,
          column: :fca_id,
          name: "pst_payroll_settlement_pst_cash_account_id_fkey",
          type: :uuid
        ),
        null: false
      )
    end

    create(index(:pst_payroll_settlement, [:pst_org_id]))
    create(index(:pst_payroll_settlement, [:pst_cash_account_id]))

    create(
      unique_index(
        :pst_payroll_settlement,
        [:pst_org_id, :pst_payroll_import_id],
        name: :pst_payroll_settlement_unique
      )
    )

    create(
      constraint(:pst_payroll_settlement, :pst_status_valid,
        check: "pst_status IN ('draft','posted')"
      )
    )

    create(constraint(:pst_payroll_settlement, :pst_total_positive, check: "pst_total_cents > 0"))

    create(
      constraint(:pst_payroll_settlement, :pst_payment_count_positive,
        check: "pst_payment_count > 0"
      )
    )

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    execute(
      "ALTER TABLE pst_payroll_settlement DROP CONSTRAINT IF EXISTS pst_payment_count_positive"
    )

    execute("ALTER TABLE pst_payroll_settlement DROP CONSTRAINT IF EXISTS pst_total_positive")
    execute("ALTER TABLE pst_payroll_settlement DROP CONSTRAINT IF EXISTS pst_status_valid")
    drop(table(:pst_payroll_settlement))
  end
end
