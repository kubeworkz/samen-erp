defmodule Samen.Scopes.Ai.Conversation do
  @moduledoc """
  AI Conversation (WS-ERP AI Integration).

  Chat conversation history with HuggingFace models.

  ## Design

  - `tenant_id` — reference to tenant/account
  - `user_id` — reference to user
  - `api_key_id` — which API key was used
  - `title` — conversation title (auto-generated or manual)
  - `model_id` — model used
  - `status` — :active | :archived | :deleted
  - `message_count` — total messages in conversation
  - `total_tokens` — total tokens consumed
  - `last_message_at` — timestamp of last message
  - `subject_key` / `subject_id` — object-ref attachment

  """

  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.Core.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "aic",
    archivable: true

  postgres do
    table("aic_conversation")
    repo(SamenCore.TestRepo)
  end

  attributes do
    uuid_primary_key :id
    attribute :tenant_id, :uuid, allow_nil?: false
    attribute :user_id, :uuid
    attribute :api_key_id, :uuid
    attribute :title, :string
    attribute :model_id, :string
    attribute :status, :atom, default: :active,
      constraints: [one_of: [:active, :archived, :deleted]]
    attribute :message_count, :integer, default: 0
    attribute :total_tokens, :integer, default: 0
    attribute :last_message_at, :utc_datetime_usec
    attribute :subject_key, :string
    attribute :subject_id, :string

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  actions do
    defaults [:create, :read, :update, :destroy]

    update :archive_conversation do
      require_atomic? false
      change set_attribute(:status, :archived)
    end

    update :record_message do
      require_atomic? false

      change fn changeset, _context ->
        count = Ash.Changeset.get_attribute(changeset, :message_count) || 0
        tokens = Ash.Changeset.get_attribute(changeset, :tokens_used) || 0

        changeset
        |> Ash.Changeset.force_change_attribute(:message_count, count + 1)
        |> Ash.Changeset.force_change_attribute(:total_tokens, (changeset.data.total_tokens || 0) + tokens)
        |> Ash.Changeset.force_change_attribute(:last_message_at, DateTime.utc_now())
      end
    end

    update :rename do
      require_atomic? false
      accept [:title]
    end
  end

  policies do
    policy action_type([:read, :create, :update, :destroy]) do
      authorize_if always()
    end
  end
end
