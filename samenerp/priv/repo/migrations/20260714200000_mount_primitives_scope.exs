defmodule Samenerp.Repo.Migrations.MountPrimitivesScope do
  @moduledoc """
  Mounts the Primitives scope tables (`Samenerp.Primitives`, abbrevs
  `ent/enp/efl/esh/ewh/eff`) and catalogs
  them in the SAME migration transaction (ADR-004 catalog-in-tx). Mirrors pawchart's
  `mount_primitives_scope` (with the B5 flag-engine fields included — target_rules +
  variants land directly on the flag table).

  Load-bearing tables for the inherited web surfaces:

    * `ent_notification` — 🔒 PII: rendered_body (vault token;
      `pii_ent_rendered_body`) — the notifications inbox
    * `eff_feature_flag` — the flag rows the operator flag admin manages
  """
  use Samen.Migration

  @resources [
    Samenerp.Primitives.Notification,
    Samenerp.Primitives.NotificationPreference,
    Samenerp.Primitives.File,
    Samenerp.Primitives.SearchIndex,
    Samenerp.Primitives.Webhook,
    Samenerp.Primitives.FeatureFlag
  ]

  def up do
    # --- ent_notification : 🔒 PII: rendered_body ---
    create table(:ent_notification, primary_key: false) do
      add(:ent_recipient_id, :uuid, null: false)
      add(:ent_channel, :text, default: "in_app")
      add(:ent_event_type, :text, null: false)
      add(:ent_status, :text, default: "pending")
      add(:ent_sent_at, :utc_datetime)
      add(:ent_read_at, :utc_datetime)
      add(:ent_metadata, :map, default: fragment("'{}'::jsonb"))
      add(:pii_ent_rendered_body, :text)
      add(:ent_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:ent_org_id, :uuid, null: false)
      add(:ent_inserted_at, :utc_datetime, null: false)
      add(:ent_updated_at, :utc_datetime, null: false)
    end

    create(
      index(:ent_notification, [:ent_recipient_id, :ent_org_id],
        name: "ent_notification_recipient_org_idx"
      )
    )

    create(
      index(:ent_notification, [:ent_status, :ent_org_id],
        name: "ent_notification_status_org_idx"
      )
    )

    # --- enp_notification_preference : per-recipient dispatch prefs (no PII) ---
    create table(:enp_notification_preference, primary_key: false) do
      add(:enp_recipient_id, :uuid, null: false)
      add(:enp_event_type, :text, null: false)
      add(:enp_in_app_enabled, :boolean, default: true)
      add(:enp_email_enabled, :boolean, default: false)
      add(:enp_quiet_hours, :map, default: fragment("'{}'::jsonb"))
      add(:enp_digest_cadence, :text, null: false, default: "daily")
      add(:enp_digest_timezone, :text, null: false, default: "Etc/UTC")
      add(:enp_digest_last_sent_at, :utc_datetime)
      add(:enp_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:enp_org_id, :uuid, null: false)
      add(:enp_inserted_at, :utc_datetime, null: false)
      add(:enp_updated_at, :utc_datetime, null: false)
    end

    create(
      index(:enp_notification_preference, [:enp_recipient_id, :enp_event_type, :enp_org_id],
        name: "enp_notification_preference_recipient_event_org_idx",
        unique: true
      )
    )

    # --- efl_file ---
    create table(:efl_file, primary_key: false) do
      add(:efl_filename, :text, null: false)
      add(:efl_content_type, :text)
      add(:efl_size_bytes, :integer)
      add(:efl_storage_key, :text, null: false)
      add(:efl_status, :text, default: "active")
      add(:efl_uploaded_by_id, :uuid)
      add(:efl_metadata, :map, default: fragment("'{}'::jsonb"))
      add(:efl_search_vector, :text)
      # ADR-040 §5.9 (T37e) — file is archivable: true.
      add(:efl_archived_at, :utc_datetime_usec)
      add(:efl_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:efl_org_id, :uuid, null: false)
      add(:efl_inserted_at, :utc_datetime, null: false)
      add(:efl_updated_at, :utc_datetime, null: false)
    end

    # --- esh_search_index ---
    create table(:esh_search_index, primary_key: false) do
      add(:esh_resource_name, :text, null: false)
      add(:esh_field_name, :text, null: false)
      add(:esh_vector_column, :text, null: false)
      add(:esh_description, :text)
      add(:esh_enabled, :boolean, default: true)
      add(:esh_ts_config, :text, default: "english")
      add(:esh_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:esh_org_id, :uuid, null: false)
      add(:esh_inserted_at, :utc_datetime, null: false)
      add(:esh_updated_at, :utc_datetime, null: false)
    end

    # --- ewh_webhook : 🔒 PII: signing_secret ---
    create table(:ewh_webhook, primary_key: false) do
      add(:ewh_url, :text, null: false)
      add(:ewh_label, :text)
      add(:ewh_event_types, {:array, :text}, default: [])
      add(:ewh_status, :text, default: "active")
      add(:ewh_failure_count, :integer, default: 0)
      add(:ewh_last_delivered_at, :utc_datetime)
      add(:ewh_metadata, :map, default: fragment("'{}'::jsonb"))
      add(:pii_ewh_signing_secret, :text)
      # ADR-040 §5.9 (T37e) — webhook is archivable: true.
      add(:ewh_archived_at, :utc_datetime_usec)
      add(:ewh_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:ewh_org_id, :uuid, null: false)
      add(:ewh_inserted_at, :utc_datetime, null: false)
      add(:ewh_updated_at, :utc_datetime, null: false)
    end

    # --- eff_feature_flag (incl. the B5 engine fields: target_rules/variants) ---
    create table(:eff_feature_flag, primary_key: false) do
      add(:eff_name, :text, null: false)
      add(:eff_description, :text)
      add(:eff_enabled, :boolean, default: false)
      add(:eff_rollout_pct, :integer, default: 100)
      add(:eff_stage, :text, default: "beta")
      add(:eff_metadata, :map, default: fragment("'{}'::jsonb"))
      add(:eff_target_rules, :map, default: fragment("'[]'::jsonb"))
      add(:eff_variants, :map, default: fragment("'{}'::jsonb"))
      # ADR-040 §5.9 (T37e) — feature_flag is archivable: true.
      add(:eff_archived_at, :utc_datetime_usec)
      add(:eff_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:eff_org_id, :uuid, null: false)
      add(:eff_inserted_at, :utc_datetime, null: false)
      add(:eff_updated_at, :utc_datetime, null: false)
    end

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    drop(table(:eff_feature_flag))
    drop(table(:ewh_webhook))
    drop(table(:esh_search_index))
    drop(table(:efl_file))

    drop(
      index(:enp_notification_preference, [:enp_recipient_id, :enp_event_type, :enp_org_id],
        name: "enp_notification_preference_recipient_event_org_idx"
      )
    )

    drop(table(:enp_notification_preference))

    drop(
      index(:ent_notification, [:ent_status, :ent_org_id],
        name: "ent_notification_status_org_idx"
      )
    )

    drop(
      index(:ent_notification, [:ent_recipient_id, :ent_org_id],
        name: "ent_notification_recipient_org_idx"
      )
    )

    drop(table(:ent_notification))
  end
end
