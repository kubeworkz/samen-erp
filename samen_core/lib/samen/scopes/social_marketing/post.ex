defmodule Samen.Scopes.SocialMarketing.Post do
  @moduledoc """
  Social Marketing Post (WS-ERP E30; Flectra-inspired).

  A social media post to publish.

  ## Design

  - `account_id` — reference to SocialAccount
  - `campaign_id` — reference to SocialCampaign (optional)
  - `content` — post text content
  - `media_urls` — list of image/video URLs
  - `link_url` — optional link to share
  - `status` — :draft | :scheduled | :publishing | :published | :failed | :archived
  - `scheduled_at` — when to publish
  - `published_at` — when published
  - `platform_post_id` — ID from the platform after publishing
  - `hashtags` — list of hashtags
  - `mentions` — list of mentioned accounts

  Lifecycle: draft → scheduled → publishing → published/failed → archived
  No PII (INV-1). Archivable.
  """

  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.Core.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "soj",
    archivable: true

  postgres do
    table("soj_post")
    repo(SamenCore.TestRepo)
  end

  attributes do
    uuid_primary_key :id
    attribute :account_id, :uuid, allow_nil?: false
    attribute :campaign_id, :uuid
    attribute :content, :string, allow_nil?: false
    attribute :media_urls, {:array, :string}, default: []
    attribute :link_url, :string
    attribute :status, :atom, default: :draft, constraints: [one_of: [:draft, :scheduled, :publishing, :published, :failed, :archived]]
    attribute :scheduled_at, :utc_datetime_usec
    attribute :published_at, :utc_datetime_usec
    attribute :platform_post_id, :string
    attribute :hashtags, {:array, :string}, default: []
    attribute :mentions, {:array, :string}, default: []

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  actions do
    defaults [:create, :read, :update, :destroy]

    update :schedule do
      require_atomic? false
      change set_attribute(:status, :scheduled)
    end

    update :publish do
      require_atomic? false

      change fn changeset, _context ->
        Ash.Changeset.force_change_attribute(changeset, :status, :published)
        Ash.Changeset.force_change_attribute(changeset, :published_at, DateTime.utc_now())
      end
    end

    update :mark_failed do
      require_atomic? false
      change set_attribute(:status, :failed)
    end

    update :mark_archived do
      require_atomic? false
      change set_attribute(:status, :archived)
    end
  end

  policies do
    policy action_type([:read, :create, :update, :destroy]) do
      authorize_if always()
    end
  end
end
