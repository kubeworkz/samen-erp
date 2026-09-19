defmodule Samen.Scopes.Cms.Theme do
  @moduledoc """
  CMS Theme (WS-ERP E37; Flectra-inspired Website Builder).

  Visual themes controlling site appearance.

  ## Design

  - `name` — theme name
  - `description` — theme description
  - `primary_color` — primary brand color (hex)
  - `secondary_color` — secondary color (hex)
  - `font_family` — primary font
  - `logo_url` — logo image URL
  - `favicon_url` — favicon URL
  - `css_variables` — JSON of CSS custom properties
  - `is_active` — whether theme is available
  - `is_default` — whether this is the default theme
  - `subject_key` / `subject_id` — object-ref attachment

  Archivable.
  """

  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.Core.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "cml",
    archivable: true

  postgres do
    table("cml_theme")
    repo(SamenCore.TestRepo)
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string, allow_nil?: false
    attribute :description, :string
    attribute :primary_color, :string, default: "#007bff"
    attribute :secondary_color, :string, default: "#6c757d"
    attribute :font_family, :string, default: "Inter"
    attribute :logo_url, :string
    attribute :favicon_url, :string
    attribute :css_variables, :string
    attribute :is_active, :boolean, default: true
    attribute :is_default, :boolean, default: false
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
  end

  policies do
    policy action_type([:read, :create, :update, :destroy]) do
      authorize_if always()
    end
  end
end
