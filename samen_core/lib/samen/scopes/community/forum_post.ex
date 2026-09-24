defmodule Samen.Scopes.Community.ForumPost do
  @moduledoc """
  Community Forum Post (WS-ERP E25;).

  A topic/post in a forum. Users can reply with comments.

  ## Design

  - `forum_id` — which forum
  - `author_id` — who created the post
  - `title` — post title
  - `body` — post content (Markdown)
  - `state` — :draft | :published | :closed | :archived
  - `is_pinned` — whether the post is pinned to top
  - `is_featured` — whether the post is featured
  - `view_count` — number of views
  - `reply_count` — number of replies
  - `last_reply_at` — when the last reply was posted
  - `tags` — JSON array of tags
  - `accepted_answer_id` — ID of the accepted answer (for Q&A forums)

  No PII (INV-1). Archivable.
  """

  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.Core.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "fpo",
    archivable: true

  postgres do
    table("cmp_forum_post")
    repo(SamenCore.TestRepo)
  end

  attributes do
    attribute(:forum_id, :uuid, public?: true, allow_nil?: false)
    attribute(:author_id, :uuid, public?: true, allow_nil?: false)
    attribute(:title, :string, public?: true, allow_nil?: false)
    attribute(:body, :string, public?: true, allow_nil?: false)
    attribute(:state, :atom, public?: true, allow_nil?: false, default: :published)
    attribute(:is_pinned, :boolean, public?: true, allow_nil?: false, default: false)
    attribute(:is_featured, :boolean, public?: true, allow_nil?: false, default: false)
    attribute(:view_count, :integer, public?: true, allow_nil?: false, default: 0)
    attribute(:reply_count, :integer, public?: true, allow_nil?: false, default: 0)
    attribute(:last_reply_at, :utc_datetime_usec, public?: true)
    attribute(:tags, :map, public?: true)
    attribute(:accepted_answer_id, :uuid, public?: true)
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
