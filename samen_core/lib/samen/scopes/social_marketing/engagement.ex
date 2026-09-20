defmodule Samen.Scopes.SocialMarketing.Engagement do
  @moduledoc """
  Social Marketing Engagement (WS-ERP E30;).

  Engagement metrics for a social media post.

  ## Design

  - `post_id` — reference to SocialPost
  - `impressions` — total impressions
  - `reach` — unique accounts reached
  - `likes` — total likes/reactions
  - `comments` — total comments
  - `shares` — total shares/retweets
  - `clicks` — total link clicks
  - `saves` — total saves/bookmarks
  - `engagement_rate` — calculated engagement rate
  - `snapshot_at` — when metrics were captured

  Immutable: append-only metrics snapshots. Archivable.
  """

  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.Core.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "seu",
    archivable: true

  postgres do
    table("seu_engagement")
    repo(SamenCore.TestRepo)
  end

  attributes do
    uuid_primary_key :id
    attribute :post_id, :uuid, allow_nil?: false
    attribute :impressions, :integer, default: 0
    attribute :reach, :integer, default: 0
    attribute :likes, :integer, default: 0
    attribute :comments, :integer, default: 0
    attribute :shares, :integer, default: 0
    attribute :clicks, :integer, default: 0
    attribute :saves, :integer, default: 0
    attribute :engagement_rate, :float, default: 0.0
    attribute :snapshot_at, :utc_datetime_usec, allow_nil?: false

    create_timestamp :inserted_at
  end

  actions do
    defaults [:create, :read]
    # No update or destroy — engagement metrics are append-only snapshots
  end

  policies do
    policy action_type([:read, :create]) do
      authorize_if always()
    end
  end
end
