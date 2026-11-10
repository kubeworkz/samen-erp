defmodule SamenCore.TestRepo.Migrations.AddApThreeWayMatch do
  @moduledoc """
  Gap #9 — the AP bill's three-way-match tolerance.

  Tolerance is a BILL-level policy because the bill is the negotiated document;
  every reference-bearing line uses it. Zero is the fail-honest default.
  """
  use Samen.Migration

  @resources [SamenCore.Support.FinanceFixture.ApInvoice]

  def up do
    alter table(:sap_ap_invoice) do
      add(:sap_match_tolerance_cents, :bigint, null: false, default: 0)
      add(:sap_match_tolerance_pct, :integer, null: false, default: 0)
    end

    execute(
      """
      ALTER TABLE sap_ap_invoice
        ADD CONSTRAINT sap_match_tolerance_non_negative
        CHECK (sap_match_tolerance_cents >= 0 AND sap_match_tolerance_pct BETWEEN 0 AND 100)
      """,
      "ALTER TABLE sap_ap_invoice DROP CONSTRAINT sap_match_tolerance_non_negative"
    )

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    alter table(:sap_ap_invoice) do
      remove(:sap_match_tolerance_cents)
      remove(:sap_match_tolerance_pct)
    end
  end
end
