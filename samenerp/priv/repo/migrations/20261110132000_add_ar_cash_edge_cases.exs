defmodule Samenerp.Repo.Migrations.AddArCashEdgeCases do
  @moduledoc """
  AR cash edge cases on the Kubeworkz books.

  `ecr_payment_receipt` gains the customer owner and may hold on-account cash
  without an invoice anchor. `eaa_receipt_allocation` applies posted on-account
  cash to an invoice without a second ledger entry.
  """

  use Samen.Migration

  @resources [Samenerp.Erp.ReceiptAllocation]

  def up do
    alter table(:ecr_payment_receipt) do
      add(:ecr_customer_id, :uuid)
      modify(:ecr_invoice_key, :text, null: true)
      modify(:ecr_invoice_id, :uuid, null: true)
    end

    create(index(:ecr_payment_receipt, [:ecr_org_id, :ecr_customer_id]))

    create table(:eaa_receipt_allocation, primary_key: false) do
      add(:eaa_receipt_id, :uuid, null: false)
      add(:eaa_invoice_key, :text, null: false, default: "billing_invoice")
      add(:eaa_invoice_id, :uuid, null: false)
      add(:eaa_amount_cents, :bigint, null: false)
      add(:eaa_currency, :text, null: false)
      add(:eaa_applied_at, :utc_datetime, null: false)

      add(:eaa_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:eaa_org_id, :uuid, null: false)
      add(:eaa_inserted_at, :utc_datetime, null: false)
      add(:eaa_updated_at, :utc_datetime, null: false)
    end

    create(index(:eaa_receipt_allocation, [:eaa_org_id]))
    create(index(:eaa_receipt_allocation, [:eaa_receipt_id]))
    create(index(:eaa_receipt_allocation, [:eaa_invoice_id]))

    create(
      unique_index(:eaa_receipt_allocation, [:eaa_org_id, :eaa_receipt_id, :eaa_invoice_id],
        name: :eaa_receipt_allocation_unique
      )
    )

    create(
      constraint(:eaa_receipt_allocation, :eaa_receipt_allocation_amount_positive,
        check: "eaa_amount_cents > 0"
      )
    )

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)
    drop(table(:eaa_receipt_allocation))

    alter table(:ecr_payment_receipt) do
      remove(:ecr_customer_id)
      modify(:ecr_invoice_key, :text, null: false)
      modify(:ecr_invoice_id, :uuid, null: false)
    end
  end
end
