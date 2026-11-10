defmodule Samenerp.Repo.Migrations.AddFinanceCreditNotes do
  @moduledoc """
  WS-ERP E12 — the AR/AP adjustment documents on the Kubeworkz books
  (`Samenerp.Erp`, credit note `ecn`, vendor credit `evc`).

  A credit note reduces AR against the host's Billing invoice; a vendor credit
  reduces an approved AP bill. The posting entries are the ledger facts and the
  rows here carry the document lifecycle, target reference and entry anchors.

  Catalog rows via `catalog_sync/1` in the same transaction (ADR-004).
  """

  use Samen.Migration

  @resources [
    Samenerp.Erp.CreditNote,
    Samenerp.Erp.VendorCredit
  ]

  def up do
    create table(:ecn_credit_note, primary_key: false) do
      add(:ecn_customer_id, :uuid, null: false)
      add(:ecn_number, :text, null: false)
      add(:ecn_date, :date, null: false)
      add(:ecn_due_date, :date)
      add(:ecn_currency, :text, null: false, default: "USD")
      add(:ecn_amount_cents, :bigint, null: false)
      add(:ecn_kind, :text, null: false, default: "credit")
      add(:ecn_status, :text, null: false, default: "draft")
      add(:ecn_memo, :text)
      add(:ecn_invoice_id, :uuid)
      add(:ecn_entry_id, :uuid)
      add(:ecn_posted_at, :utc_datetime)
      add(:ecn_applied_at, :utc_datetime)

      add(:ecn_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:ecn_org_id, :uuid, null: false)
      add(:ecn_inserted_at, :utc_datetime, null: false)
      add(:ecn_updated_at, :utc_datetime, null: false)
    end

    create(index(:ecn_credit_note, [:ecn_org_id]))
    create(index(:ecn_credit_note, [:ecn_customer_id]))
    create(index(:ecn_credit_note, [:ecn_invoice_id]))
    create(index(:ecn_credit_note, [:ecn_status]))

    create(
      unique_index(:ecn_credit_note, [:ecn_org_id, :ecn_number],
        name: :ecn_credit_note_number_unique
      )
    )

    create(
      constraint(:ecn_credit_note, :ecn_credit_note_amount_positive,
        check: "ecn_amount_cents > 0"
      )
    )

    create(
      constraint(:ecn_credit_note, :ecn_credit_note_kind_valid,
        check: "ecn_kind IN ('credit','write_off')"
      )
    )

    create(
      constraint(:ecn_credit_note, :ecn_credit_note_status_valid,
        check: "ecn_status IN ('draft','open','applied','void')"
      )
    )

    create table(:evc_vendor_credit, primary_key: false) do
      add(:evc_vendor_id, :uuid, null: false)
      add(:evc_number, :text, null: false)
      add(:evc_date, :date, null: false)
      add(:evc_currency, :text, null: false, default: "USD")
      add(:evc_amount_cents, :bigint, null: false)
      add(:evc_status, :text, null: false, default: "draft")
      add(:evc_memo, :text)
      add(:evc_bill_id, :uuid)
      add(:evc_entry_id, :uuid)
      add(:evc_posted_at, :utc_datetime)
      add(:evc_applied_at, :utc_datetime)

      add(:evc_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:evc_org_id, :uuid, null: false)
      add(:evc_inserted_at, :utc_datetime, null: false)
      add(:evc_updated_at, :utc_datetime, null: false)
    end

    create(index(:evc_vendor_credit, [:evc_org_id]))
    create(index(:evc_vendor_credit, [:evc_vendor_id]))
    create(index(:evc_vendor_credit, [:evc_bill_id]))
    create(index(:evc_vendor_credit, [:evc_status]))

    create(
      unique_index(:evc_vendor_credit, [:evc_org_id, :evc_number],
        name: :evc_vendor_credit_number_unique
      )
    )

    create(
      constraint(:evc_vendor_credit, :evc_vendor_credit_amount_positive,
        check: "evc_amount_cents > 0"
      )
    )

    create(
      constraint(:evc_vendor_credit, :evc_vendor_credit_status_valid,
        check: "evc_status IN ('draft','open','applied','void')")
    )

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)
    drop(table(:evc_vendor_credit))
    drop(table(:ecn_credit_note))
  end
end
