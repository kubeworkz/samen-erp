defmodule Samen.Scopes.Cms.Page do
  @moduledoc """
  CMS Page (WS-ERP E37; Flectra-inspired Website Builder).

  Content pages with SEO and publishing lifecycle.

  ## Design

  - `title` — page title
  - `slug` — URL slug (unique)
  - `html_content` — page HTML body
  - `template_id` — reference to CmsTemplate
  - `theme_id` — reference to CmsTheme
  - `status` — :draft | :review | :published | :archived
  - `seo_title` — SEO meta title
  - `seo_description` — SEO meta description
  - `seo_keywords` — SEO keywords
  - `published_at` — when published
  - `author_id` — who created the page
  - `is_homepage` — whether this is the homepage
  - `sort_order` — page ordering in navigation
  - `subject_key` / `subject_id` — object-ref attachment

  Lifecycle: draft → review → published → archived
  No PII (INV-1). Archivable.
  """

  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.Core.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "cms",
    archivable: true

  postgres do
    table("cms_page")
    repo(SamenCore.TestRepo)
  end

  attributes do
    uuid_primary_key :id
    attribute :title, :string, allow_nil?: false
    attribute :slug, :string, allow_nil?: false
    attribute :html_content, :string
    attribute :template_id, :uuid
    attribute :theme_id, :uuid
    attribute :status, :atom, default: :draft,
      constraints: [one_of: [:draft, :review, :published, :archived]]
    attribute :seo_title, :string
    attribute :seo_description, :string
    attribute :seo_keywords, {:array, :string}, default: []
    attribute :published_at, :utc_datetime_usec
    attribute :author_id, :uuid
    attribute :is_homepage, :boolean, default: false
    attribute :sort_order, :integer, default: 0
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

    update :publish do
      require_atomic? false

      change fn changeset, _context ->
        Ash.Changeset.force_change_attribute(changeset, :status, :published)
        Ash.Changeset.force_change_attribute(changeset, :published_at, DateTime.utc_now())
      end
    end

    update :archive_page do
      require_atomic? false
      change set_attribute(:status, :archived)
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
