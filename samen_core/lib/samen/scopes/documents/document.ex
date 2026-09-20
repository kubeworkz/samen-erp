defmodule Samen.Scopes.Documents.Document do
  @moduledoc """
  Document (WS-ERP E32;).

  File metadata and lifecycle for document management.

  ## Design

  - `name` — document title
  - `description` — document description
  - `folder_id` — reference to DocumentFolder
  - `file_name` — original file name
  - `file_size_bytes` — file size
  - `mime_type` — MIME type (e.g. "application/pdf")
  - `storage_url` — URL to stored file
  - `checksum` — file integrity hash (SHA-256)
  - `status` — :draft | :review | :approved | :archived | :deleted
  - `classification` — :public | :internal | :confidential | :secret
  - `owner_id` — user who uploaded
  - `version_number` — current version (e.g. "1.0", "2.1")
  - `tags` — list of tags for search/filter
  - `subject_key` / `subject_id` — object-ref attachment

  Lifecycle: draft → review → approved → archived → deleted
  No PII (INV-1). Archivable.
  """

  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.Core.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "dcn",
    archivable: true

  postgres do
    table("doc_document")
    repo(SamenCore.TestRepo)
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string, allow_nil?: false
    attribute :description, :string
    attribute :folder_id, :uuid
    attribute :file_name, :string, allow_nil?: false
    attribute :file_size_bytes, :integer
    attribute :mime_type, :string
    attribute :storage_url, :string
    attribute :checksum, :string
    attribute :status, :atom, default: :draft,
      constraints: [one_of: [:draft, :review, :approved, :archived, :deleted]]
    attribute :classification, :atom, default: :internal,
      constraints: [one_of: [:public, :internal, :confidential, :secret]]
    attribute :owner_id, :uuid
    attribute :version_number, :string, default: "1.0"
    attribute :tags, {:array, :string}, default: []
    attribute :subject_key, :string
    attribute :subject_id, :string

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  actions do
    defaults [:create, :read, :update, :destroy]

    update :submit_for_review do
      require_atomic? false
      change set_attribute(:status, :review)
    end

    update :approve do
      require_atomic? false
      change set_attribute(:status, :approved)
    end

    update :archive_doc do
      require_atomic? false
      change set_attribute(:status, :archived)
    end

    update :soft_delete do
      require_atomic? false
      change set_attribute(:status, :deleted)
    end

    update :add_tag do
      require_atomic? false

      change fn changeset, _context ->
        tag = Ash.Changeset.get_attribute(changeset, :new_tag)
        current = Ash.Changeset.get_attribute(changeset, :tags) || []
        Ash.Changeset.force_change_attribute(changeset, :tags, current ++ [tag])
      end
    end
  end

  policies do
    policy action_type([:read, :create, :update, :destroy]) do
      authorize_if always()
    end
  end
end
