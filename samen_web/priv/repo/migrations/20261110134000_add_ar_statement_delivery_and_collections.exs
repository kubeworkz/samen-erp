defmodule Samen.WebTest.Repo.Migrations.AddArStatementDeliveryAndCollections do
  @moduledoc """
  AR statement delivery and collections on the `samen_web` test host.
  Mirrors the Finance fixture: one immutable delivery audit and one manual
  customer/currency collection case. No PII, no ledger writes.
  """

  use Samen.Migration

  @resources [
    Samen.WebTest.Erp.StatementDelivery,
    Samen.WebTest.Erp.CollectionCase
  ]

  def up do
    create table(:fcl_statement_delivery, primary_key: false) do
      add(:fcl_customer_id, :uuid, null: false)
      add(:fcl_send_id, :uuid, null: false)
      add(:fcl_template_id, :text, null: false, default: "ar_statement")
      add(:fcl_as_of, :date, null: false)
      add(:fcl_currency, :text, null: false)
      add(:fcl_status, :text, null: false, default: "queued")
      add(:fcl_invoiced_cents, :bigint, null: false, default: 0)
      add(:fcl_paid_cents, :bigint, null: false, default: 0)
      add(:fcl_credited_cents, :bigint, null: false, default: 0)
      add(:fcl_outstanding_cents, :bigint, null: false, default: 0)
      add(:fcl_unapplied_cents, :bigint, null: false, default: 0)
      add(:fcl_invoice_count, :integer, null: false, default: 0)
      add(:fcl_invoice_ids, {:array, :uuid}, null: false, default: [])
      add(:fcl_provider_message_id, :text)
      add(:fcl_delivered_at, :utc_datetime)
      add(:fcl_error, :text)

      add(:fcl_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:fcl_org_id, :uuid, null: false)
      add(:fcl_inserted_at, :utc_datetime, null: false)
      add(:fcl_updated_at, :utc_datetime, null: false)
    end

    create(index(:fcl_statement_delivery, [:fcl_org_id]))
    create(index(:fcl_statement_delivery, [:fcl_org_id, :fcl_customer_id]))
    create(unique_index(:fcl_statement_delivery, [:fcl_org_id, :fcl_send_id]))

    create(
      constraint(:fcl_statement_delivery, :fcl_statement_delivery_amounts_nonnegative,
        check:
          "fcl_invoiced_cents >= 0 AND fcl_paid_cents >= 0 AND fcl_credited_cents >= 0 AND " <>
            "fcl_outstanding_cents >= 0 AND fcl_unapplied_cents >= 0"
      )
    )

    create table(:fcc_collection_case, primary_key: false) do
      add(:fcc_customer_id, :uuid, null: false)
      add(:fcc_opened_on, :date, null: false)
      add(:fcc_currency, :text, null: false)
      add(:fcc_status, :text, null: false, default: "open")
      add(:fcc_stage, :text, null: false, default: "reminder")
      add(:fcc_next_action_on, :date)
      add(:fcc_last_contacted_at, :utc_datetime)
      add(:fcc_outstanding_cents, :bigint, null: false, default: 0)
      add(:fcc_invoice_count, :integer, null: false, default: 0)
      add(:fcc_promised_cents, :bigint)
      add(:fcc_promise_to_pay_on, :date)
      add(:fcc_notes, :text)
      add(:fcc_actions, :jsonb, null: false, default: "{}")

      add(:fcc_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:fcc_org_id, :uuid, null: false)
      add(:fcc_inserted_at, :utc_datetime, null: false)
      add(:fcc_updated_at, :utc_datetime, null: false)
    end

    create(index(:fcc_collection_case, [:fcc_org_id]))
    create(index(:fcc_collection_case, [:fcc_org_id, :fcc_customer_id]))
    create(index(:fcc_collection_case, [:fcc_org_id, :fcc_status]))

    create(
      unique_index(
        :fcc_collection_case,
        [:fcc_org_id, :fcc_customer_id, :fcc_currency],
        where: "fcc_status <> 'resolved'",
        name: :fcc_collection_case_active_unique
      )
    )

    create(
      constraint(:fcc_collection_case, :fcc_collection_case_amounts_nonnegative,
        check:
          "fcc_outstanding_cents >= 0 AND (fcc_promised_cents IS NULL OR fcc_promised_cents >= 0)"
      )
    )

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)
    drop(table(:fcc_collection_case))
    drop(table(:fcl_statement_delivery))
  end
end
