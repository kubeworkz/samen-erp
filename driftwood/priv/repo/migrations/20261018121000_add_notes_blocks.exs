defmodule Driftwood.Repo.Migrations.AddNotesBlocks do
  @moduledoc """
  WS-Notes Phase 1 (ADR-053 §3) — the **block model** in the driftwood host, with the
  catalog written in the SAME transaction (ADR-004 catalog-in-tx).

    * `fdd_doc` gains the page-tree/ordinal columns — additive, nothing rewritten:
      `fdd_parent_doc_id` (the tree, same-org — R4's org half),
      `fdd_icon` (bounded token), `fdd_position` (integer ordinal among
      siblings, ADR-053 §8 O2) and `fdd_revision` (optimistic concurrency).
    * `fdb_doc_block` — one typed BLOCK row per page (ADR-053 §2 D2): `fdb_type` is a
      bounded enum and `fdb_metadata`/`fdb_checked` are validated against it by
      `Samen.Scopes.Docs.BlockShape` at the write boundary (the enum constraint alone
      cannot express "`language` only on `code`"). `fdb_position` is an integer
      ordinal scoped to `fdb_parent_block_id` and 🔒 `pii_fdb_text_secure` is the
      vaulted half of the per-block `text`/`text_secure` pair (`vault:
      :pii_block_text`) — block-level masking granularity, at the column level where
      the PII verifiers already look. Archivable (ADR-040 §5.9).
    * `fdl_doc_link` — one RESOLVED `[[Title]]` edge (ADR-053 §3): `fdl_source_doc_id` →
      `fdl_target_doc_id`, both same-org (`Samen.Policy.SameOrgFk`, R13), so a
      backlink is an indexed reverse query and a title in another org never resolves.
      Unique per `(source, target)`. Not archivable — a pure edge row.

  ## Abbrevs

  `fdb`/`fdl` are reserved through `mix samen.abbrev.reserve` under host
  `driftwood` (ADR-023) — never hand-edited into `priv/abbrev_registry.json`.

  ## Down

  `down/0` drops both new tables, drops the four added `fdd_doc` columns, and removes
  exactly the catalog rows this migration added (`catalog_sync_down(…, only: […])`
  for the additive columns, so nothing else in the table's entry is touched).
  """
  # An ADDITIVE (expand) migration: `down/0` is a clean round trip, so the tree
  # down-check exercises it in every host gate (`mix samen.verify.migrations`).
  use Samen.Migration, phase: :expand

  @doc_additions [:parent_doc_id, :icon, :position, :revision]
  @new_resources [Driftwood.Docs.DocBlock, Driftwood.Docs.DocLink]

  def up do
    alter table(:fdd_doc) do
      add(:fdd_parent_doc_id, :uuid)
      add(:fdd_icon, :text)
      add(:fdd_position, :bigint, null: false, default: 0)
      add(:fdd_revision, :bigint, null: false, default: 1)
    end

    create(index(:fdd_doc, [:fdd_parent_doc_id]))

    create table(:fdb_doc_block, primary_key: false) do
      add(:fdb_parent_block_id, :uuid)
      add(:fdb_position, :bigint, null: false, default: 0)
      add(:fdb_type, :text, null: false)
      add(:fdb_text, :text)
      add(:fdb_checked, :boolean)
      add(:fdb_metadata, :map, default: %{})
      add(:fdb_revision, :bigint, null: false, default: 1)
      add(:fdb_doc_id, :uuid, null: false)
      add(:pii_fdb_text_secure, :text)
      add(:fdb_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:fdb_org_id, :uuid, null: false)
      add(:fdb_inserted_at, :utc_datetime, null: false)
      add(:fdb_updated_at, :utc_datetime, null: false)
      add(:fdb_archived_at, :utc_datetime_usec)
    end

    create(index(:fdb_doc_block, [:fdb_org_id]))
    create(index(:fdb_doc_block, [:fdb_doc_id, :fdb_position]))
    create(index(:fdb_doc_block, [:fdb_parent_block_id]))

    create table(:fdl_doc_link, primary_key: false) do
      add(:fdl_anchor_text, :text, null: false)
      add(:fdl_source_doc_id, :uuid, null: false)
      add(:fdl_target_doc_id, :uuid, null: false)
      add(:fdl_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:fdl_org_id, :uuid, null: false)
      add(:fdl_inserted_at, :utc_datetime, null: false)
      add(:fdl_updated_at, :utc_datetime, null: false)
    end

    create(index(:fdl_doc_link, [:fdl_target_doc_id]))
    create(unique_index(:fdl_doc_link, [:fdl_source_doc_id, :fdl_target_doc_id]))

    catalog_sync([Driftwood.Docs.Doc], only: @doc_additions)
    catalog_sync(@new_resources)
  end

  def down do
    catalog_sync_down(@new_resources)
    catalog_sync_down([Driftwood.Docs.Doc], only: @doc_additions)

    drop(table(:fdl_doc_link))
    drop(table(:fdb_doc_block))

    alter table(:fdd_doc) do
      remove(:fdd_parent_doc_id)
      remove(:fdd_icon)
      remove(:fdd_position)
      remove(:fdd_revision)
    end
  end
end
