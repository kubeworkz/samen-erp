defmodule Samenerp.Repo.Migrations.AddArStatementDeliveryAndCollections do
  @moduledoc """
  AR statement delivery and collections on the Kubeworkz books. Mirrors the
  Finance fixture and `samen_web`; delivery is audited and collections are a
  manual workflow over the ledger read, never a second ledger.
  """

  use Samen.Migration

  @resources [
    Samenerp.Erp.StatementDelivery,
    Samenerp.Erp.CollectionCase
  ]

  def up do
    create table(:edm_statement_delivery, primary_key: false) do
      add(:edm_customer_id, :uuid, null: false)
      add(:edm_send_id, :uuid, null: false)
      add(:edm_template_id, :text, null: false, default: "ar_statement")
      add(:edm_as_of, :date, null: false)
      add(:edm_currency, :text, null: false)
      add(:edm_status, :text, null: false, default: "queued")
      add(:edm_invoiced_cents, :bigint, null: false, default: 0)
      add(:edm_paid_cents, :bigint, null: false, default: 0)
      add(:edm_credited_cents, :bigint, null: false, default: 0)
      add(:edm_outstanding_cents, :bigint, null: false, default: 0)
      add(:edm_unapplied_cents, :bigint, null: false, default: 0)
      add(:edm_invoice_count, :integer, null: false, default: 0)
      add(:edm_invoice_ids, {:array, :uuid}, null: false, default: [])
      add(:edm_provider_message_id, :text)
      add(:edm_delivered_at, :utc_datetime)
      add(:edm_error, :text)

      add(:edm_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:edm_org_id, :uuid, null: false)
      add(:edm_inserted_at, :utc_datetime, null: false)
      add(:edm_updated_at, :utc_datetime, null: false)
    end

    create(index(:edm_statement_delivery, [:edm_org_id]))
    create(index(:edm_statement_delivery, [:edm_org_id, :edm_customer_id]))
    create(unique_index(:edm_statement_delivery, [:edm_org_id, :edm_send_id]))

    create(
      constraint(:edm_statement_delivery, :edm_statement_delivery_amounts_nonnegative,
        check:
          "edm_invoiced_cents >= 0 AND edm_paid_cents >= 0 AND edm_credited_cents >= 0 AND " <>
            "edm_outstanding_cents >= 0 AND edm_unapplied_cents >= 0"
      )
    )

    create table(:ecc_collection_case, primary_key: false) do
      add(:ecc_customer_id, :uuid, null: false)
      add(:ecc_opened_on, :date, null: false)
      add(:ecc_currency, :text, null: false)
      add(:ecc_status, :text, null: false, default: "open")
      add(:ecc_stage, :text, null: false, default: "reminder")
      add(:ecc_next_action_on, :date)
      add(:ecc_last_contacted_at, :utc_datetime)
      add(:ecc_outstanding_cents, :bigint, null: false, default: 0)
      add(:ecc_invoice_count, :integer, null: false, default: 0)
      add(:ecc_promised_cents, :bigint)
      add(:ecc_promise_to_pay_on, :date)
      add(:ecc_notes, :text)
      add(:ecc_actions, :jsonb, null: false, default: "{}")

      add(:ecc_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:ecc_org_id, :uuid, null: false)
      add(:ecc_inserted_at, :utc_datetime, null: false)
      add(:ecc_updated_at, :utc_datetime, null: false)
    end

    create(index(:ecc_collection_case, [:ecc_org_id]))
    create(index(:ecc_collection_case, [:ecc_org_id, :ecc_customer_id]))
    create(index(:ecc_collection_case, [:ecc_org_id, :ecc_status]))

    create(
      unique_index(
        :ecc_collection_case,
        [:ecc_org_id, :ecc_customer_id, :ecc_currency],
        where: "ecc_status <> 'resolved'",
        name: :ecc_collection_case_active_unique
      )
    )

    create(
      constraint(:ecc_collection_case, :ecc_collection_case_amounts_nonnegative,
        check:
          "ecc_outstanding_cents >= 0 AND (ecc_promised_cents IS NULL OR ecc_promised_cents >= 0)"
      )
    )

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)
    drop(table(:ecc_collection_case))
    drop(table(:edm_statement_delivery))
  end
end
