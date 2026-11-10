defmodule SamenCore.TestRepo.Migrations.AddArStatementDeliveryAndCollections do
  @moduledoc """
  AR statement delivery and the manual collections workflow in the
  `samen_core` Finance fixture.

  `sdm_statement_delivery` is an immutable send-attempt audit row.
  `scl_collection_case` is a customer/currency workflow record with an
  append-only action timeline. Neither table posts a journal entry or stores
  customer PII.
  """

  use Samen.Migration

  @resources [
    SamenCore.Support.FinanceFixture.StatementDelivery,
    SamenCore.Support.FinanceFixture.CollectionCase
  ]

  def up do
    create table(:sdm_statement_delivery, primary_key: false) do
      add(:sdm_customer_id, :uuid, null: false)
      add(:sdm_send_id, :uuid, null: false)
      add(:sdm_template_id, :text, null: false, default: "ar_statement")
      add(:sdm_as_of, :date, null: false)
      add(:sdm_currency, :text, null: false)
      add(:sdm_status, :text, null: false, default: "queued")
      add(:sdm_invoiced_cents, :bigint, null: false, default: 0)
      add(:sdm_paid_cents, :bigint, null: false, default: 0)
      add(:sdm_credited_cents, :bigint, null: false, default: 0)
      add(:sdm_outstanding_cents, :bigint, null: false, default: 0)
      add(:sdm_unapplied_cents, :bigint, null: false, default: 0)
      add(:sdm_invoice_count, :integer, null: false, default: 0)
      add(:sdm_invoice_ids, {:array, :uuid}, null: false, default: [])
      add(:sdm_provider_message_id, :text)
      add(:sdm_delivered_at, :utc_datetime)
      add(:sdm_error, :text)

      add(:sdm_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:sdm_org_id, :uuid, null: false)
      add(:sdm_inserted_at, :utc_datetime, null: false)
      add(:sdm_updated_at, :utc_datetime, null: false)
    end

    create(index(:sdm_statement_delivery, [:sdm_org_id]))
    create(index(:sdm_statement_delivery, [:sdm_org_id, :sdm_customer_id]))
    create(unique_index(:sdm_statement_delivery, [:sdm_org_id, :sdm_send_id]))

    create(
      constraint(:sdm_statement_delivery, :sdm_statement_delivery_amounts_nonnegative,
        check:
          "sdm_invoiced_cents >= 0 AND sdm_paid_cents >= 0 AND sdm_credited_cents >= 0 AND " <>
            "sdm_outstanding_cents >= 0 AND sdm_unapplied_cents >= 0"
      )
    )

    create table(:scl_collection_case, primary_key: false) do
      add(:scl_customer_id, :uuid, null: false)
      add(:scl_opened_on, :date, null: false)
      add(:scl_currency, :text, null: false)
      add(:scl_status, :text, null: false, default: "open")
      add(:scl_stage, :text, null: false, default: "reminder")
      add(:scl_next_action_on, :date)
      add(:scl_last_contacted_at, :utc_datetime)
      add(:scl_outstanding_cents, :bigint, null: false, default: 0)
      add(:scl_invoice_count, :integer, null: false, default: 0)
      add(:scl_promised_cents, :bigint)
      add(:scl_promise_to_pay_on, :date)
      add(:scl_notes, :text)
      add(:scl_actions, :jsonb, null: false, default: "{}")

      add(:scl_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:scl_org_id, :uuid, null: false)
      add(:scl_inserted_at, :utc_datetime, null: false)
      add(:scl_updated_at, :utc_datetime, null: false)
    end

    create(index(:scl_collection_case, [:scl_org_id]))
    create(index(:scl_collection_case, [:scl_org_id, :scl_customer_id]))
    create(index(:scl_collection_case, [:scl_org_id, :scl_status]))

    create(
      unique_index(
        :scl_collection_case,
        [:scl_org_id, :scl_customer_id, :scl_currency],
        where: "scl_status <> 'resolved'",
        name: :scl_collection_case_active_unique
      )
    )

    create(
      constraint(:scl_collection_case, :scl_collection_case_amounts_nonnegative,
        check:
          "scl_outstanding_cents >= 0 AND (scl_promised_cents IS NULL OR scl_promised_cents >= 0)"
      )
    )

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)
    drop(table(:scl_collection_case))
    drop(table(:sdm_statement_delivery))
  end
end
