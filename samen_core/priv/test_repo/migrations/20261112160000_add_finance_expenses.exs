defmodule SamenCore.TestRepo.Migrations.AddFinanceExpenses do
  @moduledoc """
  WS-ERP E31 (#12): expense categories, corporate cards and expense reports for
  the core Finance fixture. Card rows hold only last-four + an opaque cardholder
  id — no PAN/CVV/name. Tables are catalog-synced with the fixture resources.
  """

  use Samen.Migration

  @resources [
    SamenCore.Support.FinanceFixture.ExpenseCategory,
    SamenCore.Support.FinanceFixture.CorporateCard,
    SamenCore.Support.FinanceFixture.ExpenseReport
  ]

  def up do
    create table(:exk_expense_category, primary_key: false) do
      add(:exk_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:exk_org_id, :uuid, null: false)
      add(:exk_name, :text, null: false)

      add(
        :exk_account_id,
        references(:sac_account,
          column: :sac_id,
          name: "exk_expense_category_account_fkey",
          type: :uuid
        ),
        null: false
      )

      add(:exk_requires_receipt, :boolean, null: false, default: false)
      add(:exk_max_amount_cents, :bigint)
      add(:exk_is_active, :boolean, null: false, default: true)
      add(:exk_inserted_at, :utc_datetime, null: false)
      add(:exk_updated_at, :utc_datetime, null: false)
    end

    create(index(:exk_expense_category, [:exk_org_id]))
    create(index(:exk_expense_category, [:exk_account_id]))
    create(index(:exk_expense_category, [:exk_org_id, :exk_name], unique: true))

    create(
      constraint(:exk_expense_category, :exk_max_amount_positive,
        check: "exk_max_amount_cents IS NULL OR exk_max_amount_cents > 0"
      )
    )

    create table(:ccd_corporate_card, primary_key: false) do
      add(:ccd_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:ccd_org_id, :uuid, null: false)
      add(:ccd_name, :text, null: false)
      add(:ccd_last4, :text, null: false)
      add(:ccd_cardholder_id, :uuid, null: false)

      add(
        :ccd_account_id,
        references(:sac_account,
          column: :sac_id,
          name: "ccd_corporate_card_account_fkey",
          type: :uuid
        ),
        null: false
      )

      add(:ccd_currency, :text, null: false, default: "USD")
      add(:ccd_is_active, :boolean, null: false, default: true)
      add(:ccd_inserted_at, :utc_datetime, null: false)
      add(:ccd_updated_at, :utc_datetime, null: false)
    end

    create(index(:ccd_corporate_card, [:ccd_org_id]))
    create(index(:ccd_corporate_card, [:ccd_account_id]))
    create(index(:ccd_corporate_card, [:ccd_org_id, :ccd_name], unique: true))
    create(constraint(:ccd_corporate_card, :ccd_last4_format, check: "ccd_last4 ~ '^[0-9]{4}$'"))

    create table(:exr_expense_report, primary_key: false) do
      add(:exr_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:exr_org_id, :uuid, null: false)
      add(:exr_employee_id, :uuid, null: false)
      add(:exr_title, :text, null: false)
      add(:exr_currency, :text, null: false, default: "USD")
      add(:exr_lines, :map, null: false, default: fragment("'[]'::jsonb"))
      add(:exr_total_cents, :bigint, null: false, default: 0)
      add(:exr_status, :text, null: false, default: "draft")
      add(:exr_submitted_at, :utc_datetime)
      add(:exr_approved_at, :utc_datetime)
      add(:exr_rejected_at, :utc_datetime)
      add(:exr_reimbursed_at, :utc_datetime)
      add(:exr_rejected_reason, :text)
      add(:exr_posted_entry_id, :uuid)
      add(:exr_settlement_entry_id, :uuid)
      add(:exr_inserted_at, :utc_datetime, null: false)
      add(:exr_updated_at, :utc_datetime, null: false)
    end

    create(index(:exr_expense_report, [:exr_org_id]))
    create(index(:exr_expense_report, [:exr_org_id, :exr_status]))
    create(index(:exr_expense_report, [:exr_org_id, :exr_employee_id]))

    create(
      constraint(:exr_expense_report, :exr_status_valid,
        check:
          "exr_status IN ('draft','submitted','approved','rejected','reimbursed','cancelled')"
      )
    )

    create(
      constraint(:exr_expense_report, :exr_total_non_negative, check: "exr_total_cents >= 0")
    )

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    drop(table(:exr_expense_report))
    drop(table(:ccd_corporate_card))
    drop(table(:exk_expense_category))
  end
end
