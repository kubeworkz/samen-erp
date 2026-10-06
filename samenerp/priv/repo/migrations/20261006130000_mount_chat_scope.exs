defmodule Samenerp.Repo.Migrations.MountChatScope do
  @moduledoc """
  Mounts the Samenerp Chat scope tables (ADR-012 — the flagship cross-plane
  realtime chat, Phase 2 of the module-group plan) and catalogs every resource in
  the SAME migration transaction (ADR-004 catalog-in-tx). Column shape mirrors the
  `Samen.Scopes.Chat` blueprint exactly as driftwood's `20260708170000
  _mount_chat_scope` + `20260729260000_chat_scope_archivable` +
  `20260803130000_add_chat_message_attachments` migrations leave it today — this
  host folds all three into one migration since nothing pre-exists here.

  ## Chat — cth/chp/cmg/cds (the canonical ADR-012 §11 family, allocator-reserved)

    * `cth_thread`             — a conversation that may span two planes (no PII)
    * `chp_participant`        — 🔒 PII: full_name (composite vault token) + the grant carrier
    * `cmg_message`            — 🔒 PII: body (scalar pii_ token; free-text vault) + refs + attachments
    * `cds_disclosure_setting` — Tier-0 per-org identity-disclosure config (no PII)

  ## PII columns (vault vt_* tokens — plaintext never lands here)

  - `chp_participant.chp_full_name` — composite vault token (VaultField; no pii_ prefix)
  - `cmg_message.pii_cmg_body`      — scalar vault token (pii_ prefix; free-text)

  ## FK order: cth_thread ← chp_participant ← cmg_message → cth_thread
  """
  use Samen.Migration

  @resources [
    Samenerp.Chat.ChatThread,
    Samenerp.Chat.ChatParticipant,
    Samenerp.Chat.ChatMessage,
    Samenerp.Chat.ChatDisclosureSetting
  ]

  def up do
    create table(:cth_thread, primary_key: false) do
      add(:cth_subject, :text)
      add(:cth_kind, :text, default: "cross_plane")
      add(:cth_status, :text, default: "open")
      add(:cth_disclosure_mode, :text, default: "masked")
      add(:cth_context_ref, :text)
      add(:cth_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:cth_org_id, :uuid, null: false)
      add(:cth_inserted_at, :utc_datetime, null: false)
      add(:cth_updated_at, :utc_datetime, null: false)
      # ADR-040 §5.9 (T37e) — archivable + the cascade PARENT (thread ▸cascade
      # participant ▸cascade message); driftwood added this additively, we fold it in.
      add(:cth_archived_at, :utc_datetime_usec)
    end

    create(index(:cth_thread, [:cth_org_id]))

    create table(:chp_participant, primary_key: false) do
      add(:chp_party, :text, default: "tenant")
      add(:chp_principal_kind, :text, default: "user")
      add(:chp_principal_id, :text)
      add(:chp_handle, :text)
      add(:chp_identity_shared, :boolean, default: false)
      add(:chp_role, :text, default: "member")
      add(:chp_online_at, :utc_datetime)
      # Composite PII vault token: full_name routes by vault name (no pii_ prefix).
      add(:chp_full_name, :text)

      add(
        :chp_thread_id,
        references(:cth_thread,
          column: :cth_id,
          name: "chp_participant_chp_thread_id_fkey",
          type: :uuid,
          prefix: "public"
        ),
        null: false
      )

      add(:chp_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:chp_org_id, :uuid, null: false)
      add(:chp_inserted_at, :utc_datetime, null: false)
      add(:chp_updated_at, :utc_datetime, null: false)
      add(:chp_archived_at, :utc_datetime_usec)
    end

    create(index(:chp_participant, [:chp_org_id]))
    create(index(:chp_participant, [:chp_thread_id]))

    create table(:cmg_message, primary_key: false) do
      add(:cmg_sender_party, :text, default: "tenant")
      add(:cmg_kind, :text, default: "message")
      add(:cmg_refs, {:array, :text}, default: [])
      # Scalar PII vault token: body carries the pii_ prefix (pii_cmg_body). Free-text.
      add(:pii_cmg_body, :text)
      # `Samen.Files` upload keys (the chokepoint) — never a raw storage_key write.
      add(:cmg_attachments, {:array, :text}, default: [])

      add(
        :cmg_thread_id,
        references(:cth_thread,
          column: :cth_id,
          name: "cmg_message_cmg_thread_id_fkey",
          type: :uuid,
          prefix: "public"
        ),
        null: false
      )

      add(
        :cmg_participant_id,
        references(:chp_participant,
          column: :chp_id,
          name: "cmg_message_chp_participant_id_fkey",
          type: :uuid,
          prefix: "public"
        ),
        null: false
      )

      add(:cmg_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:cmg_org_id, :uuid, null: false)
      add(:cmg_inserted_at, :utc_datetime, null: false)
      add(:cmg_updated_at, :utc_datetime, null: false)
      add(:cmg_archived_at, :utc_datetime_usec)
    end

    create(index(:cmg_message, [:cmg_org_id]))
    create(index(:cmg_message, [:cmg_thread_id]))

    create table(:cds_disclosure_setting, primary_key: false) do
      add(:cds_expose_identity_to_support, :boolean, default: false)
      add(:cds_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:cds_org_id, :uuid, null: false)
      add(:cds_inserted_at, :utc_datetime, null: false)
      add(:cds_updated_at, :utc_datetime, null: false)
    end

    create(index(:cds_disclosure_setting, [:cds_org_id]))

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    drop(table(:cds_disclosure_setting))

    drop(constraint(:cmg_message, "cmg_message_chp_participant_id_fkey"))
    drop(constraint(:cmg_message, "cmg_message_cmg_thread_id_fkey"))
    drop(table(:cmg_message))

    drop(constraint(:chp_participant, "chp_participant_chp_thread_id_fkey"))
    drop(table(:chp_participant))

    drop(table(:cth_thread))
  end
end
