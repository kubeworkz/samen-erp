defmodule Samenerp.Repo.Migrations.AddAutomationScope do
  @moduledoc """
  Mounts the Automation universal scope (ADR-039 §3.1; T39/T41/T42/T118) into
  this host's one Postgres, cataloging all four resources in the SAME migration
  transaction (ADR-004 catalog-in-tx). Mirrors driftwood's
  `add_automation_scope` with fresh `z`-family abbrevs (the scope defaults
  `awf`/`arm`/`aes`/`sar` are permanently owned by the samen_core automation
  fixtures). No resource in this scope is `archivable` — no archived_at
  columns, matching the reference migration.

    * `zwf_workflow` — E1 rule definition (trigger → conditions → actions),
      incl. the §8.4 kill columns. No PII by schema.
    * `zrm_reminder` — E4 first-class reminder; 🔒 vaulted `note`
      (`pii_zrm_note`).
    * `zes_escalation` — E5 generic escalation primitive (AshStateMachine).
    * `zrn_run` — E8 run log. No PII by schema.
  """
  use Samen.Migration

  @resources [
    Samenerp.Automation.Workflow,
    Samenerp.Automation.Reminder,
    Samenerp.Automation.Escalation,
    Samenerp.Automation.Run
  ]

  def up do
    create table(:zwf_workflow, primary_key: false) do
      add(:zwf_name, :text, null: false)
      add(:zwf_status, :text, default: "draft")
      add(:zwf_trigger_kind, :text, default: "resource_event")
      add(:zwf_resource_key, :text)
      add(:zwf_event, :text)
      add(:zwf_schedule_cron, :text)
      add(:zwf_next_fire_at, :utc_datetime)
      add(:zwf_conditions, :map, default: fragment("'[]'::jsonb"))
      add(:zwf_actions, :map, default: fragment("'[]'::jsonb"))
      add(:zwf_owner_id, :uuid)
      add(:zwf_disabled_by_operator_at, :utc_datetime)
      add(:zwf_disabled_reason, :text)
      add(:zwf_webhook_secret, :text)
      add(:zwf_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:zwf_org_id, :uuid, null: false)
      add(:zwf_inserted_at, :utc_datetime, null: false)
      add(:zwf_updated_at, :utc_datetime, null: false)
    end

    create(index(:zwf_workflow, [:zwf_org_id], name: "zwf_workflow_org_idx"))

    create table(:zrm_reminder, primary_key: false) do
      add(:zrm_recipient_id, :uuid, null: false)
      add(:zrm_subject_ref, :text, null: false)
      add(:zrm_remind_at, :utc_datetime, null: false)
      # Scalar PII vault token: `note` carries the `pii_` prefix (pii_zrm_note),
      # the SAME convention Chat's `body` uses.
      add(:pii_zrm_note, :text)
      add(:zrm_source, :text, default: "user")
      add(:zrm_state, :text, null: false, default: "scheduled")
      add(:zrm_sent_at, :utc_datetime)
      add(:zrm_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:zrm_org_id, :uuid, null: false)
      add(:zrm_inserted_at, :utc_datetime, null: false)
      add(:zrm_updated_at, :utc_datetime, null: false)
    end

    create(index(:zrm_reminder, [:zrm_org_id], name: "zrm_reminder_org_idx"))
    create(index(:zrm_reminder, [:zrm_state, :zrm_remind_at], name: "zrm_reminder_due_scan_idx"))

    create table(:zes_escalation, primary_key: false) do
      add(:zes_kind, :text, null: false)
      add(:zes_dedupe_key, :text, null: false)
      add(:zes_subject_ref, :text, null: false)
      add(:zes_deadline_at, :utc_datetime, null: false)
      add(:zes_chain, :map, default: fragment("'[]'::jsonb"))
      add(:zes_current_step, :integer, default: 0)
      add(:zes_next_action_at, :utc_datetime)
      add(:zes_resolved_at, :utc_datetime)
      add(:zes_state, :text, null: false, default: "open")
      add(:zes_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:zes_org_id, :uuid, null: false)
      add(:zes_inserted_at, :utc_datetime, null: false)
      add(:zes_updated_at, :utc_datetime, null: false)
    end

    create(
      unique_index(:zes_escalation, [:zes_org_id, :zes_kind, :zes_dedupe_key],
        where: "zes_state IN ('open', 'escalating')",
        name: "zes_escalation_active_dedupe_idx"
      )
    )

    create(
      index(:zes_escalation, [:zes_state, :zes_next_action_at], name: "zes_escalation_due_scan_idx")
    )

    create(index(:zes_escalation, [:zes_org_id], name: "zes_escalation_org_idx"))

    create table(:zrn_run, primary_key: false) do
      add(:zrn_workflow_id, :uuid, null: false)
      add(:zrn_dispatch_key, :text, null: false)
      add(:zrn_trigger_kind, :text)
      add(:zrn_subject_ref, :text)
      add(:zrn_depth, :integer, default: 0)
      add(:zrn_outcome, :map, default: fragment("'[]'::jsonb"))
      add(:zrn_started_at, :utc_datetime)
      add(:zrn_finished_at, :utc_datetime)
      add(:zrn_duration_ms, :integer)
      add(:zrn_error_kind, :text)
      add(:zrn_state, :text, default: "queued")
      add(:zrn_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:zrn_org_id, :uuid, null: false)
      add(:zrn_inserted_at, :utc_datetime, null: false)
      add(:zrn_updated_at, :utc_datetime, null: false)
    end

    create(unique_index(:zrn_run, [:zrn_dispatch_key], name: "zrn_run_dispatch_key_idx"))
    create(index(:zrn_run, [:zrn_org_id, :zrn_workflow_id], name: "zrn_run_org_workflow_idx"))

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    drop(index(:zrn_run, [:zrn_org_id, :zrn_workflow_id], name: "zrn_run_org_workflow_idx"))
    drop(unique_index(:zrn_run, [:zrn_dispatch_key], name: "zrn_run_dispatch_key_idx"))
    drop(table(:zrn_run))

    drop(index(:zes_escalation, [:zes_org_id], name: "zes_escalation_org_idx"))
    drop(index(:zes_escalation, [:zes_state, :zes_next_action_at], name: "zes_escalation_due_scan_idx"))

    drop(
      unique_index(:zes_escalation, [:zes_org_id, :zes_kind, :zes_dedupe_key],
        where: "zes_state IN ('open', 'escalating')",
        name: "zes_escalation_active_dedupe_idx"
      )
    )

    drop(table(:zes_escalation))

    drop(index(:zrm_reminder, [:zrm_state, :zrm_remind_at], name: "zrm_reminder_due_scan_idx"))
    drop(index(:zrm_reminder, [:zrm_org_id], name: "zrm_reminder_org_idx"))
    drop(table(:zrm_reminder))

    drop(index(:zwf_workflow, [:zwf_org_id], name: "zwf_workflow_org_idx"))
    drop(table(:zwf_workflow))
  end
end
