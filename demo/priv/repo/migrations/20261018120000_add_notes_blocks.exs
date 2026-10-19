defmodule Demo.Repo.Migrations.AddNotesBlocks do
  @moduledoc """
  WS-Notes Phase 1 (ADR-053 §3) — the **block model** in the demo host, with the
  catalog written in the SAME transaction (ADR-004 catalog-in-tx).

    * `ddd_doc` gains the page-tree/ordinal columns — additive, nothing rewritten:
      `ddd_parent_doc_id` (the tree, same-org — R4's org half),
      `ddd_icon` (bounded token), `ddd_position` (integer ordinal among
      siblings, ADR-053 §8 O2) and `ddd_revision` (optimistic concurrency).
    * `ddb_doc_block` — one typed BLOCK row per page (ADR-053 §2 D2): `ddb_type` is a
      bounded enum and `ddb_metadata`/`ddb_checked` are validated against it by
      `Samen.Scopes.Docs.BlockShape` at the write boundary (the enum constraint alone
      cannot express "`language` only on `code`"). `ddb_position` is an integer
      ordinal scoped to `ddb_parent_block_id` and 🔒 `pii_ddb_text_secure` is the
      vaulted half of the per-block `text`/`text_secure` pair (`vault:
      :pii_block_text`) — block-level masking granularity, at the column level where
      the PII verifiers already look. Archivable (ADR-040 §5.9).
    * `ddl_doc_link` — one RESOLVED `[[Title]]` edge (ADR-053 §3): `ddl_source_doc_id` →
      `ddl_target_doc_id`, both same-org (`Samen.Policy.SameOrgFk`, R13), so a
      backlink is an indexed reverse query and a title in another org never resolves.
      Unique per `(source, target)`. Not archivable — a pure edge row.

  ## Abbrevs

  `ddb`/`ddl` are reserved through `mix samen.abbrev.reserve` under host
  `demo` (ADR-023) — never hand-edited into `priv/abbrev_registry.json`.

  ## Down

  `down/0` drops both new tables, drops the four added `ddd_doc` columns, and removes
  exactly the catalog rows this migration added (`catalog_sync_down(…, only: […])`
  for the additive columns, so nothing else in the table's entry is touched).
  """
  # An ADDITIVE (expand) migration: `down/0` is a clean round trip, so the tree
  # down-check exercises it in every host gate (`mix samen.verify.migrations`).
  use Samen.Migration, phase: :expand

  @doc_additions [:parent_doc_id, :icon, :position, :revision]
  @new_resources [Demo.DocsScope.DocBlock, Demo.DocsScope.DocLink]

  def up do
    alter table(:ddd_doc) do
      add(:ddd_parent_doc_id, :uuid)
      add(:ddd_icon, :text)
      add(:ddd_position, :bigint, null: false, default: 0)
      add(:ddd_revision, :bigint, null: false, default: 1)
    end

    create(index(:ddd_doc, [:ddd_parent_doc_id]))

    create table(:ddb_doc_block, primary_key: false) do
      add(:ddb_parent_block_id, :uuid)
      add(:ddb_position, :bigint, null: false, default: 0)
      add(:ddb_type, :text, null: false)
      add(:ddb_text, :text)
      add(:ddb_checked, :boolean)
      add(:ddb_metadata, :map, default: %{})
      add(:ddb_revision, :bigint, null: false, default: 1)
      add(:ddb_doc_id, :uuid, null: false)
      add(:pii_ddb_text_secure, :text)
      add(:ddb_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:ddb_org_id, :uuid, null: false)
      add(:ddb_inserted_at, :utc_datetime, null: false)
      add(:ddb_updated_at, :utc_datetime, null: false)
      add(:ddb_archived_at, :utc_datetime_usec)
    end

    create(index(:ddb_doc_block, [:ddb_org_id]))
    create(index(:ddb_doc_block, [:ddb_doc_id, :ddb_position]))
    create(index(:ddb_doc_block, [:ddb_parent_block_id]))

    create table(:ddl_doc_link, primary_key: false) do
      add(:ddl_anchor_text, :text, null: false)
      add(:ddl_source_doc_id, :uuid, null: false)
      add(:ddl_target_doc_id, :uuid, null: false)
      add(:ddl_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:ddl_org_id, :uuid, null: false)
      add(:ddl_inserted_at, :utc_datetime, null: false)
      add(:ddl_updated_at, :utc_datetime, null: false)
    end

    create(index(:ddl_doc_link, [:ddl_target_doc_id]))
    create(unique_index(:ddl_doc_link, [:ddl_source_doc_id, :ddl_target_doc_id]))

    catalog_sync([Demo.DocsScope.Doc], only: @doc_additions)
    catalog_sync(@new_resources)
  end

  def down do
    catalog_sync_down(@new_resources)
    catalog_sync_down([Demo.DocsScope.Doc], only: @doc_additions)

    drop(table(:ddl_doc_link))
    drop(table(:ddb_doc_block))

    alter table(:ddd_doc) do
      remove(:ddd_parent_doc_id)
      remove(:ddd_icon)
      remove(:ddd_position)
      remove(:ddd_revision)
    end
  end
end
