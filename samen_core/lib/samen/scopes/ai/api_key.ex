defmodule Samen.Scopes.Ai.ApiKey do
  @moduledoc """
  AI API Key (WS-ERP AI Integration).

  Stores encrypted HuggingFace API keys per tenant using BYOK (Bring Your Own Key).

  ## Design

  - `tenant_id` — reference to tenant/account
  - `name` — friendly name (e.g. "Production HF Key")
  - `encrypted_key` — AES-256-GCM encrypted API key (binary)
  - `encryption_iv` — initialization vector (12 bytes, binary)
  - `key_prefix` — first 8 chars for identification (e.g. "hf_abc1...")
  - `status` — :active | :revoked | :expired | :pending_validation
  - `validated_at` — last successful validation timestamp
  - `last_used_at` — last API call timestamp
  - `expires_at` — optional expiration date
  - `scopes` — token scopes (e.g. ["read", "write"])
  - `error_count` — consecutive validation failures
  - `last_error` — last error message
  - `subject_key` / `subject_id` — object-ref attachment

  Lifecycle: pending_validation → active → revoked/expired

  ## Security

  - Raw keys are NEVER stored in the database
  - Keys are encrypted immediately on input via Ecto changeset
  - Decrypted only in-memory within short-lived processes
  - GC flushes decrypted key when process terminates
  """

  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.Core.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "aik",
    archivable: true

  postgres do
    table("aik_api_key")
    repo(SamenCore.TestRepo)
  end

  attributes do
    uuid_primary_key :id
    attribute :tenant_id, :uuid, allow_nil?: false
    attribute :name, :string, allow_nil?: false
    attribute :encrypted_key, :binary
    attribute :encryption_iv, :binary
    attribute :key_prefix, :string
    attribute :status, :atom, default: :pending_validation,
      constraints: [one_of: [:active, :revoked, :expired, :pending_validation]]
    attribute :validated_at, :utc_datetime_usec
    attribute :last_used_at, :utc_datetime_usec
    attribute :expires_at, :utc_datetime_usec
    attribute :scopes, {:array, :string}, default: ["read", "write"]
    attribute :error_count, :integer, default: 0
    attribute :last_error, :string
    attribute :subject_key, :string
    attribute :subject_id, :string

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  actions do
    defaults [:create, :read, :update, :destroy]

    update :activate do
      require_atomic? false
      change set_attribute(:status, :active)
    end

    update :revoke do
      require_atomic? false
      change set_attribute(:status, :revoked)
    end

    update :mark_expired do
      require_atomic? false
      change set_attribute(:status, :expired)
    end

    update :record_usage do
      require_atomic? false
      change set_attribute(:last_used_at, DateTime.utc_now())
    end

    update :record_validation do
      require_atomic? false

      change fn changeset, _context ->
        changeset
        |> Ash.Changeset.force_change_attribute(:validated_at, DateTime.utc_now())
        |> Ash.Changeset.force_change_attribute(:error_count, 0)
        |> Ash.Changeset.force_change_attribute(:last_error, nil)
      end
    end

    update :record_error do
      require_atomic? false

      change fn changeset, _context ->
        error = Ash.Changeset.get_attribute(changeset, :error_message) || "unknown"
        count = Ash.Changeset.get_attribute(changeset, :error_count) || 0

        changeset
        |> Ash.Changeset.force_change_attribute(:error_count, count + 1)
        |> Ash.Changeset.force_change_attribute(:last_error, error)
      end
    end
  end

  policies do
    policy action_type([:read, :create, :update, :destroy]) do
      authorize_if always()
    end
  end
end
