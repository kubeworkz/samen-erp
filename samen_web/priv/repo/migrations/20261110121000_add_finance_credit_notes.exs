defmodule Samen.WebTest.Repo.Migrations.AddFinanceCreditNotes do
  @moduledoc """
  WS-ERP E12 — the AR/AP adjustment documents on the `samen_web` test host
  (`Samen.WebTest.Erp`, credit note `fcn`, vendor credit `fvc`). Same shape and
  DB belts as every other host mount:

    * `fcn_credit_note` — an AR adjustment (`:credit` or a direct `:write_off`)
      tied to the Billing invoice it reduces;
    * `fvc_vendor_credit` — the AP mirror tied to the approved bill it reduces.

  Catalog rows via `catalog_sync/1` in the same transaction (ADR-004).
  """

  use Samen.Migration

  @resources [
    Samen.WebTest.Erp.CreditNote,
    Samen.WebTest.Erp.VendorCredit
  ]

  def up do
    create table(:fcn_credit_note, primary_key: false) do
      add(:fcn_customer_id, :uuid, null: false)
      add(:fcn_number, :text, null: false)
      add(:fcn_date, :date, null: false)
      add(:fcn_due_date, :date)
      add(:fcn_currency, :text, null: false, default: "USD")
      add(:fcn_amount_cents, :bigint, null: false)
      add(:fcn_kind, :text, null: false, default: "credit")
      add(:fcn_status, :text, null: false, default: "draft")
      add(:fcn_memo, :text)
      add(:fcn_invoice_id, :uuid)
      add(:fcn_entry_id, :uuid)
      add(:fcn_posted_at, :utc_datetime)
      add(:fcn_applied_at, :utc_datetime)

      add(:fcn_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:fcn_org_id, :uuid, null: false)
      add(:fcn_inserted_at, :utc_datetime, null: false)
      add(:fcn_updated_at, :utc_datetime, null: false)
    end

    create(index(:fcn_credit_note, [:fcn_org_id]))
    create(index(:fcn_credit_note, [:fcn_customer_id]))
    create(index(:fcn_credit_note, [:fcn_invoice_id]))
    create(index(:fcn_credit_note, [:fcn_status]))

    create(
      unique_index(:fcn_credit_note, [:fcn_org_id, :fcn_number],
        name: :fcn_credit_note_number_unique
      )
    )

    create(
      constraint(:fcn_credit_note, :fcn_credit_note_amount_positive,
        check: "fcn_amount_cents > 0"
      )
    )

    create(
      constraint(:fcn_credit_note, :fcn_credit_note_kind_valid,
        check: "fcn_kind IN ('credit','write_off')"
      )
    )

    create(
      constraint(:fcn_credit_note, :fcn_credit_note_status_valid,
        check: "fcn_status IN ('draft','open','applied','void')"
      )
    )

    create table(:fvc_vendor_credit, primary_key: false) do
      add(:fvc_vendor_id, :uuid, null: false)
      add(:fvc_number, :text, null: false)
      add(:fvc_date, :date, null: false)
      add(:fvc_currency, :text, null: false, default: "USD")
      add(:fvc_amount_cents, :bigint, null: false)
      add(:fvc_status, :text, null: false, default: "draft")
      add(:fvc_memo, :text)
      add(:fvc_bill_id, :uuid)
      add(:fvc_entry_id, :uuid)
      add(:fvc_posted_at, :utc_datetime)
      add(:fvc_applied_at, :utc_datetime)

      add(:fvc_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:fvc_org_id, :uuid, null: false)
      add(:fvc_inserted_at, :utc_datetime, null: false)
      add(:fvc_updated_at, :utc_datetime, null: false)
    end

    create(index(:fvc_vendor_credit, [:fvc_org_id]))
    create(index(:fvc_vendor_credit, [:fvc_vendor_id]))
    create(index(:fvc_vendor_credit, [:fvc_bill_id]))
    create(index(:fvc_vendor_credit, [:fvc_status]))

    create(
      unique_index(:fvc_vendor_credit, [:fvc_org_id, :fvc_number],
        name: :fvc_vendor_credit_number_unique
      )
    )

    create(
      constraint(:fvc_vendor_credit, :fvc_vendor_credit_amount_positive,
        check: "fvc_amount_cents > 0"
      )
    )

    create(
      constraint(:fvc_vendor_credit, :fvc_vendor_credit_status_valid,
        check: "fvc_status IN ('draft','open','applied','void')")
    )

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)
    drop(table(:fvc_vendor_credit))
    drop(table(:fcn_credit_note))
  end
end
