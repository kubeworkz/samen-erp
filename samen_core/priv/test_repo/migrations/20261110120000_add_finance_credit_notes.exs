defmodule SamenCore.TestRepo.Migrations.AddFinanceCreditNotes do
  @moduledoc """
  WS-ERP E12 — the AR/AP adjustment documents in the `samen_core` fixture
  (`SamenCore.Support.FinanceFixture`, credit note `sdc`, vendor credit `sdv`).

  A credit note is an AR adjustment (`:credit` or a direct `:write_off`); a
  vendor credit is its AP mirror. Both carry a target reference, a governed
  status, the posting entry anchor and the posting/applied timestamps. The
  ledger entry is the fact; these rows are the document lifecycle around it.

  Catalog rows via `catalog_sync/1` in the same transaction (ADR-004).
  """

  use Samen.Migration

  @resources [
    SamenCore.Support.FinanceFixture.CreditNote,
    SamenCore.Support.FinanceFixture.VendorCredit
  ]

  def up do
    create table(:sdc_credit_note, primary_key: false) do
      add(:sdc_customer_id, :uuid, null: false)
      add(:sdc_number, :text, null: false)
      add(:sdc_date, :date, null: false)
      add(:sdc_due_date, :date)
      add(:sdc_currency, :text, null: false, default: "USD")
      add(:sdc_amount_cents, :bigint, null: false)
      add(:sdc_kind, :text, null: false, default: "credit")
      add(:sdc_status, :text, null: false, default: "draft")
      add(:sdc_memo, :text)
      add(:sdc_invoice_id, :uuid)
      add(:sdc_entry_id, :uuid)
      add(:sdc_posted_at, :utc_datetime)
      add(:sdc_applied_at, :utc_datetime)

      add(:sdc_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:sdc_org_id, :uuid, null: false)
      add(:sdc_inserted_at, :utc_datetime, null: false)
      add(:sdc_updated_at, :utc_datetime, null: false)
    end

    create(index(:sdc_credit_note, [:sdc_org_id]))
    create(index(:sdc_credit_note, [:sdc_customer_id]))
    create(index(:sdc_credit_note, [:sdc_invoice_id]))
    create(index(:sdc_credit_note, [:sdc_status]))

    create(
      unique_index(:sdc_credit_note, [:sdc_org_id, :sdc_number],
        name: :sdc_credit_note_number_unique
      )
    )

    create(
      constraint(:sdc_credit_note, :sdc_credit_note_amount_positive,
        check: "sdc_amount_cents > 0"
      )
    )

    create(
      constraint(:sdc_credit_note, :sdc_credit_note_kind_valid,
        check: "sdc_kind IN ('credit','write_off')"
      )
    )

    create(
      constraint(:sdc_credit_note, :sdc_credit_note_status_valid,
        check: "sdc_status IN ('draft','open','applied','void')"
      )
    )

    create table(:sdv_vendor_credit, primary_key: false) do
      add(:sdv_vendor_id, :uuid, null: false)
      add(:sdv_number, :text, null: false)
      add(:sdv_date, :date, null: false)
      add(:sdv_currency, :text, null: false, default: "USD")
      add(:sdv_amount_cents, :bigint, null: false)
      add(:sdv_status, :text, null: false, default: "draft")
      add(:sdv_memo, :text)
      add(:sdv_bill_id, :uuid)
      add(:sdv_entry_id, :uuid)
      add(:sdv_posted_at, :utc_datetime)
      add(:sdv_applied_at, :utc_datetime)

      add(:sdv_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:sdv_org_id, :uuid, null: false)
      add(:sdv_inserted_at, :utc_datetime, null: false)
      add(:sdv_updated_at, :utc_datetime, null: false)
    end

    create(index(:sdv_vendor_credit, [:sdv_org_id]))
    create(index(:sdv_vendor_credit, [:sdv_vendor_id]))
    create(index(:sdv_vendor_credit, [:sdv_bill_id]))
    create(index(:sdv_vendor_credit, [:sdv_status]))

    create(
      unique_index(:sdv_vendor_credit, [:sdv_org_id, :sdv_number],
        name: :sdv_vendor_credit_number_unique
      )
    )

    create(
      constraint(:sdv_vendor_credit, :sdv_vendor_credit_amount_positive,
        check: "sdv_amount_cents > 0"
      )
    )

    create(
      constraint(:sdv_vendor_credit, :sdv_vendor_credit_status_valid,
        check: "sdv_status IN ('draft','open','applied','void')"
      )
    )

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)
    drop(table(:sdv_vendor_credit))
    drop(table(:sdc_credit_note))
  end
end
