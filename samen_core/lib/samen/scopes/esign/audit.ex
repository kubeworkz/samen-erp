defmodule Samen.Scopes.Esign.Audit do
  @moduledoc """
  E-Signatures SignAudit (WS-ERP E26; Flectra-inspired).

  An immutable audit trail entry for e-signature events.

  ## Design

  - `request_id` — reference to SignRequest
  - `recipient_id` — reference to SignRecipient (optional, for recipient-specific events)
  - `event_type` — :created | :sent | :viewed | :signed | :declined | :expired | :cancelled | :completed | :document_downloaded
  - `description` — human-readable event description
  - `ip_address` — signer IP address
  - `user_agent` — browser/device info
  - `metadata` — JSON map for additional event data

  Immutable: no update/destroy actions. Archivable.
  """

  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.Core.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "esa",
    archivable: true

  postgres do
    table("esa_audit")
    repo(SamenCore.TestRepo)
  end

  attributes do
    uuid_primary_key :id
    attribute :request_id, :uuid, allow_nil?: false
    attribute :recipient_id, :uuid
    attribute :event_type, :atom, allow_nil?: false, constraints: [one_of: [:created, :sent, :viewed, :signed, :declined, :expired, :cancelled, :completed, :document_downloaded]]
    attribute :description, :string
    attribute :ip_address, :string
    attribute :user_agent, :string
    attribute :metadata, :map, default: %{}

    create_timestamp :inserted_at
  end

  actions do
    defaults [:create, :read]

    # No update or destroy — audit trail is immutable
  end

  policies do
    policy action_type([:read, :create]) do
      authorize_if always()
    end
  end
end
