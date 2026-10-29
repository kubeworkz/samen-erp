defmodule Samenerp.Repo.Migrations.AddFinanceCostObjects do
  @moduledoc """
  WS-ACCT Phase 1 (ADR-054 D1/D2) — the cost-object seam on the REAL host
  (`Samenerp.Erp`, abbrevs `eco`/`ecl`).

  `eco_cost_object` is the registry the Kubeworkz cost-by-programme and
  cost-by-pool reads will name (Phase 2 seeds the four programmes and the cost
  pools as ordinary rows — the COA stays DATA, ADR-054 §0.3).
  `ecl_journal_line.ecl_dimension_refs` is the bounded jsonb seam itself.

  The dimension column is `null: false` with an empty-object default: every
  pre-existing posting was undimensioned by definition, and the empty map keeps
  the append-only line belt's INSERT policy unchanged for undimensioned
  postings. Posting-map widening (ADR-054 D2) is Ash-level only — the base
  `ecf_posting_account` table never carried a DB CHECK on `ecf_key`, so this
  migration moves no key DDL.

  Catalog rows via `catalog_sync/1,2` in the same transaction (ADR-004).
  """

  use Samen.Migration

  @resources [Samenerp.Erp.CostObject]

  def up do
    create table(:eco_cost_object, primary_key: false) do
      add(:eco_code, :text, null: false)
      add(:eco_name, :text, null: false)
      add(:eco_kind, :text, null: false)
      add(:eco_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:eco_org_id, :uuid, null: false)
      add(:eco_inserted_at, :utc_datetime, null: false)
      add(:eco_updated_at, :utc_datetime, null: false)
      add(:eco_archived_at, :utc_datetime_usec)
    end

    create(index(:eco_cost_object, [:eco_org_id]))
    create(unique_index(:eco_cost_object, [:eco_org_id, :eco_code]))

    alter table(:ecl_journal_line) do
      add(:ecl_dimension_refs, :map, null: false, default: %{})
    end

    catalog_sync(@resources)

    catalog_sync([Samenerp.Erp.JournalLine], only: [:dimension_refs])
  end

  def down do
    catalog_sync_down([Samenerp.Erp.JournalLine], only: [:dimension_refs])

    catalog_sync_down(@resources)

    alter table(:ecl_journal_line) do
      remove(:ecl_dimension_refs)
    end

    drop(table(:eco_cost_object))
  end
end
