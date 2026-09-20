defmodule Samen.Scopes.Cms.Template do
  @moduledoc """
  CMS Template (WS-ERP E37; Website Builder).

  Page layout templates with HTML structure.

  ## Design

  - `name` — template name
  - `description` — template description
  - `html_layout` — HTML layout with {{content}} placeholder
  - `css` — template-specific CSS
  - `js` — template-specific JavaScript
  - `is_default` — whether this is the default template
  - `is_active` — whether template is available
  - `use_count` — number of pages using this template
  - `subject_key` / `subject_id` — object-ref attachment

  Archivable.
  """

  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.Core.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "cmn",
    archivable: true

  postgres do
    table("cmn_template")
    repo(SamenCore.TestRepo)
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string, allow_nil?: false
    attribute :description, :string
    attribute :html_layout, :string
    attribute :css, :string
    attribute :js, :string
    attribute :is_default, :boolean, default: false
    attribute :is_active, :boolean, default: true
    attribute :use_count, :integer, default: 0
    attribute :subject_key, :string
    attribute :subject_id, :string

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  actions do
    defaults [:create, :read, :update, :destroy]

    update :deactivate do
      require_atomic? false
      change set_attribute(:is_active, false)
    end

    update :activate do
      require_atomic? false
      change set_attribute(:is_active, true)
    end

    update :set_default do
      require_atomic? false
      change set_attribute(:is_default, true)
    end

    update :increment_use_count do
      require_atomic? false

      change fn changeset, _context ->
        current = Ash.Changeset.get_attribute(changeset, :use_count) || 0
        Ash.Changeset.force_change_attribute(changeset, :use_count, current + 1)
      end
    end
  end

  policies do
    policy action_type([:read, :create, :update, :destroy]) do
      authorize_if always()
    end
  end
end
