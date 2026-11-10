defmodule Samenerp.Repo.Migrations.AddApThreeWayMatch do
  @moduledoc "Gap #9 — the AP bill's three-way-match tolerance."
  use Samen.Migration

  @resources [Samenerp.Erp.ApInvoice]

  def up do
    alter table(:ecp_ap_invoice) do
      add(:ecp_match_tolerance_cents, :bigint, null: false, default: 0)
      add(:ecp_match_tolerance_pct, :integer, null: false, default: 0)
    end

    execute(
      """
      ALTER TABLE ecp_ap_invoice
        ADD CONSTRAINT ecp_match_tolerance_non_negative
        CHECK (ecp_match_tolerance_cents >= 0 AND ecp_match_tolerance_pct BETWEEN 0 AND 100)
      """,
      "ALTER TABLE ecp_ap_invoice DROP CONSTRAINT ecp_match_tolerance_non_negative"
    )

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    alter table(:ecp_ap_invoice) do
      remove(:ecp_match_tolerance_cents)
      remove(:ecp_match_tolerance_pct)
    end
  end
end
