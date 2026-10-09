defmodule Samenerp.Repo.Migrations.MountAiDomain do
  @moduledoc """
  Phase 7 — mounts the framework AI plane (`Samen.AI.Domain`, ADR-043 §5.2/§7.5,
  ADR-047 §4.1/§6) into the Samenerp host, and catalogs the resources in the SAME
  migration transaction (ADR-004 catalog-in-tx).

  Fresh mount, so the whole domain lands at once — the deltas driftwood accumulated
  across separate migrations (the `sas_simulated` honesty provenance, the A2 agent
  durability columns + the vault-routed transcript, the T21 run hooks, the A2 turn
  meta) are folded into this one DDL, exactly as `MountCmsScope` folded the CMS
  scope's deltas.

  Resources (all `Samen.AI.*` framework resources, `use Samen.Resource`):

    * `ai_prompt`          — the D3 versioned managed prompt (abbrev `aip`)
    * `ai_support_reply_draft` — the D5 AI-support-operator draft (abbrev `sas`), the
      row the `ai_support_reply` approval kind gates the send of
    * `ai_agent_run`       — the durable agent-run cursor (abbrev `arn`); carries the
      🔒 vault-routed `pii_arn_transcript` (ADR-047 §7.4): only ever a `vt_*` token at
      rest, ciphertext under the run row's own DEK, reached by the 90-day retention
      shred arm
    * `ai_agent_turn`      — the token-only bounded per-turn log (abbrev `atn`)
    * `ai_agent_kill`      — the durable per-{org, definition} kill switch (abbrev `akl`)
    * `ai_assistant`       — the org-scoped assistant definition (abbrev `ast`)
    * `ai_assistant_conversation` — the thread under it (abbrev `asc`), whose ONE text
      artifact `pii_asc_transcript` is vault-routed exactly like the run transcript

  ## Abbrevs — none reserved

  Every resource here is a KERNEL resource whose abbrev is owned by host `samen_core`
  (`aip`/`sas`/`arn`/`atn`/`akl`/`ast`/`asc`), and whose physical table name is
  host-invariant (`ai_prompt`, …) — the resource declares it, not the host. So this
  phase allocates NOTHING through `mix samen.abbrev.reserve` and the golden
  registry/dict counts are unchanged; only this host's `schema.dict.json` grows.

  ## PII

  Two 🔒 columns, both scalar vault-routed fields carrying the `pii_` prefix that
  marks a token column (`pii_arn_transcript`, `pii_asc_transcript`) — never plaintext
  at rest, resolved per plane through `Samen.Api.PiiResolution` like every other
  vaulted field (INV-1). Their `pii_` prefix is the SCALAR convention (the composite
  convention is the Calendar scope's unprefixed `*_attendees`).
  """
  use Samen.Migration

  @resources [
    Samen.AI.Prompt,
    Samen.AI.SupportReplyDraft,
    Samen.AI.Agent.Run,
    Samen.AI.Agent.Turn,
    Samen.AI.Agent.Kill,
    Samen.AI.Assistant,
    Samen.AI.AssistantConversation
  ]

  def up do
    # --- ai_prompt : the D3 versioned managed prompt ---
    create table(:ai_prompt, primary_key: false) do
      add(:aip_name, :text, null: false)
      add(:aip_version, :bigint, null: false)
      add(:aip_body, :text, null: false)
      add(:aip_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:aip_org_id, :uuid, null: false)
      add(:aip_inserted_at, :utc_datetime, null: false)
      add(:aip_updated_at, :utc_datetime, null: false)
    end

    create(
      unique_index(:ai_prompt, [:aip_org_id, :aip_name, :aip_version],
        name: "ai_prompt_name_version_index"
      )
    )

    # --- ai_support_reply_draft : the D5 AI-support-operator draft ---
    create table(:ai_support_reply_draft, primary_key: false) do
      add(:sas_to_subscriber_id, :uuid, null: false)
      add(:sas_inbound_ref, :text)
      add(:sas_subject, :text)
      add(:sas_body, :text, null: false)
      add(:sas_requested_by, :text)
      add(:sas_status, :text, null: false, default: "draft")
      # PP-16/T152 honesty provenance — folded (the later driftwood/samen_core delta):
      # whether the body came from a keyless/deterministic SIMULATED provider.
      add(:sas_simulated, :boolean, null: false, default: false)
      add(:sas_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:sas_org_id, :uuid, null: false)
      add(:sas_inserted_at, :utc_datetime, null: false)
      add(:sas_updated_at, :utc_datetime, null: false)
    end

    create(index(:ai_support_reply_draft, [:sas_org_id], name: "ai_support_reply_draft_org_idx"))

    # --- ai_agent_run : the durable agent-run cursor (TOKEN-ONLY except the transcript) ---
    create table(:ai_agent_run, primary_key: false) do
      add(:arn_agent, :text, null: false)
      # AshStateMachine state stored as text (the apv_state precedent).
      add(:arn_state, :text, null: false, default: "queued")
      add(:arn_current_turn, :bigint, null: false, default: 0)
      add(:arn_next_turn_at, :utc_datetime_usec)
      add(:arn_started_at, :utc_datetime_usec)
      add(:arn_cancel_requested_at, :utc_datetime_usec)
      add(:arn_error_kind, :text)
      add(:arn_max_turns, :bigint, null: false)
      add(:arn_max_tool_calls, :bigint, null: false)
      add(:arn_max_input_tokens, :bigint, null: false)
      add(:arn_max_output_tokens, :bigint, null: false)
      add(:arn_deadline_seconds, :bigint, null: false)
      add(:arn_tool_calls_used, :bigint, null: false, default: 0)
      add(:arn_input_tokens_used, :bigint, null: false, default: 0)
      add(:arn_output_tokens_used, :bigint, null: false, default: 0)
      add(:arn_origin, :text)
      add(:arn_depth, :bigint, null: false, default: 0)
      add(:arn_chain, {:array, :text}, null: false, default: [])
      # A2 durability — the worker-resume facts (folded).
      add(:arn_owner_id, :text)
      add(:arn_agent_module, :text)
      # A2 §7.4 — the 🔒 vault-routed transcript: only ever a vt_* token at rest.
      add(:pii_arn_transcript, :text)
      # T21/UXD-08 — the per-run hook chain (module names), so the durable TurnWorker
      # can re-resolve it at execution time (folded).
      add(:arn_hooks, {:array, :text}, null: false, default: [])
      add(:arn_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:arn_org_id, :uuid, null: false)
      add(:arn_inserted_at, :utc_datetime, null: false)
      add(:arn_updated_at, :utc_datetime, null: false)
    end

    create(index(:ai_agent_run, [:arn_org_id], name: "ai_agent_run_org_idx"))
    # The A2 due-scan's selector shape (`next_turn_at <= now`, non-terminal).
    create(index(:ai_agent_run, [:arn_next_turn_at], name: "ai_agent_run_next_turn_at_idx"))

    # --- ai_agent_turn : the bounded, token-only per-turn log ---
    create table(:ai_agent_turn, primary_key: false) do
      add(:atn_run_id, :uuid, null: false)
      add(:atn_turn_index, :bigint, null: false)
      add(:atn_status, :text, null: false)
      add(:atn_tool_kind, :text)
      add(:atn_arg_keys, {:array, :text}, null: false, default: [])
      add(:atn_error_kind, :text)
      add(:atn_input_tokens, :bigint, null: false, default: 0)
      add(:atn_output_tokens, :bigint, null: false, default: 0)
      add(:atn_duration_ms, :bigint, null: false, default: 0)
      add(:atn_provider, :text)
      add(:atn_simulated, :boolean, null: false, default: false)
      # A2 — bounded jsonb replay provenance (token-only allowlist), folded.
      add(:atn_meta, :map, null: false, default: %{})
      add(:atn_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:atn_org_id, :uuid, null: false)
      add(:atn_inserted_at, :utc_datetime, null: false)
      add(:atn_updated_at, :utc_datetime, null: false)
    end

    # The A2 crash-replay idempotency key.
    create(
      unique_index(:ai_agent_turn, [:atn_run_id, :atn_turn_index],
        name: "ai_agent_turn_run_turn_index"
      )
    )

    create(index(:ai_agent_turn, [:atn_org_id], name: "ai_agent_turn_org_idx"))

    # --- ai_agent_kill : the durable per-{org, definition} kill switch ---
    create table(:ai_agent_kill, primary_key: false) do
      add(:akl_agent, :text, null: false)
      add(:akl_reason, :text, null: false)
      add(:akl_killed_at, :utc_datetime_usec, null: false)
      add(:akl_killed_by, :text)
      add(:akl_rearmed_at, :utc_datetime_usec)
      add(:akl_rearmed_by, :text)
      add(:akl_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:akl_org_id, :uuid, null: false)
      add(:akl_inserted_at, :utc_datetime, null: false)
      add(:akl_updated_at, :utc_datetime, null: false)
    end

    create(
      unique_index(:ai_agent_kill, [:akl_org_id, :akl_agent], name: "ai_agent_kill_org_agent_index")
    )

    # --- ai_assistant : the org-scoped assistant definition ---
    create table(:ai_assistant, primary_key: false) do
      add(:ast_name, :text, null: false)
      add(:ast_title, :text, null: false)
      add(:ast_system_prompt, :text, null: false)
      add(:ast_model_id, :text)
      add(:ast_tools, {:array, :text}, null: false, default: [])
      add(:ast_status, :text, null: false, default: "active")
      add(:ast_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:ast_org_id, :uuid, null: false)
      add(:ast_inserted_at, :utc_datetime_usec, null: false)
      add(:ast_updated_at, :utc_datetime_usec, null: false)
      add(:ast_archived_at, :utc_datetime_usec)
    end

    create(unique_index(:ai_assistant, [:ast_org_id, :ast_name], name: "ai_assistant_org_name_index"))
    create(index(:ai_assistant, [:ast_org_id], name: "ai_assistant_org_idx"))

    # --- ai_assistant_conversation : the vault-routed thread under it ---
    create table(:ai_assistant_conversation, primary_key: false) do
      add(:asc_assistant_id, :uuid, null: false)
      add(:asc_title, :text, null: false)
      add(:asc_status, :text, null: false, default: "active")
      add(:asc_model_id, :text)
      add(:asc_message_count, :bigint, null: false, default: 0)
      add(:asc_total_tokens, :bigint, null: false, default: 0)
      add(:asc_last_message_at, :utc_datetime_usec)
      # The 🔒 vault-routed transcript: only ever a vt_* token at rest.
      add(:pii_asc_transcript, :text)
      add(:asc_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:asc_org_id, :uuid, null: false)
      add(:asc_inserted_at, :utc_datetime_usec, null: false)
      add(:asc_updated_at, :utc_datetime_usec, null: false)
      add(:asc_archived_at, :utc_datetime_usec)
    end

    create(index(:ai_assistant_conversation, [:asc_org_id], name: "ai_assistant_conversation_org_idx"))

    create(
      index(:ai_assistant_conversation, [:asc_assistant_id],
        name: "ai_assistant_conversation_assistant_idx"
      )
    )

    # --- catalog the seven AI-plane resources in THIS transaction ---
    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    drop(index(:ai_assistant_conversation, [:asc_assistant_id], name: "ai_assistant_conversation_assistant_idx"))
    drop(index(:ai_assistant_conversation, [:asc_org_id], name: "ai_assistant_conversation_org_idx"))
    drop(table(:ai_assistant_conversation))

    drop(index(:ai_assistant, [:ast_org_id], name: "ai_assistant_org_idx"))
    drop_if_exists(unique_index(:ai_assistant, [:ast_org_id, :ast_name], name: "ai_assistant_org_name_index"))
    drop(table(:ai_assistant))

    drop_if_exists(unique_index(:ai_agent_kill, [:akl_org_id, :akl_agent], name: "ai_agent_kill_org_agent_index"))
    drop(table(:ai_agent_kill))

    drop(index(:ai_agent_turn, [:atn_org_id], name: "ai_agent_turn_org_idx"))

    drop_if_exists(
      unique_index(:ai_agent_turn, [:atn_run_id, :atn_turn_index],
        name: "ai_agent_turn_run_turn_index"
      )
    )

    drop(table(:ai_agent_turn))

    drop(index(:ai_agent_run, [:arn_next_turn_at], name: "ai_agent_run_next_turn_at_idx"))
    drop(index(:ai_agent_run, [:arn_org_id], name: "ai_agent_run_org_idx"))
    drop(table(:ai_agent_run))

    drop(index(:ai_support_reply_draft, [:sas_org_id], name: "ai_support_reply_draft_org_idx"))
    drop(table(:ai_support_reply_draft))

    drop_if_exists(
      unique_index(:ai_prompt, [:aip_org_id, :aip_name, :aip_version],
        name: "ai_prompt_name_version_index"
      )
    )

    drop(table(:ai_prompt))
  end
end
