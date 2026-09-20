defmodule Samen.Scopes.Community.BlogPost do
  @moduledoc """
  Community Blog Post (WS-ERP E25;).

  An article/blog post within a blog.

  ## Design

  - `blog_id` — which blog
  - `author_id` — who wrote the post
  - `title` — post title
  - `slug` — URL-friendly identifier
  - `body` — post content (Markdown)
  - `excerpt` — short summary for listings
  - `featured_image_url` — optional hero image
  - `state` — :draft | :review | :published | :archived
  - `published_at` — when the post was published
  - `category` — post category (e.g., "News", "Tutorial")
  - `tags` — JSON array of tags
  - `view_count` — number of views
  - `allow_comments` — whether comments are enabled on this post

  No PII (INV-1). Archivable.
  """

  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.Core.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "cbp",
    archivable: true

  postgres do
    table("cbp_blog_post")
    repo(SamenCore.TestRepo)
  end

  attributes do
    attribute(:blog_id, :uuid, public?: true, allow_nil?: false)
    attribute(:author_id, :uuid, public?: true, allow_nil?: false)
    attribute(:title, :string, public?: true, allow_nil?: false)
    attribute(:slug, :string, public?: true, allow_nil?: false)
    attribute(:body, :string, public?: true, allow_nil?: false)
    attribute(:excerpt, :string, public?: true)
    attribute(:featured_image_url, :string, public?: true)
    attribute(:state, :atom, public?: true, allow_nil?: false, default: :draft)
    attribute(:published_at, :utc_datetime_usec, public?: true)
    attribute(:category, :string, public?: true)
    attribute(:tags, :map, public?: true)
    attribute(:view_count, :integer, public?: true, allow_nil?: false, default: 0)
    attribute(:allow_comments, :boolean, public?: true, allow_nil?: false, default: true)
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
