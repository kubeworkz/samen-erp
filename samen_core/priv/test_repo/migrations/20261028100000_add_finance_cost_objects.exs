defmodule SamenCore.TestRepo.Migrations.AddFinanceCostObjects do
  @moduledoc """
  WS-ACCT Phase 1 (ADR-054 D1/D2) — the cost-object seam, in the `samen_core`
  test fixture (`SamenCore.Support.FinanceFixture`, abbrevs `cob`/`sjl`):

    * `cob_cost_object` — the cost/analysis registry: `code` (unique per org),
      `name`, `kind ∈ {project, chip, cost_pool, fund}`, archivable. A retired
      cost object is archived, never deleted (posted lines name it forever).
    * `sjl_journal_line.sjl_dimension_refs` — the bounded jsonb seam: axis =>
      same-org cost-object id, validated by
      `Samen.Scopes.Finance.DimensionGuard` and balanced per cost object by
      `Samen.Scopes.Finance.DimensionBalance` (R6).

  The column is `null: false` with an empty-object default so the append-only
  line belt's INSERT policy is unchanged for undimensioned postings, and so the
  pre-existing rows (there are none in a fresh fixture) could not be NULL. The
  posting map's widened `key` enum is an Ash-level constraint only: the base
  table never carried a DB CHECK on `fav_key`, so no DDL moves for ADR-054 D2.

  Catalog rows are written by `catalog_sync/1,2` in the SAME transaction
  (ADR-004) — the new resource in full, and ONLY the new column on the
  already-catalogued `JournalLine`.
  """

  use Samen.Migration

  @resources [SamenCore.Support.FinanceFixture.CostObject]

  def up do
    create table(:cob_cost_object, primary_key: false) do
      add(:cob_code, :text, null: false)
      add(:cob_name, :text, null: false)
      add(:cob_kind, :text, null: false)
      add(:cob_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:cob_org_id, :uuid, null: false)
      add(:cob_inserted_at, :utc_datetime, null: false)
      add(:cob_updated_at, :utc_datetime, null: false)
      add(:cob_archived_at, :utc_datetime_usec)
    end

    create(index(:cob_cost_object, [:cob_org_id]))
    create(unique_index(:cob_cost_object, [:cob_org_id, :cob_code]))

    alter table(:sjl_journal_line) do
      add(:sjl_dimension_refs, :map, null: false, default: %{})
    end

    catalog_sync(@resources)

    catalog_sync([SamenCore.Support.FinanceFixture.JournalLine], only: [:dimension_refs])
  end

  def down do
    catalog_sync_down([SamenCore.Support.FinanceFixture.JournalLine], only: [:dimension_refs])

    catalog_sync_down(@resources)

    alter table(:sjl_journal_line) do
      remove(:sjl_dimension_refs)
    end

    drop(table(:cob_cost_object))
  end
end
