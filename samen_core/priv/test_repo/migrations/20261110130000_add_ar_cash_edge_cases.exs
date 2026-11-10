defmodule SamenCore.TestRepo.Migrations.AddArCashEdgeCases do
  @moduledoc """
  AR cash edge cases in the `samen_core` Finance fixture.

  `prc_payment_receipt` becomes a customer cash intake: `customer_id` is the
  required owner of every new receipt, and an on-account receipt carries no
  invoice anchor. `sra_receipt_allocation` applies a posted on-account receipt
  to an invoice without a second journal entry.
  """

  use Samen.Migration

  @resources [SamenCore.Support.FinanceFixture.ReceiptAllocation]

  def up do
    alter table(:prc_payment_receipt) do
      add(:prc_customer_id, :uuid)
      modify(:prc_invoice_key, :text, null: true)
      modify(:prc_invoice_id, :uuid, null: true)
    end

    create(index(:prc_payment_receipt, [:prc_org_id, :prc_customer_id]))

    create table(:sra_receipt_allocation, primary_key: false) do
      add(:sra_receipt_id, :uuid, null: false)
      add(:sra_invoice_key, :text, null: false, default: "billing_invoice")
      add(:sra_invoice_id, :uuid, null: false)
      add(:sra_amount_cents, :bigint, null: false)
      add(:sra_currency, :text, null: false)
      add(:sra_applied_at, :utc_datetime, null: false)

      add(:sra_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:sra_org_id, :uuid, null: false)
      add(:sra_inserted_at, :utc_datetime, null: false)
      add(:sra_updated_at, :utc_datetime, null: false)
    end

    create(index(:sra_receipt_allocation, [:sra_org_id]))
    create(index(:sra_receipt_allocation, [:sra_receipt_id]))
    create(index(:sra_receipt_allocation, [:sra_invoice_id]))

    create(
      unique_index(:sra_receipt_allocation, [:sra_org_id, :sra_receipt_id, :sra_invoice_id],
        name: :sra_receipt_allocation_unique
      )
    )

    create(
      constraint(:sra_receipt_allocation, :sra_receipt_allocation_amount_positive,
        check: "sra_amount_cents > 0"
      )
    )

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)
    drop(table(:sra_receipt_allocation))

    alter table(:prc_payment_receipt) do
      remove(:prc_customer_id)
      modify(:prc_invoice_key, :text, null: false)
      modify(:prc_invoice_id, :uuid, null: false)
    end
  end
end
