defmodule Samen.Scopes.Social.Analytics do
  @moduledoc """
  Social Marketing Analytics (WS-ERP E22; Flectra-inspired).

  Engagement metrics for social media posts.

  ## Design

  - `post_id` — which post
  - `impressions` — number of times shown
  - `reach` — unique users reached
  - `engagement` — total interactions (likes, comments, shares)
  - `likes` — number of likes
  - `comments` — number of comments
  - `shares` — number of shares
  - `clicks` — number of link clicks
  - `conversions` — number of conversions
  - `engagement_rate` — engagement / impressions * 100
  - `recorded_at` — when the metrics were recorded

  No PII (INV-1). Archivable.
  """

  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.Core.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "soa",
    archivable: true

  postgres do
    table("soa_analytics")
    repo(SamenCore.TestRepo)
  end

  attributes do
    attribute(:post_id, :uuid, public?: true, allow_nil?: false)
    attribute(:impressions, :integer, public?: true, allow_nil?: false, default: 0)
    attribute(:reach, :integer, public?: true, allow_nil?: false, default: 0)
    attribute(:engagement, :integer, public?: true, allow_nil?: false, default: 0)
    attribute(:likes, :integer, public?: true, allow_nil?: false, default: 0)
    attribute(:comments, :integer, public?: true, allow_nil?: false, default: 0)
    attribute(:shares, :integer, public?: true, allow_nil?: false, default: 0)
    attribute(:clicks, :integer, public?: true, allow_nil?: false, default: 0)
    attribute(:conversions, :integer, public?: true, allow_nil?: false, default: 0)
    attribute(:engagement_rate, :float, public?: true, allow_nil?: false, default: 0.0)
    attribute(:recorded_at, :utc_datetime_usec, public?: true)
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
