defmodule Samen.WebTest.Repo.Migrations.AddErpReceiptAnchorUnique do
  @moduledoc """
  The AR receipt intake now writes POSTED receipts from the `samen_web` host, so
  this host carries the same exactly-once anchor a deployed Finance mount has:
  at most one POSTED receipt per `{org, invoice_key, invoice_id}`. Draft rows
  remain unconstrained.
  """
  use Samen.Migration

  def up do
    execute("""
    CREATE UNIQUE INDEX prc_anchor_unique
    ON frr_payment_receipt (frr_org_id, frr_invoice_key, frr_invoice_id)
    WHERE frr_status = 'posted'
    """)
  end

  def down do
    execute("DROP INDEX IF EXISTS prc_anchor_unique")
  end
end
