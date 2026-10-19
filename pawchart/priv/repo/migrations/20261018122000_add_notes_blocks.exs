defmodule PawChart.Repo.Migrations.AddNotesBlocks do
  @moduledoc """
  WS-Notes Phase 1 (ADR-053 §3) — the **block model** in the pawchart host, with the
  catalog written in the SAME transaction (ADR-004 catalog-in-tx).

    * `pdd_doc` gains the page-tree/ordinal columns — additive, nothing rewritten:
      `pdd_parent_doc_id` (the tree, same-org — R4's org half),
      `pdd_icon` (bounded token), `pdd_position` (integer ordinal among
      siblings, ADR-053 §8 O2) and `pdd_revision` (optimistic concurrency).
    * `pdb_doc_block` — one typed BLOCK row per page (ADR-053 §2 D2): `pdb_type` is a
      bounded enum and `pdb_metadata`/`pdb_checked` are validated against it by
      `Samen.Scopes.Docs.BlockShape` at the write boundary (the enum constraint alone
      cannot express "`language` only on `code`"). `pdb_position` is an integer
      ordinal scoped to `pdb_parent_block_id` and 🔒 `pii_pdb_text_secure` is the
      vaulted half of the per-block `text`/`text_secure` pair (`vault:
      :pii_block_text`) — block-level masking granularity, at the column level where
      the PII verifiers already look. Archivable (ADR-040 §5.9).
    * `pdl_doc_link` — one RESOLVED `[[Title]]` edge (ADR-053 §3): `pdl_source_doc_id` →
      `pdl_target_doc_id`, both same-org (`Samen.Policy.SameOrgFk`, R13), so a
      backlink is an indexed reverse query and a title in another org never resolves.
      Unique per `(source, target)`. Not archivable — a pure edge row.

  ## Abbrevs

  `pdb`/`pdl` are reserved through `mix samen.abbrev.reserve` under host
  `pawchart` (ADR-023) — never hand-edited into `priv/abbrev_registry.json`.

  ## Down

  `down/0` drops both new tables, drops the four added `pdd_doc` columns, and removes
  exactly the catalog rows this migration added (`catalog_sync_down(…, only: […])`
  for the additive columns, so nothing else in the table's entry is touched).
  """
  # An ADDITIVE (expand) migration: `down/0` is a clean round trip, so the tree
  # down-check exercises it in every host gate (`mix samen.verify.migrations`).
  use Samen.Migration, phase: :expand

  @doc_additions [:parent_doc_id, :icon, :position, :revision]
  @new_resources [PawChart.Docs.DocBlock, PawChart.Docs.DocLink]

  def up do
    alter table(:pdd_doc) do
      add(:pdd_parent_doc_id, :uuid)
      add(:pdd_icon, :text)
      add(:pdd_position, :bigint, null: false, default: 0)
      add(:pdd_revision, :bigint, null: false, default: 1)
    end

    create(index(:pdd_doc, [:pdd_parent_doc_id]))

    create table(:pdb_doc_block, primary_key: false) do
      add(:pdb_parent_block_id, :uuid)
      add(:pdb_position, :bigint, null: false, default: 0)
      add(:pdb_type, :text, null: false)
      add(:pdb_text, :text)
      add(:pdb_checked, :boolean)
      add(:pdb_metadata, :map, default: %{})
      add(:pdb_revision, :bigint, null: false, default: 1)
      add(:pdb_doc_id, :uuid, null: false)
      add(:pii_pdb_text_secure, :text)
      add(:pdb_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:pdb_org_id, :uuid, null: false)
      add(:pdb_inserted_at, :utc_datetime, null: false)
      add(:pdb_updated_at, :utc_datetime, null: false)
      add(:pdb_archived_at, :utc_datetime_usec)
    end

    create(index(:pdb_doc_block, [:pdb_org_id]))
    create(index(:pdb_doc_block, [:pdb_doc_id, :pdb_position]))
    create(index(:pdb_doc_block, [:pdb_parent_block_id]))

    create table(:pdl_doc_link, primary_key: false) do
      add(:pdl_anchor_text, :text, null: false)
      add(:pdl_source_doc_id, :uuid, null: false)
      add(:pdl_target_doc_id, :uuid, null: false)
      add(:pdl_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:pdl_org_id, :uuid, null: false)
      add(:pdl_inserted_at, :utc_datetime, null: false)
      add(:pdl_updated_at, :utc_datetime, null: false)
    end

    create(index(:pdl_doc_link, [:pdl_target_doc_id]))
    create(unique_index(:pdl_doc_link, [:pdl_source_doc_id, :pdl_target_doc_id]))

    catalog_sync([PawChart.Docs.Doc], only: @doc_additions)
    catalog_sync(@new_resources)
  end

  def down do
    catalog_sync_down(@new_resources)
    catalog_sync_down([PawChart.Docs.Doc], only: @doc_additions)

    drop(table(:pdl_doc_link))
    drop(table(:pdb_doc_block))

    alter table(:pdd_doc) do
      remove(:pdd_parent_doc_id)
      remove(:pdd_icon)
      remove(:pdd_position)
      remove(:pdd_revision)
    end
  end
end
