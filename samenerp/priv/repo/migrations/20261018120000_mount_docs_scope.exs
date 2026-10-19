defmodule Samenerp.Repo.Migrations.MountDocsScope do
  @moduledoc """
  WS-Notes Phase 1 / ADR-053 — mounts the Docs scope into the Samenerp host for the
  FIRST time (this host never carried Doc/Note), together with the block model, and
  catalogs all four resources in the SAME transaction (ADR-004 catalog-in-tx).
  Mirrors this host's own `MountCalendarScope`.

    * `edd_doc`  — Doc: `title`, `body` (plain, `FreeTextScan`-guarded) /
      `pii_edd_secure_body` (🔒 `vault: :pii_doc_body`), the generic
      `(subject_key, subject_id)` object-ref anchor, plus the WS-Notes page-tree
      columns: `edd_parent_doc_id` (same-org — R4's org half), `edd_icon`,
      `edd_position` (integer ordinal among siblings, ADR-053 §8 O2) and
      `edd_revision` (optimistic concurrency). Archivable (ADR-040 §5.9).
    * `edn_note` — Note: same posture (`vault: :pii_note_body`), same anchor.
      Archivable.
    * `edb_doc_block` — one typed BLOCK row per page: `edb_type` is a bounded enum
      whose `edb_metadata`/`edb_checked` are validated against it by
      `Samen.Scopes.Docs.BlockShape` on every governed write; `edb_position` is
      scoped to `edb_parent_block_id`; `pii_edb_text_secure` is the 🔒 vaulted half
      of the per-block `text`/`text_secure` pair (`vault: :pii_block_text`) —
      block-level masking granularity. Archivable.
    * `edl_doc_link` — one RESOLVED `[[Title]]` edge; both endpoints same-org
      (`Samen.Policy.SameOrgFk`, R13); unique per `(source_doc_id, target_doc_id)`.
      Not archivable — a pure edge row.

  ## Abbrevs

  `edd`/`edn`/`edb`/`edl` reserved through `mix samen.abbrev.reserve` under host
  `samenerp` (ADR-023), never hand-edited into `priv/abbrev_registry.json`.

  ## Down

  `down/0` drops all four tables and their catalog rows (fresh mount — the
  bootstrap form of `catalog_sync_down/1`).
  """
  # An ADDITIVE (expand) migration: `down/0` is a clean round trip, so the tree
  # down-check exercises it in this host's gate (`mix samen.verify.migrations`).
  use Samen.Migration, phase: :expand

  @resources [
    Samenerp.Docs.Doc,
    Samenerp.Docs.Note,
    Samenerp.Docs.DocBlock,
    Samenerp.Docs.DocLink
  ]

  def up do
    create table(:edd_doc, primary_key: false) do
      add(:edd_title, :text, null: false)
      add(:edd_body, :text)
      add(:edd_subject_key, :text)
      add(:edd_subject_id, :uuid)
      add(:edd_custom, :map)
      add(:edd_owner_id, :uuid)
      add(:edd_icon, :text)
      add(:edd_position, :bigint, null: false, default: 0)
      add(:edd_revision, :bigint, null: false, default: 1)
      add(:edd_parent_doc_id, :uuid)
      add(:pii_edd_secure_body, :text)
      add(:edd_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:edd_org_id, :uuid, null: false)
      add(:edd_inserted_at, :utc_datetime, null: false)
      add(:edd_updated_at, :utc_datetime, null: false)
      add(:edd_archived_at, :utc_datetime_usec)
    end

    create(index(:edd_doc, [:edd_org_id]))
    create(index(:edd_doc, [:edd_subject_key, :edd_subject_id]))
    create(index(:edd_doc, [:edd_parent_doc_id]))

    create table(:edn_note, primary_key: false) do
      add(:edn_body, :text)
      add(:edn_subject_key, :text)
      add(:edn_subject_id, :uuid)
      add(:edn_custom, :map)
      add(:edn_owner_id, :uuid)
      add(:pii_edn_secure_body, :text)
      add(:edn_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:edn_org_id, :uuid, null: false)
      add(:edn_inserted_at, :utc_datetime, null: false)
      add(:edn_updated_at, :utc_datetime, null: false)
      add(:edn_archived_at, :utc_datetime_usec)
    end

    create(index(:edn_note, [:edn_org_id]))
    create(index(:edn_note, [:edn_subject_key, :edn_subject_id]))

    create table(:edb_doc_block, primary_key: false) do
      add(:edb_parent_block_id, :uuid)
      add(:edb_position, :bigint, null: false, default: 0)
      add(:edb_type, :text, null: false)
      add(:edb_text, :text)
      add(:edb_checked, :boolean)
      add(:edb_metadata, :map, default: %{})
      add(:edb_revision, :bigint, null: false, default: 1)
      add(:edb_doc_id, :uuid, null: false)
      add(:pii_edb_text_secure, :text)
      add(:edb_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:edb_org_id, :uuid, null: false)
      add(:edb_inserted_at, :utc_datetime, null: false)
      add(:edb_updated_at, :utc_datetime, null: false)
      add(:edb_archived_at, :utc_datetime_usec)
    end

    create(index(:edb_doc_block, [:edb_org_id]))
    create(index(:edb_doc_block, [:edb_doc_id, :edb_position]))
    create(index(:edb_doc_block, [:edb_parent_block_id]))

    create table(:edl_doc_link, primary_key: false) do
      add(:edl_anchor_text, :text, null: false)
      add(:edl_source_doc_id, :uuid, null: false)
      add(:edl_target_doc_id, :uuid, null: false)
      add(:edl_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:edl_org_id, :uuid, null: false)
      add(:edl_inserted_at, :utc_datetime, null: false)
      add(:edl_updated_at, :utc_datetime, null: false)
    end

    create(index(:edl_doc_link, [:edl_target_doc_id]))
    create(unique_index(:edl_doc_link, [:edl_source_doc_id, :edl_target_doc_id]))

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    drop(table(:edl_doc_link))
    drop(table(:edb_doc_block))
    drop(table(:edn_note))
    drop(table(:edd_doc))
  end
end
