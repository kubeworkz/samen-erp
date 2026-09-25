defmodule SamenCore.TestRepo.Migrations.AiAssistantAssistantConversation do
  @moduledoc """
  OpenClaw-lite assistant (P1) — the org-scoped assistant definition (`ast`, `ai_assistant`)
  + the vault-routed conversation thread under it (`asc`, `ai_assistant_conversation`).

  Allocator-owned abbrevs (`samen.abbrev.reserve --host samen_core` — `ast` = `Samen.AI.Assistant`,
  `asc` = `Samen.AI.AssistantConversation`). The conversation's ONE text artifact
  (`asc_transcript` / `pii_asc_transcript`) is vault-routed precisely like
  `ai_agent_run.pii_arn_transcript` (the `Samen.AI.Agent.Run` durability precedent
  above): the domain column holds a `vt_*` token; the ciphertext lives in
  `pii_vault` under the row's OWN DEK (per-row crypto-shred unit), presentation
  is `%Samen.Masked{}` vs grant-cleared, and `mix samen.verify.*`
  `vault_declared_parity` proves the vault route is declared. `catalog_sync/1`
  keeps `mix samen.verify.catalog_parity` green in the SAME transaction as the
  DDL (ADR-004).
  """

  use Samen.Migration

  @assistant_resources [Samen.AI.Assistant]
  @conversation_resources [Samen.AI.AssistantConversation]

  def up do
    # --- ast_assistant : the named, org-scoped assistant definition (bounded labels; see AssistantChange / FreeTextScan) ---
    create table(:ai_assistant, primary_key: false) do
      add(:ast_name, :text, null: false)
      add(:ast_title, :text, null: false)
      add(:ast_system_prompt, :text, null: false)
      add(:ast_model_id, :text)
      add(:ast_tools, {:array, :text}, null: false, default: [])
      # AshStateMachine-style status is plain text (the apv_state/sas_status precedent).
      add(:ast_status, :text, null: false, default: "active")
      add(:ast_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:ast_org_id, :uuid, null: false)
      add(:ast_inserted_at, :utc_datetime_usec, null: false)
      add(:ast_updated_at, :utc_datetime_usec, null: false)
      add(:ast_archived_at, :utc_datetime_usec)
    end

    create(
      unique_index(:ai_assistant, [:ast_org_id, :ast_name],
        name: "ai_assistant_org_name_index"
      )
    )

    create(index(:ai_assistant, [:ast_org_id], name: "ai_assistant_org_idx"))

    # --- asc_conversation : the bounded thread row under one assistant (vault-routed transcript is the ONE persisted text artifact) ---
    create table(:ai_assistant_conversation, primary_key: false) do
      add(:asc_assistant_id, :uuid, null: false)
      add(:asc_title, :text, null: false)
      add(:asc_status, :text, null: false, default: "active")
      add(:asc_model_id, :text)
      add(:asc_message_count, :bigint, null: false, default: 0)
      add(:asc_total_tokens, :bigint, null: false, default: 0)
      add(:asc_last_message_at, :utc_datetime_usec)
      # Vault-routed transcript (the ONE text artifact the thread manages — JSON of the bounded chat turns,
      # inside the row's OWN DEK envelope, like arn_transcript). The column holds a vt_* token; the vault
      # holds the ciphertext — this IS the `pii_asc_transcript` column `Samen.Pii.Info.storage_name/2` expects.
      add(:pii_asc_transcript, :text)
      add(:asc_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:asc_org_id, :uuid, null: false)
      add(:asc_inserted_at, :utc_datetime_usec, null: false)
      add(:asc_updated_at, :utc_datetime_usec, null: false)
      add(:asc_archived_at, :utc_datetime_usec)
    end

    create(
      index(:ai_assistant_conversation, [:asc_org_id],
        name: "ai_assistant_conversation_org_idx"
      )
    )

    create(
      index(:ai_assistant_conversation, [:asc_assistant_id],
        name: "ai_assistant_conversation_assistant_idx"
      )
    )

    catalog_sync(@assistant_resources)
    catalog_sync(@conversation_resources)
  end

  def down do
    catalog_sync_down(@conversation_resources)
    catalog_sync_down(@assistant_resources)

    drop(index(:ai_assistant_conversation, [:asc_assistant_id], name: "ai_assistant_conversation_assistant_idx"))
    drop(index(:ai_assistant_conversation, [:asc_org_id], name: "ai_assistant_conversation_org_idx"))
    drop(table(:ai_assistant_conversation))

    drop(index(:ai_assistant, [:ast_org_id], name: "ai_assistant_org_idx"))

    drop_if_exists(
      unique_index(:ai_assistant, [:ast_org_id, :ast_name],
        name: "ai_assistant_org_name_index"
      )
    )

    drop(table(:ai_assistant))
  end
end
