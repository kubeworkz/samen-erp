defmodule Samen.WebTest.Repo.Migrations.AddFinanceExpenses do
  @moduledoc """
  WS-ERP E31 (#12): expense categories, corporate cards and expense reports for
  the samen_web test host. Card rows hold only last-four + an opaque cardholder
  id. Tables are catalog-synced with the test host's mounted resources.
  """

  use Samen.Migration

  @resources [
    Samen.WebTest.Erp.ExpenseCategory,
    Samen.WebTest.Erp.CorporateCard,
    Samen.WebTest.Erp.ExpenseReport
  ]

  def up do
    create table(:wex_expense_category, primary_key: false) do
      add(:wex_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:wex_org_id, :uuid, null: false)
      add(:wex_name, :text, null: false)

      add(
        :wex_account_id,
        references(:fca_account,
          column: :fca_id,
          name: "wex_expense_category_account_fkey",
          type: :uuid
        ),
        null: false
      )

      add(:wex_requires_receipt, :boolean, null: false, default: false)
      add(:wex_max_amount_cents, :bigint)
      add(:wex_is_active, :boolean, null: false, default: true)
      add(:wex_inserted_at, :utc_datetime, null: false)
      add(:wex_updated_at, :utc_datetime, null: false)
    end

    create(index(:wex_expense_category, [:wex_org_id]))
    create(index(:wex_expense_category, [:wex_account_id]))
    create(index(:wex_expense_category, [:wex_org_id, :wex_name], unique: true))

    create(
      constraint(:wex_expense_category, :wex_max_amount_positive,
        check: "wex_max_amount_cents IS NULL OR wex_max_amount_cents > 0"
      )
    )

    create table(:wcc_corporate_card, primary_key: false) do
      add(:wcc_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:wcc_org_id, :uuid, null: false)
      add(:wcc_name, :text, null: false)
      add(:wcc_last4, :text, null: false)
      add(:wcc_cardholder_id, :uuid, null: false)

      add(
        :wcc_account_id,
        references(:fca_account,
          column: :fca_id,
          name: "wcc_corporate_card_account_fkey",
          type: :uuid
        ),
        null: false
      )

      add(:wcc_currency, :text, null: false, default: "USD")
      add(:wcc_is_active, :boolean, null: false, default: true)
      add(:wcc_inserted_at, :utc_datetime, null: false)
      add(:wcc_updated_at, :utc_datetime, null: false)
    end

    create(index(:wcc_corporate_card, [:wcc_org_id]))
    create(index(:wcc_corporate_card, [:wcc_account_id]))
    create(index(:wcc_corporate_card, [:wcc_org_id, :wcc_name], unique: true))
    create(constraint(:wcc_corporate_card, :wcc_last4_format, check: "wcc_last4 ~ '^[0-9]{4}$'"))

    create table(:wer_expense_report, primary_key: false) do
      add(:wer_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:wer_org_id, :uuid, null: false)
      add(:wer_employee_id, :uuid, null: false)
      add(:wer_title, :text, null: false)
      add(:wer_currency, :text, null: false, default: "USD")
      add(:wer_lines, :map, null: false, default: fragment("'[]'::jsonb"))
      add(:wer_total_cents, :bigint, null: false, default: 0)
      add(:wer_status, :text, null: false, default: "draft")
      add(:wer_submitted_at, :utc_datetime)
      add(:wer_approved_at, :utc_datetime)
      add(:wer_rejected_at, :utc_datetime)
      add(:wer_reimbursed_at, :utc_datetime)
      add(:wer_rejected_reason, :text)
      add(:wer_posted_entry_id, :uuid)
      add(:wer_settlement_entry_id, :uuid)
      add(:wer_inserted_at, :utc_datetime, null: false)
      add(:wer_updated_at, :utc_datetime, null: false)
    end

    create(index(:wer_expense_report, [:wer_org_id]))
    create(index(:wer_expense_report, [:wer_org_id, :wer_status]))
    create(index(:wer_expense_report, [:wer_org_id, :wer_employee_id]))

    create(
      constraint(:wer_expense_report, :wer_status_valid,
        check:
          "wer_status IN ('draft','submitted','approved','rejected','reimbursed','cancelled')"
      )
    )

    create(
      constraint(:wer_expense_report, :wer_total_non_negative, check: "wer_total_cents >= 0")
    )

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    drop(table(:wer_expense_report))
    drop(table(:wcc_corporate_card))
    drop(table(:wex_expense_category))
  end
end
