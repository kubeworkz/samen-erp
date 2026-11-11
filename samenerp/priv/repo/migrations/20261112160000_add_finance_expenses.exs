defmodule Samenerp.Repo.Migrations.AddFinanceExpenses do
  @moduledoc """
  WS-ERP E31 (#12): expense categories, corporate cards and expense reports for
  the Kubeworkz host. Card rows hold only last-four + an opaque cardholder id.
  Tables are catalog-synced with Samenerp.Erp's mounted resources.
  """

  use Samen.Migration

  @resources [
    Samenerp.Erp.ExpenseCategory,
    Samenerp.Erp.CorporateCard,
    Samenerp.Erp.ExpenseReport
  ]

  def up do
    create table(:ecg_expense_category, primary_key: false) do
      add(:ecg_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:ecg_org_id, :uuid, null: false)
      add(:ecg_name, :text, null: false)

      add(
        :ecg_account_id,
        references(:eca_account,
          column: :eca_id,
          name: "ecg_expense_category_account_fkey",
          type: :uuid
        ),
        null: false
      )

      add(:ecg_requires_receipt, :boolean, null: false, default: false)
      add(:ecg_max_amount_cents, :bigint)
      add(:ecg_is_active, :boolean, null: false, default: true)
      add(:ecg_inserted_at, :utc_datetime, null: false)
      add(:ecg_updated_at, :utc_datetime, null: false)
    end

    create(index(:ecg_expense_category, [:ecg_org_id]))
    create(index(:ecg_expense_category, [:ecg_account_id]))
    create(index(:ecg_expense_category, [:ecg_org_id, :ecg_name], unique: true))

    create(
      constraint(:ecg_expense_category, :ecg_max_amount_positive,
        check: "ecg_max_amount_cents IS NULL OR ecg_max_amount_cents > 0"
      )
    )

    create table(:ecy_corporate_card, primary_key: false) do
      add(:ecy_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:ecy_org_id, :uuid, null: false)
      add(:ecy_name, :text, null: false)
      add(:ecy_last4, :text, null: false)
      add(:ecy_cardholder_id, :uuid, null: false)

      add(
        :ecy_account_id,
        references(:eca_account,
          column: :eca_id,
          name: "ecy_corporate_card_account_fkey",
          type: :uuid
        ),
        null: false
      )

      add(:ecy_currency, :text, null: false, default: "USD")
      add(:ecy_is_active, :boolean, null: false, default: true)
      add(:ecy_inserted_at, :utc_datetime, null: false)
      add(:ecy_updated_at, :utc_datetime, null: false)
    end

    create(index(:ecy_corporate_card, [:ecy_org_id]))
    create(index(:ecy_corporate_card, [:ecy_account_id]))
    create(index(:ecy_corporate_card, [:ecy_org_id, :ecy_name], unique: true))
    create(constraint(:ecy_corporate_card, :ecy_last4_format, check: "ecy_last4 ~ '^[0-9]{4}$'"))

    create table(:ecz_expense_report, primary_key: false) do
      add(:ecz_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:ecz_org_id, :uuid, null: false)
      add(:ecz_employee_id, :uuid, null: false)
      add(:ecz_title, :text, null: false)
      add(:ecz_currency, :text, null: false, default: "USD")
      add(:ecz_lines, :map, null: false, default: fragment("'[]'::jsonb"))
      add(:ecz_total_cents, :bigint, null: false, default: 0)
      add(:ecz_status, :text, null: false, default: "draft")
      add(:ecz_submitted_at, :utc_datetime)
      add(:ecz_approved_at, :utc_datetime)
      add(:ecz_rejected_at, :utc_datetime)
      add(:ecz_reimbursed_at, :utc_datetime)
      add(:ecz_rejected_reason, :text)
      add(:ecz_posted_entry_id, :uuid)
      add(:ecz_settlement_entry_id, :uuid)
      add(:ecz_inserted_at, :utc_datetime, null: false)
      add(:ecz_updated_at, :utc_datetime, null: false)
    end

    create(index(:ecz_expense_report, [:ecz_org_id]))
    create(index(:ecz_expense_report, [:ecz_org_id, :ecz_status]))
    create(index(:ecz_expense_report, [:ecz_org_id, :ecz_employee_id]))

    create(
      constraint(:ecz_expense_report, :ecz_status_valid,
        check:
          "ecz_status IN ('draft','submitted','approved','rejected','reimbursed','cancelled')"
      )
    )

    create(
      constraint(:ecz_expense_report, :ecz_total_non_negative, check: "ecz_total_cents >= 0")
    )

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    drop(table(:ecz_expense_report))
    drop(table(:ecy_corporate_card))
    drop(table(:ecg_expense_category))
  end
end
