defmodule Samen.Scopes.Esign.Template do
  @moduledoc """
  E-Signatures SignTemplate (WS-ERP E26; Flectra-inspired).

  A reusable document template for e-signature requests.

  ## Design

  - `name` — template display name
  - `description` — template description
  - `subject` — email subject for signing requests
  - `message` — email message body
  - `status` — :draft | :published
  - `document_url` — reference to the template document
  - `document_hash` — SHA-256 hash of the document for integrity
  - `redirect_url` — URL to redirect after signing
  - ` expires_at` — default expiration for requests using this template

  No PII (INV-1). Archivable.
  """

  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.Core.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "est",
    archivable: true

  postgres do
    table("est_template")
    repo(SamenCore.TestRepo)
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string, allow_nil?: false
    attribute :description, :string
    attribute :subject, :string, allow_nil?: false
    attribute :message, :string
    attribute :status, :atom, default: :draft, constraints: [one_of: [:draft, :published]]
    attribute :document_url, :string
    attribute :document_hash, :string
    attribute :redirect_url, :string
    attribute :default_expiry_days, :integer, default: 30

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  actions do
    defaults [:create, :read, :update, :destroy]

    update :publish do
      require_atomic? false
      change set_attribute(:status, :published)
    end

    update :unpublish do
      require_atomic? false
      change set_attribute(:status, :draft)
    end
  end

  policies do
    policy action_type([:read, :create, :update, :destroy]) do
      authorize_if always()
    end
  end
end
