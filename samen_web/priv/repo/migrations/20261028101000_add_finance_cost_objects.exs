defmodule Samen.WebTest.Repo.Migrations.AddFinanceCostObjects do
  @moduledoc """
  WS-ACCT Phase 1 (ADR-054 D1/D2) — the cost-object seam in the `samen_web`
  test host (`Samen.WebTest.Erp`, scope-DEFAULT abbrevs `fco`/`fjl`).

  `fco_cost_object` + `fjl_journal_line.fjl_dimension_refs`, exactly as the
  `samen_core` fixture migration does it. The `samen_web` ERP mount is a
  deliberate SUBSET of the scope (only the tables the `Samen.Web.Erp` surfaces
  read/write), and this keeps the subset honest: a journal line written through
  the web surfaces carries the dimension column its resource declares, and the
  line's `DimensionGuard` can resolve a cost object when one is named.

  No belt triggers here (the samen_web mount posture — the web tests exercise
  the Ash-level guards the UI path rides).
  """

  use Samen.Migration

  @resources [Samen.WebTest.Erp.CostObject]

  def up do
    create table(:fco_cost_object, primary_key: false) do
      add(:fco_code, :text, null: false)
      add(:fco_name, :text, null: false)
      add(:fco_kind, :text, null: false)
      add(:fco_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:fco_org_id, :uuid, null: false)
      add(:fco_inserted_at, :utc_datetime, null: false)
      add(:fco_updated_at, :utc_datetime, null: false)
      add(:fco_archived_at, :utc_datetime_usec)
    end

    create(index(:fco_cost_object, [:fco_org_id]))
    create(unique_index(:fco_cost_object, [:fco_org_id, :fco_code]))

    alter table(:fjl_journal_line) do
      add(:fjl_dimension_refs, :map, null: false, default: %{})
    end

    catalog_sync(@resources)

    catalog_sync([Samen.WebTest.Erp.JournalLine], only: [:dimension_refs])
  end

  def down do
    catalog_sync_down([Samen.WebTest.Erp.JournalLine], only: [:dimension_refs])

    catalog_sync_down(@resources)

    alter table(:fjl_journal_line) do
      remove(:fjl_dimension_refs)
    end

    drop(table(:fco_cost_object))
  end
end
