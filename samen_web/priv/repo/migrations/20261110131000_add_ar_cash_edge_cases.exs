defmodule Samen.WebTest.Repo.Migrations.AddArCashEdgeCases do
  @moduledoc """
  AR cash edge cases on the `samen_web` test host.

  Mirrors the Finance fixture: receipts gain a customer owner and may be
  on-account (no invoice anchor); `fra_receipt_allocation` applies posted
  on-account cash to an invoice without touching the ledger.
  """

  use Samen.Migration

  @resources [Samen.WebTest.Erp.ReceiptAllocation]

  def up do
    alter table(:frr_payment_receipt) do
      add(:frr_customer_id, :uuid)
      modify(:frr_invoice_key, :text, null: true)
      modify(:frr_invoice_id, :uuid, null: true)
    end

    create(index(:frr_payment_receipt, [:frr_org_id, :frr_customer_id]))

    create table(:fra_receipt_allocation, primary_key: false) do
      add(:fra_receipt_id, :uuid, null: false)
      add(:fra_invoice_key, :text, null: false, default: "billing_invoice")
      add(:fra_invoice_id, :uuid, null: false)
      add(:fra_amount_cents, :bigint, null: false)
      add(:fra_currency, :text, null: false)
      add(:fra_applied_at, :utc_datetime, null: false)

      add(:fra_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:fra_org_id, :uuid, null: false)
      add(:fra_inserted_at, :utc_datetime, null: false)
      add(:fra_updated_at, :utc_datetime, null: false)
    end

    create(index(:fra_receipt_allocation, [:fra_org_id]))
    create(index(:fra_receipt_allocation, [:fra_receipt_id]))
    create(index(:fra_receipt_allocation, [:fra_invoice_id]))

    create(
      unique_index(:fra_receipt_allocation, [:fra_org_id, :fra_receipt_id, :fra_invoice_id],
        name: :fra_receipt_allocation_unique
      )
    )

    create(
      constraint(:fra_receipt_allocation, :fra_receipt_allocation_amount_positive,
        check: "fra_amount_cents > 0"
      )
    )

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)
    drop(table(:fra_receipt_allocation))

    alter table(:frr_payment_receipt) do
      remove(:frr_customer_id)
      modify(:frr_invoice_key, :text, null: false)
      modify(:frr_invoice_id, :uuid, null: false)
    end
  end
end
