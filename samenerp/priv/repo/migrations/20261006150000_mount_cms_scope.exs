defmodule Samenerp.Repo.Migrations.MountCmsScope do
  @moduledoc """
  Phase 5 — mounts the framework CMS scope tables into the Samenerp host, and
  catalogs them in the SAME migration transaction (ADR-004 §"Migrations": the
  catalog-in-tx guarantee requires DDL + `catalog_sync` in one transaction in the
  host's repo).

  Fresh mount, so the whole scope lands at once — the three deltas the demo host
  accumulated across separate migrations (T3.5 base tables, T37b `archivable`
  columns, T78 post `visibility`) are folded into this one DDL, plus the E7
  `versioned: :snapshot` history tables (ADR-040 §6.5).

  Resources (`Samen.Scopes.Cms.Blueprint` via `Samenerp.Cms`):

    * `scg_page`         — a content page (draft→publish workflow; no PII)
    * `sct_post`         — a blog post / helpdesk KB article (draft→publish +
      `visibility` internal|public — a public+published post is the portal read)
    * `scb_block`        — a reusable content block (component/fragment)
    * `scd_media`        — a media asset (image/video/document reference)
    * `scn_navigation`   — Tier-0 config rows (nav items per org)
    * `scf_seo_meta`     — SEO metadata attached to a page or post
    * `scg_page_versions` / `sct_post_versions` / `scb_block_versions` — the E7
      audit-on-write history (ash_paper_trail `<Resource>.Version`)

  All six base tables carry the ADR-040 §5.9 `archivable: true` `<abbrev>_archived_at`
  column. The `<abbrev>_versions` tables are governed like any samen table:
  allocator-owned abbrev (`spv`/`stv`/`sbv`), self-qualifying prefixed columns, the
  mirrored `<abbrev>_org_id` (NOT NULL), the jsonb `<abbrev>_changes` token-only diff,
  and the universal id/timestamps.

  ## Abbrevs (permanent, allocator-reserved under host `samenerp`)

  `scg`/`sct`/`scb`/`scd`/`scn`/`scf` for the base resources, `spv`/`stv`/`sbv` for the
  three generated Version resources — reserved through `mix samen.abbrev.reserve`
  (ADR-023), never hand-edited.

  ## Non-PII

  The CMS scope has no 🔒 objects (all fields are authored content). No vault routing,
  no `non_pii!` registration needed — the free-text columns are not identity data.
  """
  use Samen.Migration

  @resources [
    Samenerp.Cms.Page,
    Samenerp.Cms.Post,
    Samenerp.Cms.Block,
    Samenerp.Cms.Media,
    Samenerp.Cms.Navigation,
    Samenerp.Cms.SeoMeta,
    Samenerp.Cms.Page.Version,
    Samenerp.Cms.Post.Version,
    Samenerp.Cms.Block.Version
  ]

  def up do
    # --- scg_page : a content page (draft→publish workflow) ---
    create table(:scg_page, primary_key: false) do
      add(:scg_title, :text, null: false)
      add(:scg_slug, :text)
      add(:scg_body, :text)
      add(:scg_status, :text, default: "draft")
      add(:scg_published_at, :utc_datetime)
      add(:scg_custom, :map, default: fragment("'{}'::jsonb"))
      add(:scg_archived_at, :utc_datetime_usec)
      add(:scg_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:scg_org_id, :uuid, null: false)
      add(:scg_inserted_at, :utc_datetime, null: false)
      add(:scg_updated_at, :utc_datetime, null: false)
    end

    # --- sct_post : a blog post / KB article (draft→publish + visibility) ---
    create table(:sct_post, primary_key: false) do
      add(:sct_title, :text, null: false)
      add(:sct_slug, :text)
      add(:sct_body, :text)
      add(:sct_excerpt, :text)
      add(:sct_status, :text, default: "draft")
      # T78 (spec §I5): the entire delta that turns a post into a KB article.
      add(:sct_visibility, :text, null: false, default: "internal")
      add(:sct_published_at, :utc_datetime)
      add(:sct_custom, :map, default: fragment("'{}'::jsonb"))
      add(:sct_archived_at, :utc_datetime_usec)
      add(:sct_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:sct_org_id, :uuid, null: false)
      add(:sct_inserted_at, :utc_datetime, null: false)
      add(:sct_updated_at, :utc_datetime, null: false)
    end

    create(index(:sct_post, [:sct_org_id, :sct_status, :sct_visibility]))

    # --- scb_block : a reusable content block (FK → scg_page) ---
    create table(:scb_block, primary_key: false) do
      add(:scb_name, :text, null: false)
      add(:scb_block_type, :text, default: "generic")
      add(:scb_content, :map, default: fragment("'{}'::jsonb"))
      add(:scb_position, :integer, default: 0)
      add(:scb_enabled, :boolean, default: true)
      add(:scb_archived_at, :utc_datetime_usec)

      add(
        :scb_page_id,
        references(:scg_page,
          column: :scg_id,
          name: "scb_block_scb_page_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:scb_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:scb_org_id, :uuid, null: false)
      add(:scb_inserted_at, :utc_datetime, null: false)
      add(:scb_updated_at, :utc_datetime, null: false)
    end

    # --- scd_media : a media asset (image/video/document reference) ---
    create table(:scd_media, primary_key: false) do
      add(:scd_file_name, :text, null: false)
      add(:scd_content_type, :text)
      add(:scd_size_bytes, :integer)
      add(:scd_storage_key, :text)
      add(:scd_alt_text, :text)
      add(:scd_media_type, :text, default: "image")
      add(:scd_archived_at, :utc_datetime_usec)
      add(:scd_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:scd_org_id, :uuid, null: false)
      add(:scd_inserted_at, :utc_datetime, null: false)
      add(:scd_updated_at, :utc_datetime, null: false)
    end

    # --- scn_navigation : Tier-0 config rows (nav items per org) ---
    create table(:scn_navigation, primary_key: false) do
      add(:scn_label, :text, null: false)
      add(:scn_url, :text)
      add(:scn_nav_type, :text, default: "main")
      add(:scn_position, :integer, default: 0)
      add(:scn_enabled, :boolean, default: true)
      add(:scn_target, :text, default: "self")
      add(:scn_archived_at, :utc_datetime_usec)
      add(:scn_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:scn_org_id, :uuid, null: false)
      add(:scn_inserted_at, :utc_datetime, null: false)
      add(:scn_updated_at, :utc_datetime, null: false)
    end

    # --- scf_seo_meta : SEO metadata for a page or post (FKs → scg_page, sct_post) ---
    create table(:scf_seo_meta, primary_key: false) do
      add(:scf_meta_title, :text)
      add(:scf_description, :text)
      add(:scf_canonical_url, :text)
      add(:scf_og_title, :text)
      add(:scf_og_description, :text)
      add(:scf_no_index, :boolean, default: false)
      add(:scf_no_follow, :boolean, default: false)
      add(:scf_archived_at, :utc_datetime_usec)

      add(
        :scf_page_id,
        references(:scg_page,
          column: :scg_id,
          name: "scf_seo_meta_scf_page_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(
        :scf_post_id,
        references(:sct_post,
          column: :sct_id,
          name: "scf_seo_meta_scf_post_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:scf_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:scf_org_id, :uuid, null: false)
      add(:scf_inserted_at, :utc_datetime, null: false)
      add(:scf_updated_at, :utc_datetime, null: false)
    end

    # --- E7 history (ADR-040 §6.5): the generated <Resource>.Version tables ---
    create table(:scg_page_versions, primary_key: false) do
      add(:spv_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:spv_version_action_type, :text, null: false)
      add(:spv_org_id, :uuid, null: false)
      add(:spv_version_source_id, :uuid, null: false)
      add(:spv_changes, :map)
      add(:spv_version_inserted_at, :utc_datetime_usec, null: false)
      add(:spv_version_updated_at, :utc_datetime_usec, null: false)
      add(:spv_inserted_at, :utc_datetime, null: false)
      add(:spv_updated_at, :utc_datetime, null: false)
    end

    create table(:sct_post_versions, primary_key: false) do
      add(:stv_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:stv_version_action_type, :text, null: false)
      add(:stv_org_id, :uuid, null: false)
      add(:stv_version_source_id, :uuid, null: false)
      add(:stv_changes, :map)
      add(:stv_version_inserted_at, :utc_datetime_usec, null: false)
      add(:stv_version_updated_at, :utc_datetime_usec, null: false)
      add(:stv_inserted_at, :utc_datetime, null: false)
      add(:stv_updated_at, :utc_datetime, null: false)
    end

    create table(:scb_block_versions, primary_key: false) do
      add(:sbv_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:sbv_version_action_type, :text, null: false)
      add(:sbv_org_id, :uuid, null: false)
      add(:sbv_version_source_id, :uuid, null: false)
      add(:sbv_changes, :map)
      add(:sbv_version_inserted_at, :utc_datetime_usec, null: false)
      add(:sbv_version_updated_at, :utc_datetime_usec, null: false)
      add(:sbv_inserted_at, :utc_datetime, null: false)
      add(:sbv_updated_at, :utc_datetime, null: false)
    end

    # --- catalog the nine CMS resources in THIS transaction ---
    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    # Drop in reverse FK order.
    drop(constraint(:scf_seo_meta, "scf_seo_meta_scf_post_id_fkey"))
    drop(constraint(:scf_seo_meta, "scf_seo_meta_scf_page_id_fkey"))
    drop(table(:scf_seo_meta))

    drop(constraint(:scb_block, "scb_block_scb_page_id_fkey"))
    drop(table(:scb_block))

    drop(table(:scn_navigation))
    drop(table(:scd_media))
    drop(table(:sct_post_versions))
    drop(table(:scg_page_versions))
    drop(table(:scb_block_versions))
    drop(table(:sct_post))
    drop(table(:scg_page))
  end
end
