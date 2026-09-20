defmodule Samen.Scopes.Ai.Model do
  @moduledoc """
  AI Model (WS-ERP AI Integration).

  Registry of HuggingFace models available to tenants.

  ## Design

  - `model_id` — HuggingFace model identifier (e.g. "gpt2", "meta-llama/Llama-2-7b")
  - `display_name` — friendly name
  - `task_type` — primary task type
  - `status` — :available | :deprecated | :private | :rate_limited
  - `is_default` — default model for task type
  - `max_input_tokens` — maximum input token limit
  - `max_output_tokens` — maximum output token limit
  - `pricing_tier` — :free | :pro | :enterprise (for UI display)
  - `requires_pro` — whether model requires Pro subscription
  - `tags` — categorization tags
  - `subject_key` / `subject_id` — object-ref attachment

  """

  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.Core.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "aim"

  postgres do
    table("aim_model")
    repo(SamenCore.TestRepo)
  end

  attributes do
    uuid_primary_key :id
    attribute :model_id, :string, allow_nil?: false
    attribute :display_name, :string, allow_nil?: false
    attribute :task_type, :atom, allow_nil?: false,
      constraints: [one_of: [
        :text_generation, :text_classification, :summarization,
        :translation, :question_answering, :image_classification, :custom
      ]]
    attribute :status, :atom, default: :available,
      constraints: [one_of: [:available, :deprecated, :private, :rate_limited]]
    attribute :is_default, :boolean, default: false
    attribute :max_input_tokens, :integer, default: 4096
    attribute :max_output_tokens, :integer, default: 1024
    attribute :pricing_tier, :atom, default: :free,
      constraints: [one_of: [:free, :pro, :enterprise]]
    attribute :requires_pro, :boolean, default: false
    attribute :tags, {:array, :string}, default: []
    attribute :subject_key, :string
    attribute :subject_id, :string

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  actions do
    defaults [:create, :read, :update, :destroy]

    update :set_default do
      require_atomic? false
      change set_attribute(:is_default, true)
    end

    update :deprecate do
      require_atomic? false
      change set_attribute(:status, :deprecated)
    end

    update :enable do
      require_atomic? false
      change set_attribute(:status, :available)
    end

    update :disable do
      require_atomic? false
      change set_attribute(:status, :rate_limited)
    end
  end

  policies do
    policy action_type([:read, :create, :update, :destroy]) do
      authorize_if always()
    end
  end
end
