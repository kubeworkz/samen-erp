defmodule Samen.Scopes.Documents.Folder do
  @moduledoc """
  Document Folder (WS-ERP E32;).

  Hierarchical folder structure for organizing documents.

  ## Design

  - `name` — folder name
  - `description` — folder description
  - `parent_id` — parent folder (nil = root)
  - `path` — materialized path (e.g. "/root/contracts/2026")
  - `depth` — nesting depth (0 = root)
  - `owner_id` — user who created the folder
  - `is_shared` — whether folder is shared with others
  - `is_archived` — whether folder is archived
  - `document_count` — number of documents in folder (denormalized)
  - `subject_key` / `subject_id` — object-ref attachment

  Archivable.
  """

  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.Core.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "dcf",
    archivable: true

  postgres do
    table("dcf_folder")
    repo(SamenCore.TestRepo)
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string, allow_nil?: false
    attribute :description, :string
    attribute :parent_id, :uuid
    attribute :path, :string
    attribute :depth, :integer, default: 0
    attribute :owner_id, :uuid
    attribute :is_shared, :boolean, default: false
    attribute :is_archived, :boolean, default: false
    attribute :document_count, :integer, default: 0
    attribute :subject_key, :string
    attribute :subject_id, :string

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  actions do
    defaults [:create, :read, :update, :destroy]

    update :share do
      require_atomic? false
      change set_attribute(:is_shared, true)
    end

    update :unshare do
      require_atomic? false
      change set_attribute(:is_shared, false)
    end

    update :archive_folder do
      require_atomic? false
      change set_attribute(:is_archived, true)
    end

    update :restore_folder do
      require_atomic? false
      change set_attribute(:is_archived, false)
    end
  end

  policies do
    policy action_type([:read, :create, :update, :destroy]) do
      authorize_if always()
    end
  end
end
