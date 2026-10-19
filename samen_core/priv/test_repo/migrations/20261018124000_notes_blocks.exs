defmodule SamenCore.TestRepo.Migrations.NotesBlocks do
  @moduledoc """
  WS-Notes Phase 1 (ADR-053 §3) — the **block model** in the samen_core host, with the
  catalog written in the SAME transaction (ADR-004 catalog-in-tx).

    * `sdd_doc` gains the page-tree/ordinal columns — additive, nothing rewritten:
      `sdd_parent_doc_id` (the tree, same-org — R4's org half),
      `sdd_icon` (bounded token), `sdd_position` (integer ordinal among
      siblings, ADR-053 §8 O2) and `sdd_revision` (optimistic concurrency).
    * `sdb_doc_block` — one typed BLOCK row per page (ADR-053 §2 D2): `sdb_type` is a
      bounded enum and `sdb_metadata`/`sdb_checked` are validated against it by
      `Samen.Scopes.Docs.BlockShape` at the write boundary (the enum constraint alone
      cannot express "`language` only on `code`"). `sdb_position` is an integer
      ordinal scoped to `sdb_parent_block_id` and 🔒 `pii_sdb_text_secure` is the
      vaulted half of the per-block `text`/`text_secure` pair (`vault:
      :pii_block_text`) — block-level masking granularity, at the column level where
      the PII verifiers already look. Archivable (ADR-040 §5.9).
    * `sdl_doc_link` — one RESOLVED `[[Title]]` edge (ADR-053 §3): `sdl_source_doc_id` →
      `sdl_target_doc_id`, both same-org (`Samen.Policy.SameOrgFk`, R13), so a
      backlink is an indexed reverse query and a title in another org never resolves.
      Unique per `(source, target)`. Not archivable — a pure edge row.

  ## Abbrevs

  `sdb`/`sdl` are reserved through `mix samen.abbrev.reserve` under host
  `samen_core` (ADR-023) — never hand-edited into `priv/abbrev_registry.json`.

  ## Down

  `down/0` drops both new tables, drops the four added `sdd_doc` columns, and removes
  exactly the catalog rows this migration added (`catalog_sync_down(…, only: […])`
  for the additive columns, so nothing else in the table's entry is touched).
  """
  # An ADDITIVE (expand) migration: `down/0` is a clean round trip, so the tree
  # down-check exercises it in every host gate (`mix samen.verify.migrations`).
  use Samen.Migration, phase: :expand

  @doc_additions [:parent_doc_id, :icon, :position, :revision]
  @new_resources [SamenCore.Support.DocsFixture.DocBlock, SamenCore.Support.DocsFixture.DocLink]

  def up do
    alter table(:sdd_doc) do
      add(:sdd_parent_doc_id, :uuid)
      add(:sdd_icon, :text)
      add(:sdd_position, :bigint, null: false, default: 0)
      add(:sdd_revision, :bigint, null: false, default: 1)
    end

    create(index(:sdd_doc, [:sdd_parent_doc_id]))

    create table(:sdb_doc_block, primary_key: false) do
      add(:sdb_parent_block_id, :uuid)
      add(:sdb_position, :bigint, null: false, default: 0)
      add(:sdb_type, :text, null: false)
      add(:sdb_text, :text)
      add(:sdb_checked, :boolean)
      add(:sdb_metadata, :map, default: %{})
      add(:sdb_revision, :bigint, null: false, default: 1)
      add(:sdb_doc_id, :uuid, null: false)
      add(:pii_sdb_text_secure, :text)
      add(:sdb_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:sdb_org_id, :uuid, null: false)
      add(:sdb_inserted_at, :utc_datetime, null: false)
      add(:sdb_updated_at, :utc_datetime, null: false)
      add(:sdb_archived_at, :utc_datetime_usec)
    end

    create(index(:sdb_doc_block, [:sdb_org_id]))
    create(index(:sdb_doc_block, [:sdb_doc_id, :sdb_position]))
    create(index(:sdb_doc_block, [:sdb_parent_block_id]))

    create table(:sdl_doc_link, primary_key: false) do
      add(:sdl_anchor_text, :text, null: false)
      add(:sdl_source_doc_id, :uuid, null: false)
      add(:sdl_target_doc_id, :uuid, null: false)
      add(:sdl_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:sdl_org_id, :uuid, null: false)
      add(:sdl_inserted_at, :utc_datetime, null: false)
      add(:sdl_updated_at, :utc_datetime, null: false)
    end

    create(index(:sdl_doc_link, [:sdl_target_doc_id]))
    create(unique_index(:sdl_doc_link, [:sdl_source_doc_id, :sdl_target_doc_id]))

    catalog_sync([SamenCore.Support.DocsFixture.Doc], only: @doc_additions)
    catalog_sync(@new_resources)
  end

  def down do
    catalog_sync_down(@new_resources)
    catalog_sync_down([SamenCore.Support.DocsFixture.Doc], only: @doc_additions)

    drop(table(:sdl_doc_link))
    drop(table(:sdb_doc_block))

    alter table(:sdd_doc) do
      remove(:sdd_parent_doc_id)
      remove(:sdd_icon)
      remove(:sdd_position)
      remove(:sdd_revision)
    end
  end
end
