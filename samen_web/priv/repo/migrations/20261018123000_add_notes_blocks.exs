defmodule Samen.WebTest.Repo.Migrations.AddNotesBlocks do
  @moduledoc """
  WS-Notes Phase 1 (ADR-053 §3) — the **block model** in the samen_web host, with the
  catalog written in the SAME transaction (ADR-004 catalog-in-tx).

    * `wdd_doc` gains the page-tree/ordinal columns — additive, nothing rewritten:
      `wdd_parent_doc_id` (the tree, same-org — R4's org half),
      `wdd_icon` (bounded token), `wdd_position` (integer ordinal among
      siblings, ADR-053 §8 O2) and `wdd_revision` (optimistic concurrency).
    * `wdb_doc_block` — one typed BLOCK row per page (ADR-053 §2 D2): `wdb_type` is a
      bounded enum and `wdb_metadata`/`wdb_checked` are validated against it by
      `Samen.Scopes.Docs.BlockShape` at the write boundary (the enum constraint alone
      cannot express "`language` only on `code`"). `wdb_position` is an integer
      ordinal scoped to `wdb_parent_block_id` and 🔒 `pii_wdb_text_secure` is the
      vaulted half of the per-block `text`/`text_secure` pair (`vault:
      :pii_block_text`) — block-level masking granularity, at the column level where
      the PII verifiers already look. Archivable (ADR-040 §5.9).
    * `wdl_doc_link` — one RESOLVED `[[Title]]` edge (ADR-053 §3): `wdl_source_doc_id` →
      `wdl_target_doc_id`, both same-org (`Samen.Policy.SameOrgFk`, R13), so a
      backlink is an indexed reverse query and a title in another org never resolves.
      Unique per `(source, target)`. Not archivable — a pure edge row.

  ## Abbrevs

  `wdb`/`wdl` are reserved through `mix samen.abbrev.reserve` under host
  `samen_web` (ADR-023) — never hand-edited into `priv/abbrev_registry.json`.

  ## Down

  `down/0` drops both new tables, drops the four added `wdd_doc` columns, and removes
  exactly the catalog rows this migration added (`catalog_sync_down(…, only: […])`
  for the additive columns, so nothing else in the table's entry is touched).
  """
  # An ADDITIVE (expand) migration: `down/0` is a clean round trip, so the tree
  # down-check exercises it in every host gate (`mix samen.verify.migrations`).
  use Samen.Migration, phase: :expand

  @doc_additions [:parent_doc_id, :icon, :position, :revision]
  @new_resources [Samen.WebTest.Docs.DocBlock, Samen.WebTest.Docs.DocLink]

  def up do
    alter table(:wdd_doc) do
      add(:wdd_parent_doc_id, :uuid)
      add(:wdd_icon, :text)
      add(:wdd_position, :bigint, null: false, default: 0)
      add(:wdd_revision, :bigint, null: false, default: 1)
    end

    create(index(:wdd_doc, [:wdd_parent_doc_id]))

    create table(:wdb_doc_block, primary_key: false) do
      add(:wdb_parent_block_id, :uuid)
      add(:wdb_position, :bigint, null: false, default: 0)
      add(:wdb_type, :text, null: false)
      add(:wdb_text, :text)
      add(:wdb_checked, :boolean)
      add(:wdb_metadata, :map, default: %{})
      add(:wdb_revision, :bigint, null: false, default: 1)
      add(:wdb_doc_id, :uuid, null: false)
      add(:pii_wdb_text_secure, :text)
      add(:wdb_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:wdb_org_id, :uuid, null: false)
      add(:wdb_inserted_at, :utc_datetime, null: false)
      add(:wdb_updated_at, :utc_datetime, null: false)
      add(:wdb_archived_at, :utc_datetime_usec)
    end

    create(index(:wdb_doc_block, [:wdb_org_id]))
    create(index(:wdb_doc_block, [:wdb_doc_id, :wdb_position]))
    create(index(:wdb_doc_block, [:wdb_parent_block_id]))

    create table(:wdl_doc_link, primary_key: false) do
      add(:wdl_anchor_text, :text, null: false)
      add(:wdl_source_doc_id, :uuid, null: false)
      add(:wdl_target_doc_id, :uuid, null: false)
      add(:wdl_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:wdl_org_id, :uuid, null: false)
      add(:wdl_inserted_at, :utc_datetime, null: false)
      add(:wdl_updated_at, :utc_datetime, null: false)
    end

    create(index(:wdl_doc_link, [:wdl_target_doc_id]))
    create(unique_index(:wdl_doc_link, [:wdl_source_doc_id, :wdl_target_doc_id]))

    catalog_sync([Samen.WebTest.Docs.Doc], only: @doc_additions)
    catalog_sync(@new_resources)
  end

  def down do
    catalog_sync_down(@new_resources)
    catalog_sync_down([Samen.WebTest.Docs.Doc], only: @doc_additions)

    drop(table(:wdl_doc_link))
    drop(table(:wdb_doc_block))

    alter table(:wdd_doc) do
      remove(:wdd_parent_doc_id)
      remove(:wdd_icon)
      remove(:wdd_position)
      remove(:wdd_revision)
    end
  end
end
