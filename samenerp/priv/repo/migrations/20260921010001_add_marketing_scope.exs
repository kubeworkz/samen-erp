defmodule Samenerp.Repo.Migrations.AddMarketingScope do
  @moduledoc """
  Creates Marketing scope tables for Samenerp (z-prefix abbreviations).

  Resources:
    * `zmc_campaign`    — a marketing campaign
    * `zmg_segment`     — an audience segment
    * `zms_subscriber`  — subscriber (email vault-routed)
    * `zmt_template`    — reusable email templates per org
    * `zmn_send`        — a single send event
    * `zme_email_event` — delivery/open/click/bounce events
    * `zmp_suppression` — consent/suppression list
    * `zmv_consent_event` — consent audit events
  """
  use Samen.Migration

  @resources [
    Samenerp.Marketing.Campaign,
    Samenerp.Marketing.Segment,
    Samenerp.Marketing.Subscriber,
    Samenerp.Marketing.Template,
    Samenerp.Marketing.Send,
    Samenerp.Marketing.EmailEvent,
    Samenerp.Marketing.Suppression,
    Samenerp.Marketing.ConsentEvent
  ]

  def up do
    create table(:zmc_campaign, primary_key: false) do
      add(:zmc_name, :text, null: false)
      add(:zmc_description, :text)
      add(:zmc_status, :text, default: "draft")
      add(:zmc_scheduled_at, :utc_datetime)
      add(:zmc_sent_at, :utc_datetime)
      add(:zmc_custom, :map, default: fragment("'{}'::jsonb"))
      add(:zmc_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:zmc_org_id, :uuid, null: false)
      add(:zmc_inserted_at, :utc_datetime, null: false)
      add(:zmc_updated_at, :utc_datetime, null: false)
    end

    create table(:zmg_segment, primary_key: false) do
      add(:zmg_name, :text, null: false)
      add(:zmg_description, :text)
      add(:zmg_filter_criteria, :map, default: fragment("'{}'::jsonb"))
      add(:zmg_subscriber_count, :integer, default: 0)
      add(:zmg_custom, :map, default: fragment("'{}'::jsonb"))
      add(:zmg_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:zmg_org_id, :uuid, null: false)
      add(:zmg_inserted_at, :utc_datetime, null: false)
      add(:zmg_updated_at, :utc_datetime, null: false)
    end

    create table(:zms_subscriber, primary_key: false) do
      add(:zms_status, :text, default: "active")
      add(:zms_consent_at, :utc_datetime)
      add(:zms_source, :text)
      add(:zms_custom, :map, default: fragment("'{}'::jsonb"))
      add(:pii_zms_email, :text)
      add(:zms_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:zms_org_id, :uuid, null: false)
      add(:zms_inserted_at, :utc_datetime, null: false)
      add(:zms_updated_at, :utc_datetime, null: false)
    end

    create table(:zmt_template, primary_key: false) do
      add(:zmt_name, :text, null: false)
      add(:zmt_subject_line, :text, null: false)
      add(:zmt_body_html, :text)
      add(:zmt_body_text, :text)
      add(:zmt_from_name, :text)
      add(:zmt_from_address, :text)
      add(:zmt_enabled, :boolean, default: true)
      add(:zmt_custom, :map, default: fragment("'{}'::jsonb"))
      add(:zmt_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:zmt_org_id, :uuid, null: false)
      add(:zmt_inserted_at, :utc_datetime, null: false)
      add(:zmt_updated_at, :utc_datetime, null: false)
    end

    create table(:zmp_suppression, primary_key: false) do
      add(:zmp_reason, :text, null: false)
      add(:zmp_active, :boolean, default: true)
      add(:zmp_suppressed_at, :utc_datetime)
      add(:zmp_notes, :text)

      add(
        :zmp_subscriber_id,
        references(:zms_subscriber,
          column: :zms_id,
          name: "zmp_suppression_zmp_subscriber_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:zmp_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:zmp_org_id, :uuid, null: false)
      add(:zmp_inserted_at, :utc_datetime, null: false)
      add(:zmp_updated_at, :utc_datetime, null: false)
    end

    create table(:zmn_send, primary_key: false) do
      add(:zmn_status, :text, default: "queued")
      add(:zmn_queued_at, :utc_datetime)
      add(:zmn_sent_at, :utc_datetime)
      add(:zmn_idempotency_key, :text)
      add(:zmn_custom, :map, default: fragment("'{}'::jsonb"))

      add(
        :zmn_subscriber_id,
        references(:zms_subscriber,
          column: :zms_id,
          name: "zmn_send_zmn_subscriber_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(
        :zmn_campaign_id,
        references(:zmc_campaign,
          column: :zmc_id,
          name: "zmn_send_zmn_campaign_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(
        :zmn_template_id,
        references(:zmt_template,
          column: :zmt_id,
          name: "zmn_send_zmn_template_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:zmn_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:zmn_org_id, :uuid, null: false)
      add(:zmn_inserted_at, :utc_datetime, null: false)
      add(:zmn_updated_at, :utc_datetime, null: false)
    end

    create table(:zme_email_event, primary_key: false) do
      add(:zme_event_type, :text, null: false)
      add(:zme_occurred_at, :utc_datetime)
      add(:zme_metadata, :map, default: fragment("'{}'::jsonb"))

      add(
        :zme_send_id,
        references(:zmn_send,
          column: :zmn_id,
          name: "zme_email_event_zme_send_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(
        :zme_subscriber_id,
        references(:zms_subscriber,
          column: :zms_id,
          name: "zme_email_event_zme_subscriber_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:zme_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:zme_org_id, :uuid, null: false)
      add(:zme_inserted_at, :utc_datetime, null: false)
      add(:zme_updated_at, :utc_datetime, null: false)
    end

    create table(:zmv_consent_event, primary_key: false) do
      add(:zmv_action, :text, null: false)
      add(:zmv_channel, :text)
      add(:zmv_source, :text)
      add(:zmv_metadata, :map, default: fragment("'{}'::jsonb"))

      add(
        :zmv_subscriber_id,
        references(:zms_subscriber,
          column: :zms_id,
          name: "zmv_consent_event_zmv_subscriber_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:zmv_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:zmv_org_id, :uuid, null: false)
      add(:zmv_inserted_at, :utc_datetime, null: false)
      add(:zmv_updated_at, :utc_datetime, null: false)
    end

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    drop(constraint(:zmv_consent_event, "zmv_consent_event_zmv_subscriber_id_fkey"))
    drop(table(:zmv_consent_event))

    drop(constraint(:zme_email_event, "zme_email_event_zme_subscriber_id_fkey"))
    drop(constraint(:zme_email_event, "zme_email_event_zme_send_id_fkey"))
    drop(table(:zme_email_event))

    drop(constraint(:zmn_send, "zmn_send_zmn_template_id_fkey"))
    drop(constraint(:zmn_send, "zmn_send_zmn_campaign_id_fkey"))
    drop(constraint(:zmn_send, "zmn_send_zmn_subscriber_id_fkey"))
    drop(table(:zmn_send))

    drop(constraint(:zmp_suppression, "zmp_suppression_zmp_subscriber_id_fkey"))
    drop(table(:zmp_suppression))

    drop(table(:zmt_template))
    drop(table(:zms_subscriber))
    drop(table(:zmg_segment))
    drop(table(:zmc_campaign))
  end
end
