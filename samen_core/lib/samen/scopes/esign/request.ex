defmodule Samen.Scopes.Esign.Request do
  @moduledoc """
  E-Signatures SignRequest (WS-ERP E26; Flectra-inspired).

  A signing envelope sent to one or more recipients.

  ## Design

  - `template_id` — reference to SignTemplate (optional, for templated requests)
  - `subject` — email subject line
  - `message` — email message body
  - `status` — :draft | :sent | :viewed | :completed | :declined | :expired | :cancelled
  - `completed_at` — when all signatures were collected
  - `sent_at` — when the request was sent
  - `expires_at` — when the request expires
  - `document_url` — reference to the document to sign
  - `document_hash` — SHA-256 hash for integrity verification
  - `subject_key` / `subject_id` — object-ref attachment (any ERP object)
  - `sender_id` — who initiated the request

  Lifecycle: draft → sent → viewed → completed/declined/expired/cancelled
  No PII (INV-1). Archivable.
  """

  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.Core.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "esr",
    archivable: true

  postgres do
    table("esr_request")
    repo(SamenCore.TestRepo)
  end

  attributes do
    uuid_primary_key :id
    attribute :template_id, :uuid
    attribute :subject, :string, allow_nil?: false
    attribute :message, :string
    attribute :status, :atom, default: :draft, constraints: [one_of: [:draft, :sent, :viewed, :completed, :declined, :expired, :cancelled]]
    attribute :completed_at, :utc_datetime_usec
    attribute :sent_at, :utc_datetime_usec
    attribute :expires_at, :utc_datetime_usec
    attribute :document_url, :string
    attribute :document_hash, :string
    attribute :subject_key, :string
    attribute :subject_id, :string
    attribute :sender_id, :uuid

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  actions do
    defaults [:create, :read, :update, :destroy]

    update :send do
      require_atomic? false

      change fn changeset, _context ->
        Ash.Changeset.force_change_attribute(changeset, :status, :sent)
        Ash.Changeset.force_change_attribute(changeset, :sent_at, DateTime.utc_now())
      end
    end

    update :complete do
      require_atomic? false

      change fn changeset, _context ->
        Ash.Changeset.force_change_attribute(changeset, :status, :completed)
        Ash.Changeset.force_change_attribute(changeset, :completed_at, DateTime.utc_now())
      end
    end

    update :decline do
      require_atomic? false
      change set_attribute(:status, :declined)
    end

    update :expire do
      require_atomic? false
      change set_attribute(:status, :expired)
    end

    update :cancel do
      require_atomic? false
      change set_attribute(:status, :cancelled)
    end
  end

  policies do
    policy action_type([:read, :create, :update, :destroy]) do
      authorize_if always()
    end
  end
end
