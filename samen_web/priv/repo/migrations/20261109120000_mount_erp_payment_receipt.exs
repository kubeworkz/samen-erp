defmodule Samen.WebTest.Repo.Migrations.MountErpPaymentReceipt do
  @moduledoc """
  Tabled the Finance scope's AR cash intake (`Samen.WebTest.Erp.PaymentReceipt`)
  in the `samen_web` test host.

  The original ERP mount (`20261003090000_mount_erp_scope.exs`) tabled only the
  resources the six generic surfaces read. The AR aging / statements page
  (`/erp/ar-aging`) joins POSTED receipts against Billing invoices, so the
  receipt table is now part of the host's real read path and must exist here
  exactly as it does on a deployed host — the mount already lists the resource,
  only its table was missing.

  No belt triggers, matching the rest of this host: the web LiveView tests
  exercise the ASH-level guards the UI path actually rides (`ArAging` only
  reads; receipts are written by the Finance scope, never by this page).
  """
  use Samen.Migration

  def up do
    create table(:frr_payment_receipt, primary_key: false) do
      add(:frr_invoice_key, :text, null: false)
      add(:frr_invoice_id, :uuid, null: false)
      add(:frr_amount_cents, :bigint, null: false)
      add(:frr_currency, :text, null: false, default: "USD")
      add(:frr_paid_at, :utc_datetime, null: false)
      add(:frr_memo, :text)
      add(:frr_status, :text, null: false, default: "draft")
      add(:frr_posted_entry_id, :uuid)
      add(:frr_posted_at, :utc_datetime)
      add(:frr_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:frr_org_id, :uuid, null: false)
      add(:frr_inserted_at, :utc_datetime, null: false)
      add(:frr_updated_at, :utc_datetime, null: false)
    end

    create(index(:frr_payment_receipt, [:frr_org_id]))

    create(index(:frr_payment_receipt, [:frr_org_id, :frr_invoice_key, :frr_invoice_id]))

    create(
      constraint(:frr_payment_receipt, :frr_status_valid,
        check: "frr_status IN ('draft','posted')"
      )
    )

    create(constraint(:frr_payment_receipt, :frr_amount_positive, check: "frr_amount_cents > 0"))
  end

  def down do
    drop(table(:frr_payment_receipt))
  end
end
