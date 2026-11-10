defmodule Samen.WebTest.Repo.Migrations.AddApThreeWayMatch do
  @moduledoc "Gap #9 — the AP bill's three-way-match tolerance."
  use Samen.Migration

  @resources [Samen.WebTest.Erp.ApInvoice]

  def up do
    alter table(:fai_ap_invoice) do
      add(:fai_match_tolerance_cents, :bigint, null: false, default: 0)
      add(:fai_match_tolerance_pct, :integer, null: false, default: 0)
    end

    execute(
      """
      ALTER TABLE fai_ap_invoice
        ADD CONSTRAINT fai_match_tolerance_non_negative
        CHECK (fai_match_tolerance_cents >= 0 AND fai_match_tolerance_pct BETWEEN 0 AND 100)
      """,
      "ALTER TABLE fai_ap_invoice DROP CONSTRAINT fai_match_tolerance_non_negative"
    )

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    alter table(:fai_ap_invoice) do
      remove(:fai_match_tolerance_cents)
      remove(:fai_match_tolerance_pct)
    end
  end
end
