defmodule SamenCore.TestRepo.Migrations.AddPayrollSettlement do
  @moduledoc """
  Payroll settlement batches for the core fixture: one payment/remittance
  batch per posted payroll import, linked to the cash account and the draft
  journal entries it generated.
  """

  use Samen.Migration

  @resources [SamenCore.Support.FinanceFixture.PayrollSettlement]

  def up do
    create table(:pss_payroll_settlement, primary_key: false) do
      add(:pss_settlement_date, :date, null: false)
      add(:pss_status, :text, null: false, default: "draft")
      add(:pss_total_cents, :bigint, null: false, default: 0)
      add(:pss_payment_count, :integer, null: false, default: 0)
      add(:pss_entry_ids, {:array, :uuid}, null: false, default: [])
      add(:pss_reference, :text)
      add(:pss_prepared_by, :text, null: false)
      add(:pss_prepared_at, :utc_datetime, null: false)
      add(:pss_posted_by, :text)
      add(:pss_posted_at, :utc_datetime)
      add(:pss_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:pss_org_id, :uuid, null: false)
      add(:pss_inserted_at, :utc_datetime, null: false)
      add(:pss_updated_at, :utc_datetime, null: false)

      add(
        :pss_payroll_import_id,
        references(:pfs_payroll_import,
          column: :pfs_id,
          name: "pss_payroll_settlement_pss_payroll_import_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(
        :pss_cash_account_id,
        references(:sac_account,
          column: :sac_id,
          name: "pss_payroll_settlement_pss_cash_account_id_fkey",
          type: :uuid
        ),
        null: false
      )
    end

    create(index(:pss_payroll_settlement, [:pss_org_id]))
    create(index(:pss_payroll_settlement, [:pss_cash_account_id]))

    create(
      unique_index(
        :pss_payroll_settlement,
        [:pss_org_id, :pss_payroll_import_id],
        name: :pss_payroll_settlement_unique
      )
    )

    create(
      constraint(:pss_payroll_settlement, :pss_status_valid,
        check: "pss_status IN ('draft','posted')"
      )
    )

    create(constraint(:pss_payroll_settlement, :pss_total_positive, check: "pss_total_cents > 0"))

    create(
      constraint(:pss_payroll_settlement, :pss_payment_count_positive,
        check: "pss_payment_count > 0"
      )
    )

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    execute(
      "ALTER TABLE pss_payroll_settlement DROP CONSTRAINT IF EXISTS pss_payment_count_positive"
    )

    execute("ALTER TABLE pss_payroll_settlement DROP CONSTRAINT IF EXISTS pss_total_positive")
    execute("ALTER TABLE pss_payroll_settlement DROP CONSTRAINT IF EXISTS pss_status_valid")
    drop(table(:pss_payroll_settlement))
  end
end
