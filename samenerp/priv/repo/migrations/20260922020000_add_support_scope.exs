defmodule Samenerp.Repo.Migrations.AddSupportScope do
  @moduledoc """
  Mounts the Support universal scope (T3.6; `ticket · conversation · message🔒 ·
  agent🔒 · sla · macro · csat` + the I6 `csat_survey_token`) into this host's
  one Postgres, cataloging all eight resources in the SAME migration transaction
  (ADR-004 §"Migrations" catalog-in-tx). Mirrors demo's `add_support_scope` +
  `add_support_csat_survey_token`, with fresh `z`-family abbrevs reserved in the
  GLOBAL registry and the six `archivable: true` columns (`ticket`,
  `conversation`, `message`, `agent`, `sla`, `macro` — `csat`/`csat_survey_token`
  are excluded ledgers) folded directly into the CREATEs: this host mounts the
  scope AFTER the ADR-040 roster existed, so it never needs demo's separate
  `support_scope_archivable` follow-up.

    * `zla_sla`          — Tier-0 config rows: SLA policies per org
    * `ztk_ticket`       — the top-level ticket (SLA deadline, priority, status)
    * `zcv_conversation` — a conversation thread on a ticket
    * `zag_agent`        — 🔒 PII: full_name (composite vault) + email (scalar pii_)
    * `zmo_message`      — 🔒 PII: body (scalar pii_, free-text vault)
    * `zma_macro`        — Tier-0 config rows: canned responses per org
    * `zca_csat`         — customer satisfaction responses (excluded ledger)
    * `zct_csat_survey_token` — single-use hashed-at-rest survey link

  ## PII columns

  - `zag_agent.zag_full_name` — composite vault token (no `pii_` prefix)
  - `zag_agent.pii_zag_email` — scalar vault token
  - `zmo_message.pii_zmo_body` — scalar vault token (free-text ciphertext blob)

  ## FK order

  zla_sla ← ztk_ticket ← zcv_conversation ← zmo_message → zag_agent
  ztk_ticket ← zca_csat → zag_agent
  ztk_ticket ← zct_csat_survey_token → zag_agent
  """
  use Samen.Migration

  @resources [
    Samenerp.Support.Sla,
    Samenerp.Support.Ticket,
    Samenerp.Support.Conversation,
    Samenerp.Support.Agent,
    Samenerp.Support.Message,
    Samenerp.Support.Macro,
    Samenerp.Support.Csat,
    Samenerp.Support.CsatSurveyToken
  ]

  def up do
    # --- zla_sla : Tier-0 SLA policy rows (archivable) ---
    create table(:zla_sla, primary_key: false) do
      add(:zla_name, :text, null: false)
      add(:zla_label, :text)
      add(:zla_first_response_minutes, :integer, default: 60)
      add(:zla_resolve_minutes, :integer, default: 480)
      add(:zla_priority, :text, default: "normal")
      add(:zla_enabled, :boolean, default: true)
      add(:zla_archived_at, :utc_datetime_usec)
      add(:zla_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:zla_org_id, :uuid, null: false)
      add(:zla_inserted_at, :utc_datetime, null: false)
      add(:zla_updated_at, :utc_datetime, null: false)
    end

    # --- ztk_ticket : the top-level support ticket (archivable) ---
    create table(:ztk_ticket, primary_key: false) do
      add(:ztk_subject, :text, null: false)
      add(:ztk_status, :text, default: "open")
      add(:ztk_priority, :text, default: "normal")
      add(:ztk_sla_breach_at, :utc_datetime)
      add(:ztk_breached, :boolean, default: false, null: false)
      add(:ztk_resolved_at, :utc_datetime)
      add(:ztk_closed_at, :utc_datetime)
      add(:ztk_tags, {:array, :text}, default: [])
      add(:ztk_custom, :map, default: fragment("'{}'::jsonb"))
      add(:ztk_external_id, :text)
      add(:ztk_archived_at, :utc_datetime_usec)

      add(
        :ztk_sla_id,
        references(:zla_sla,
          column: :zla_id,
          name: "ztk_ticket_ztk_sla_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:ztk_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:ztk_org_id, :uuid, null: false)
      add(:ztk_inserted_at, :utc_datetime, null: false)
      add(:ztk_updated_at, :utc_datetime, null: false)
    end

    # Index for the SlaBreachWorker cron query (the worker's exact scan shape).
    create(
      index(:ztk_ticket, [:ztk_sla_breach_at, :ztk_breached],
        name: "ztk_ticket_sla_breach_idx",
        where: "ztk_sla_breach_at IS NOT NULL AND ztk_breached = false"
      )
    )

    # --- zcv_conversation : a conversation thread on a ticket (archivable) ---
    create table(:zcv_conversation, primary_key: false) do
      add(:zcv_channel, :text, default: "email")
      add(:zcv_status, :text, default: "open")
      add(:zcv_subject, :text)
      add(:zcv_archived_at, :utc_datetime_usec)

      add(
        :zcv_ticket_id,
        references(:ztk_ticket,
          column: :ztk_id,
          name: "zcv_conversation_zcv_ticket_id_fkey",
          type: :uuid,
          prefix: "public"
        ),
        null: false
      )

      add(:zcv_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:zcv_org_id, :uuid, null: false)
      add(:zcv_inserted_at, :utc_datetime, null: false)
      add(:zcv_updated_at, :utc_datetime, null: false)
    end

    # --- zag_agent : 🔒 PII (archivable) ---
    create table(:zag_agent, primary_key: false) do
      add(:zag_handle, :text)
      add(:zag_status, :text, default: "active")
      add(:zag_role, :text, default: "agent")
      add(:zag_external_id, :text)
      add(:zag_timezone, :text)
      add(:zag_custom, :map, default: fragment("'{}'::jsonb"))
      # Composite PII vault token: full_name routes by vault name (no pii_ prefix).
      add(:zag_full_name, :text)
      # Scalar PII vault token: email carries the pii_ prefix (pii_zag_email).
      add(:pii_zag_email, :text)
      add(:zag_archived_at, :utc_datetime_usec)
      add(:zag_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:zag_org_id, :uuid, null: false)
      add(:zag_inserted_at, :utc_datetime, null: false)
      add(:zag_updated_at, :utc_datetime, null: false)
    end

    # --- zmo_message : 🔒 PII: body (scalar pii_ token, free-text vault) (archivable) ---
    create table(:zmo_message, primary_key: false) do
      add(:zmo_sender_type, :text, default: "customer")
      add(:zmo_sender_id, :uuid)
      add(:zmo_message_type, :text, default: "reply")
      add(:zmo_attachments, {:array, :text}, default: [])
      add(:zmo_created_via, :text, default: "web")
      add(:pii_zmo_body, :text)
      add(:zmo_archived_at, :utc_datetime_usec)

      add(
        :zmo_conversation_id,
        references(:zcv_conversation,
          column: :zcv_id,
          name: "zmo_message_zmo_conversation_id_fkey",
          type: :uuid,
          prefix: "public"
        ),
        null: false
      )

      add(
        :zmo_agent_id,
        references(:zag_agent,
          column: :zag_id,
          name: "zmo_message_zmo_agent_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:zmo_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:zmo_org_id, :uuid, null: false)
      add(:zmo_inserted_at, :utc_datetime, null: false)
      add(:zmo_updated_at, :utc_datetime, null: false)
    end

    # --- zma_macro : Tier-0 canned response macros per org (archivable) ---
    create table(:zma_macro, primary_key: false) do
      add(:zma_name, :text, null: false)
      add(:zma_description, :text)
      add(:zma_body_template, :text)
      add(:zma_tags, {:array, :text}, default: [])
      add(:zma_enabled, :boolean, default: true)
      add(:zma_category, :text)
      add(:zma_archived_at, :utc_datetime_usec)
      add(:zma_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:zma_org_id, :uuid, null: false)
      add(:zma_inserted_at, :utc_datetime, null: false)
      add(:zma_updated_at, :utc_datetime, null: false)
    end

    # --- zca_csat : satisfaction responses (excluded ledger — NO archived_at) ---
    create table(:zca_csat, primary_key: false) do
      add(:zca_score, :integer, null: false)
      add(:zca_comments, :text)
      add(:zca_channel, :text, default: "email")
      add(:zca_responded_at, :utc_datetime)

      add(
        :zca_ticket_id,
        references(:ztk_ticket,
          column: :ztk_id,
          name: "zca_csat_zca_ticket_id_fkey",
          type: :uuid,
          prefix: "public"
        ),
        null: false
      )

      add(
        :zca_agent_id,
        references(:zag_agent,
          column: :zag_id,
          name: "zca_csat_zca_agent_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:zca_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:zca_org_id, :uuid, null: false)
      add(:zca_inserted_at, :utc_datetime, null: false)
      add(:zca_updated_at, :utc_datetime, null: false)
    end

    # --- zct_csat_survey_token : single-use hashed-at-rest survey link (NO archived_at) ---
    create table(:zct_csat_survey_token, primary_key: false) do
      add(:zct_token_digest, :text, null: false)
      add(:zct_expires_at, :utc_datetime, null: false)
      add(:zct_consumed_at, :utc_datetime)
      add(:zct_sent_at, :utc_datetime)

      add(
        :zct_ticket_id,
        references(:ztk_ticket,
          column: :ztk_id,
          name: "zct_csat_survey_token_zct_ticket_id_fkey",
          type: :uuid,
          prefix: "public"
        ),
        null: false
      )

      add(
        :zct_agent_id,
        references(:zag_agent,
          column: :zag_id,
          name: "zct_csat_survey_token_zct_agent_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:zct_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:zct_org_id, :uuid, null: false)
      add(:zct_inserted_at, :utc_datetime, null: false)
      add(:zct_updated_at, :utc_datetime, null: false)
    end

    # The anonymous redeem path's ONLY query shape is by digest (never by id).
    create(index(:zct_csat_survey_token, [:zct_token_digest], name: "zct_csat_survey_token_digest_idx"))

    # --- catalog all eight Support resources in THIS transaction ---
    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    drop(index(:zct_csat_survey_token, [:zct_token_digest], name: "zct_csat_survey_token_digest_idx"))
    drop(constraint(:zct_csat_survey_token, "zct_csat_survey_token_zct_agent_id_fkey"))
    drop(constraint(:zct_csat_survey_token, "zct_csat_survey_token_zct_ticket_id_fkey"))
    drop(table(:zct_csat_survey_token))

    drop(constraint(:zca_csat, "zca_csat_zca_agent_id_fkey"))
    drop(constraint(:zca_csat, "zca_csat_zca_ticket_id_fkey"))
    drop(table(:zca_csat))

    drop(constraint(:zmo_message, "zmo_message_zmo_agent_id_fkey"))
    drop(constraint(:zmo_message, "zmo_message_zmo_conversation_id_fkey"))
    drop(table(:zmo_message))

    drop(table(:zma_macro))

    drop(constraint(:zcv_conversation, "zcv_conversation_zcv_ticket_id_fkey"))
    drop(table(:zcv_conversation))

    drop(table(:zag_agent))

    drop(index(:ztk_ticket, [:ztk_sla_breach_at, :ztk_breached], name: "ztk_ticket_sla_breach_idx"))
    drop(constraint(:ztk_ticket, "ztk_ticket_ztk_sla_id_fkey"))
    drop(table(:ztk_ticket))

    drop(table(:zla_sla))
  end
end
