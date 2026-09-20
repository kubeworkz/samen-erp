defmodule Samen.Scopes.Social.Post do
  @moduledoc """
  Social Marketing Post (WS-ERP E22;).

  An individual social media post within a campaign.

  ## Design

  - `campaign_id` — parent campaign
  - `platform` — :facebook | :twitter | :linkedin | :instagram
  - `content` — post text
  - `media_urls` — JSON array of media URLs
  - `scheduled_at` — when the post is scheduled
  - `published_at` — when the post was published
  - `state` — :draft | :scheduled | :published | :failed
  - `post_url` — URL of the published post
  - ` hashtags` — JSON array of hashtags

  No PII (INV-1). Archivable.
  """

  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.Core.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "sop",
    archivable: true

  postgres do
    table("sop_post")
    repo(SamenCore.TestRepo)
  end

  attributes do
    attribute(:campaign_id, :uuid, public?: true, allow_nil?: false)
    attribute(:platform, :atom, public?: true, allow_nil?: false)
    attribute(:content, :string, public?: true, allow_nil?: false)
    attribute(:media_urls, :map, public?: true)
    attribute(:scheduled_at, :utc_datetime_usec, public?: true)
    attribute(:published_at, :utc_datetime_usec, public?: true)
    attribute(:state, :atom, public?: true, allow_nil?: false, default: :draft)
    attribute(:post_url, :string, public?: true)
    attribute(:hashtags, :map, public?: true)
  end

  actions do
    defaults([:read, create: :*, update: :*])
  end

  policies do
    policy action_type(:read) do
      authorize_if(Samen.Policy.OrgScope)
    end

    policy action_type([:create, :update, :destroy]) do
      forbid_unless(Samen.Policy.OrgScope)
      authorize_if(always())
    end
  end
end
