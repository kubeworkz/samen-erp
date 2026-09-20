defmodule Samen.Scopes.Ai.PromptLog do
  @moduledoc """
  AI Prompt Log (WS-ERP AI Integration).

  Tracks every HuggingFace API call for usage analytics and monitoring.

  ## Design

  - `tenant_id` — reference to tenant/account
  - `api_key_id` — which API key was used
  - `model_id` — HuggingFace model identifier
  - `task_type` — :text_generation | :text_classification | :summarization | :translation | :question_answering | :image_classification | :custom
  - `status` — :success | :failed | :timeout | :rate_limited
  - `input_tokens` — estimated input token count
  - `output_tokens` — generated output token count
  - `duration_ms` — request duration in milliseconds
  - `streamed` — whether response was streamed
  - `error_type` — nil | "401_revoked" | "429_rate_limit" | "timeout" | "network_error"
  - `error_message` — detailed error message
  - `request_params` — JSON of request parameters (max_tokens, temperature, etc.)
  - `ip_address` — client IP for abuse detection
  - `subject_key` / `subject_id` — object-ref attachment

  Immutable — logs are never updated after creation.
  """

  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.Core.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "ail"

  postgres do
    table("ail_prompt_log")
    repo(SamenCore.TestRepo)
  end

  attributes do
    uuid_primary_key :id
    attribute :tenant_id, :uuid, allow_nil?: false
    attribute :api_key_id, :uuid
    attribute :model_id, :string, allow_nil?: false
    attribute :task_type, :atom, default: :text_generation,
      constraints: [one_of: [
        :text_generation, :text_classification, :summarization,
        :translation, :question_answering, :image_classification, :custom
      ]]
    attribute :status, :atom, default: :success,
      constraints: [one_of: [:success, :failed, :timeout, :rate_limited]]
    attribute :input_tokens, :integer, default: 0
    attribute :output_tokens, :integer, default: 0
    attribute :duration_ms, :integer
    attribute :streamed, :boolean, default: false
    attribute :error_type, :string
    attribute :error_message, :string
    attribute :request_params, :map, default: %{}
    attribute :ip_address, :string
    attribute :subject_key, :string
    attribute :subject_id, :string

    create_timestamp :inserted_at
  end

  actions do
    defaults [:create, :read, :destroy]

    create :log_success do
      accept [
        :tenant_id, :api_key_id, :model_id, :task_type,
        :input_tokens, :output_tokens, :duration_ms, :streamed,
        :request_params, :ip_address
      ]

      change set_attribute(:status, :success)
    end

    create :log_failure do
      accept [
        :tenant_id, :api_key_id, :model_id, :task_type,
        :duration_ms, :streamed, :error_type, :error_message,
        :request_params, :ip_address
      ]

      change set_attribute(:status, :failed)
    end

    create :log_timeout do
      accept [:tenant_id, :api_key_id, :model_id, :task_type, :duration_ms]

      change fn changeset, _context ->
        changeset
        |> Ash.Changeset.force_change_attribute(:status, :timeout)
        |> Ash.Changeset.force_change_attribute(:error_type, "timeout")
      end
    end

    create :log_rate_limited do
      accept [:tenant_id, :api_key_id, :model_id, :task_type, :duration_ms]

      change fn changeset, _context ->
        changeset
        |> Ash.Changeset.force_change_attribute(:status, :rate_limited)
        |> Ash.Changeset.force_change_attribute(:error_type, "429_rate_limit")
      end
    end
  end

  policies do
    policy action_type([:read, :create, :destroy]) do
      authorize_if always()
    end
  end
end
