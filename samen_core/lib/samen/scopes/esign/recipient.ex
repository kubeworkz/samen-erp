defmodule Samen.Scopes.Esign.Recipient do
  @moduledoc """
  E-Signatures SignRecipient (WS-ERP E26; Flectra-inspired).

  An individual signer or approver on a signing request.

  ## Design

  - `request_id` — reference to SignRequest
  - `name` — signer display name
  - `email` — signer email (vaulted PII)
  - `role` — :signer | :approver | :cc
  - `signing_order` — sequential signing order (1 = first)
  - `status` — :pending | :sent | :viewed | :signed | :declined
  - `signed_at` — when the recipient signed
  - `declined_reason` — reason for decline
  - `access_code` — optional access code for authentication
  - `note` — private note to the signer

  PII: email is vaulted. Archivable.
  """

  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.Core.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "esn",
    archivable: true

  postgres do
    table("esn_recipient")
    repo(SamenCore.TestRepo)
  end

  attributes do
    uuid_primary_key :id
    attribute :request_id, :uuid, allow_nil?: false
    attribute :name, :string, allow_nil?: false

    pii do
      vault :pii_esign_recipient
      attribute :email, :string, allow_nil?: false
    end

    attribute :role, :atom, default: :signer, constraints: [one_of: [:signer, :approver, :cc]]
    attribute :signing_order, :integer, default: 1
    attribute :status, :atom, default: :pending, constraints: [one_of: [:pending, :sent, :viewed, :signed, :declined]]
    attribute :signed_at, :utc_datetime_usec
    attribute :declined_reason, :string
    attribute :access_code, :string
    attribute :note, :string

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  actions do
    defaults [:create, :read, :update, :destroy]

    update :mark_sent do
      require_atomic? false
      change set_attribute(:status, :sent)
    end

    update :mark_viewed do
      require_atomic? false
      change set_attribute(:status, :viewed)
    end

    update :sign do
      require_atomic? false

      change fn changeset, _context ->
        Ash.Changeset.force_change_attribute(changeset, :status, :signed)
        Ash.Changeset.force_change_attribute(changeset, :signed_at, DateTime.utc_now())
      end
    end

    update :decline do
      require_atomic? false
      change set_attribute(:status, :declined)
    end
  end

  policies do
    policy action_type([:read, :create, :update, :destroy]) do
      authorize_if always()
    end
  end
end
