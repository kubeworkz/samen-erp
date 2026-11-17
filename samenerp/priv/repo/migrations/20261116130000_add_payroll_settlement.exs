defmodule Samenerp.Repo.Migrations.AddPayrollSettlement do
  @moduledoc """
  Payroll settlement batches on the Kubeworkz host: one payment/remittance
  batch per posted payroll register, linked to the host cash account and the
  draft `ecj_journal_entry` rows it generated.
  """

  use Samen.Migration

  @resources [Samenerp.Erp.PayrollSettlement]

  def up do
    create table(:psy_payroll_settlement, primary_key: false) do
      add(:psy_settlement_date, :date, null: false)
      add(:psy_status, :text, null: false, default: "draft")
      add(:psy_total_cents, :bigint, null: false, default: 0)
      add(:psy_payment_count, :integer, null: false, default: 0)
      add(:psy_entry_ids, {:array, :uuid}, null: false, default: [])
      add(:psy_reference, :text)
      add(:psy_prepared_by, :text, null: false)
      add(:psy_prepared_at, :utc_datetime, null: false)
      add(:psy_posted_by, :text)
      add(:psy_posted_at, :utc_datetime)
      add(:psy_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:psy_org_id, :uuid, null: false)
      add(:psy_inserted_at, :utc_datetime, null: false)
      add(:psy_updated_at, :utc_datetime, null: false)

      add(
        :psy_payroll_import_id,
        references(:esp_payroll_import,
          column: :esp_id,
          name: "psy_payroll_settlement_psy_payroll_import_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(
        :psy_cash_account_id,
        references(:eca_account,
          column: :eca_id,
          name: "psy_payroll_settlement_psy_cash_account_id_fkey",
          type: :uuid
        ),
        null: false
      )
    end

    create(index(:psy_payroll_settlement, [:psy_org_id]))
    create(index(:psy_payroll_settlement, [:psy_cash_account_id]))

    create(
      unique_index(
        :psy_payroll_settlement,
        [:psy_org_id, :psy_payroll_import_id],
        name: :psy_payroll_settlement_unique
      )
    )

    create(
      constraint(:psy_payroll_settlement, :psy_status_valid,
        check: "psy_status IN ('draft','posted')"
      )
    )

    create(constraint(:psy_payroll_settlement, :psy_total_positive, check: "psy_total_cents > 0"))

    create(
      constraint(:psy_payroll_settlement, :psy_payment_count_positive,
        check: "psy_payment_count > 0"
      )
    )

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    execute(
      "ALTER TABLE psy_payroll_settlement DROP CONSTRAINT IF EXISTS psy_payment_count_positive"
    )

    execute("ALTER TABLE psy_payroll_settlement DROP CONSTRAINT IF EXISTS psy_total_positive")
    execute("ALTER TABLE psy_payroll_settlement DROP CONSTRAINT IF EXISTS psy_status_valid")
    drop(table(:psy_payroll_settlement))
  end
end
