defmodule Samen.Scopes.Documents.Version do
  @moduledoc """
  Document Version (WS-ERP E32;).

  Version control for documents — tracks every revision.

  ## Design

  - `document_id` — reference to Document
  - `version_number` — version label (e.g. "1.0", "2.1")
  - `file_name` — file name at this version
  - `file_size_bytes` — file size at this version
  - `storage_url` — URL to stored file at this version
  - `checksum` — file integrity hash
  - `change_summary` — what changed in this version
  - `created_by` — user who created this version
  - `is_current` — whether this is the active version
  - `subject_key` / `subject_id` — object-ref attachment

  Archivable.
  """

  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.Core.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "dcv",
    archivable: true

  postgres do
    table("dcv_version")
    repo(SamenCore.TestRepo)
  end

  attributes do
    uuid_primary_key :id
    attribute :document_id, :uuid, allow_nil?: false
    attribute :version_number, :string, allow_nil?: false
    attribute :file_name, :string
    attribute :file_size_bytes, :integer
    attribute :storage_url, :string
    attribute :checksum, :string
    attribute :change_summary, :string
    attribute :created_by, :uuid
    attribute :is_current, :boolean, default: true
    attribute :subject_key, :string
    attribute :subject_id, :string

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  actions do
    defaults [:create, :read, :update, :destroy]

    update :set_current do
      require_atomic? false
      change set_attribute(:is_current, true)
    end

    update :unset_current do
      require_atomic? false
      change set_attribute(:is_current, false)
    end
  end

  policies do
    policy action_type([:read, :create, :update, :destroy]) do
      authorize_if always()
    end
  end
end
