defmodule Samen.WebTest.Repo.Migrations.AiAssistantAssistantConversation do
  @moduledoc """
  OpenClaw-lite assistant (P1) — mirrors `samen_core/priv/test_repo/migrations/20260925100000_ai_assistant_assistant_conversation.exs`
  byte-for-byte apart from the module name (the `ai_agent_run` mirror precedent).

  The agent-loop tables are carried in BOTH test repos so `samen_web` render
  tests can exercise a real vault-routed transcript against their own scratch DB
  (the same reason `ai_agent_run` / `ai_agent_turn` are mirrored). The assistant
  pair carries the same property: the vault-routed transcript (`pii_asc_transcript`)
  is exercised via `Samen.WebTest.Repo` + `Samen.Api.PiiResolution` in `AssistantLive`.

  Allocator-owned abbrevs (`ast`, `asc` on `samen_core`); `catalog_sync` keeps
  `mix samen.verify.catalog_parity` green per repo.
  """

  use Samen.Migration

  @assistant_resources [Samen.AI.Assistant]
  @conversation_resources [Samen.AI.AssistantConversation]

  def up do
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

    create(
      unique_index(:ai_assistant, [:ast_org_id, :ast_name],
        name: "ai_assistant_org_name_index"
      )
    )

    create(index(:ai_assistant, [:ast_org_id], name: "ai_assistant_org_idx"))

    create table(:ai_assistant_conversation, primary_key: false) do
      add(:asc_assistant_id, :uuid, null: false)
      add(:asc_title, :text, null: false)
      add(:asc_status, :text, null: false, default: "active")
      add(:asc_model_id, :text)
      add(:asc_message_count, :bigint, null: false, default: 0)
      add(:asc_total_tokens, :bigint, null: false, default: 0)
      add(:asc_last_message_at, :utc_datetime_usec)
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
