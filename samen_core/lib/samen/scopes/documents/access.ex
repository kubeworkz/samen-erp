defmodule Samen.Scopes.Documents.Access do
  @moduledoc """
  Document Access (WS-ERP E32;).

  Access control and sharing permissions for documents and folders.

  ## Design

  - `document_id` — reference to Document (nil = folder access)
  - `folder_id` — reference to DocumentFolder (nil = document access)
  - `grantee_id` — user or group being granted access
  - `grantee_type` — :user | :group | :role
  - `permission` — :view | :comment | :edit | :admin
  - `is_inherited` — whether permission inherited from parent folder
  - `expires_at` — when access expires (nil = permanent)
  - `granted_by` — who granted the access
  - `subject_key` / `subject_id` — object-ref attachment

  Archivable.
  """

  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.Core.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "dca",
    archivable: true

  postgres do
    table("dca_access")
    repo(SamenCore.TestRepo)
  end

  attributes do
    uuid_primary_key :id
    attribute :document_id, :uuid
    attribute :folder_id, :uuid
    attribute :grantee_id, :uuid, allow_nil?: false
    attribute :grantee_type, :atom, default: :user,
      constraints: [one_of: [:user, :group, :role]]
    attribute :permission, :atom, default: :view,
      constraints: [one_of: [:view, :comment, :edit, :admin]]
    attribute :is_inherited, :boolean, default: false
    attribute :expires_at, :utc_datetime_usec
    attribute :granted_by, :uuid
    attribute :subject_key, :string
    attribute :subject_id, :string

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  actions do
    defaults [:create, :read, :update, :destroy]

    update :grant do
      require_atomic? false

      change fn changeset, _context ->
        Ash.Changeset.force_change_attribute(changeset, :is_inherited, false)
      end
    end

    update :revoke do
      require_atomic? false
      change set_attribute(:permission, nil)
    end

    update :expire do
      require_atomic? false

      change fn changeset, _context ->
        Ash.Changeset.force_change_attribute(changeset, :expires_at, DateTime.utc_now())
      end
    end
  end

  policies do
    policy action_type([:read, :create, :update, :destroy]) do
      authorize_if always()
    end
  end
end
