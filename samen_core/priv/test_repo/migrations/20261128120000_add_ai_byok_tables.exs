defmodule SamenCore.TestRepo.Migrations.AddAiByokTables do
  @moduledoc """
  HuggingFace BYOK persistence: the `aik_api_key` and `ail_prompt_log` tables
  backing `Samen.Scopes.Ai.ApiKey` / `Samen.Scopes.Ai.PromptLog`.

  These resources existed with no host table, so the settings surface and the
  daily `VerifyCredentialsWorker` sweep had nothing real to read or write. The
  table/column names are the resource-declared ones (`AshPostgres.DataLayer.Info`
  + the `aik_`/`ail_` abbrev prefixes); `aik_org_id` / `ail_org_id` are the
  injected `Samen.Resource` universal scope column.
  """

  use Ecto.Migration

  def up do
    create table(:aik_api_key, primary_key: false) do
      add(:aik_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:aik_org_id, :uuid, null: false)
      add(:aik_tenant_id, :uuid, null: false)
      add(:aik_name, :text, null: false)
      add(:aik_encrypted_key, :binary)
      add(:aik_encryption_iv, :binary)
      add(:aik_key_prefix, :text)
      add(:aik_status, :text, null: false, default: "pending_validation")
      add(:aik_validated_at, :utc_datetime_usec)
      add(:aik_last_used_at, :utc_datetime_usec)
      add(:aik_expires_at, :utc_datetime_usec)

      add(:aik_scopes, {:array, :text},
        null: false,
        default: fragment("ARRAY['read', 'write']::text[]")
      )

      add(:aik_error_count, :bigint, null: false, default: 0)
      add(:aik_last_error, :text)
      add(:aik_subject_key, :text)
      add(:aik_subject_id, :text)
      add(:aik_inserted_at, :utc_datetime_usec, null: false)
      add(:aik_updated_at, :utc_datetime_usec, null: false)
      add(:aik_archived_at, :utc_datetime_usec)
    end

    create(index(:aik_api_key, [:aik_org_id]))
    create(index(:aik_api_key, [:aik_tenant_id]))
    create(index(:aik_api_key, [:aik_status]))

    create table(:ail_prompt_log, primary_key: false) do
      add(:ail_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:ail_org_id, :uuid, null: false)
      add(:ail_tenant_id, :uuid, null: false)
      add(:ail_api_key_id, :uuid)
      add(:ail_model_id, :text, null: false)
      add(:ail_task_type, :text, null: false, default: "text_generation")
      add(:ail_status, :text, null: false, default: "success")
      add(:ail_input_tokens, :bigint, null: false, default: 0)
      add(:ail_output_tokens, :bigint, null: false, default: 0)
      add(:ail_duration_ms, :bigint)
      add(:ail_streamed, :boolean, null: false, default: false)
      add(:ail_error_type, :text)
      add(:ail_error_message, :text)
      add(:ail_request_params, :map, null: false, default: %{})
      add(:ail_ip_address, :text)
      add(:ail_subject_key, :text)
      add(:ail_subject_id, :text)
      add(:ail_inserted_at, :utc_datetime_usec, null: false)
      add(:ail_updated_at, :utc_datetime, null: false)
    end

    create(index(:ail_prompt_log, [:ail_org_id]))
    create(index(:ail_prompt_log, [:ail_tenant_id]))
    create(index(:ail_prompt_log, [:ail_inserted_at]))
  end

  def down do
    drop(table(:ail_prompt_log))
    drop(table(:aik_api_key))
  end
end
