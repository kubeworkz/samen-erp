defmodule Samen.Scopes.EmailMarketing.Template do
  @moduledoc """
  Email Template (WS-ERP E33;).

  Reusable email templates with HTML content and merge tags.

  ## Design

  - `name` — template name
  - `subject` — default subject line (supports {{merge_tags}})
  - `html_body` — HTML email body
  - `plain_body` — plain text fallback
  - `category` — template category (e.g. "newsletter", "promotional", "transactional")
  - `is_active` — whether template is available for use
  - `use_count` — number of times used (denormalized)
  - `preview_text` — preview text shown in inbox
  - `subject_key` / `subject_id` — object-ref attachment

  Archivable.
  """

  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.Core.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "emt",
    archivable: true

  postgres do
    table("emt_template")
    repo(SamenCore.TestRepo)
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string, allow_nil?: false
    attribute :subject, :string
    attribute :html_body, :string
    attribute :plain_body, :string
    attribute :category, :string
    attribute :is_active, :boolean, default: true
    attribute :use_count, :integer, default: 0
    attribute :preview_text, :string
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
