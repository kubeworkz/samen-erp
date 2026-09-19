defmodule Samen.Scopes.Community.ForumComment do
  @moduledoc """
  Community Forum Comment (WS-ERP E25; Flectra-inspired).

  A reply/comment on a forum post.

  ## Design

  - `post_id` — parent post
  - `author_id` — who wrote the comment
  - `body` — comment content (Markdown)
  - `state` — :published | :hidden | :deleted
  - `is_accepted` — whether this is the accepted answer
  - `upvotes` — number of upvotes
  - `downvotes` — number of downvotes
  - `parent_comment_id` — for nested replies (nil = top-level)

  No PII (INV-1). Archivable.
  """

  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.Core.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "cmc",
    archivable: true

  postgres do
    table("cmc_forum_comment")
    repo(SamenCore.TestRepo)
  end

  attributes do
    attribute(:post_id, :uuid, public?: true, allow_nil?: false)
    attribute(:author_id, :uuid, public?: true, allow_nil?: false)
    attribute(:body, :string, public?: true, allow_nil?: false)
    attribute(:state, :atom, public?: true, allow_nil?: false, default: :published)
    attribute(:is_accepted, :boolean, public?: true, allow_nil?: false, default: false)
    attribute(:upvotes, :integer, public?: true, allow_nil?: false, default: 0)
    attribute(:downvotes, :integer, public?: true, allow_nil?: false, default: 0)
    attribute(:parent_comment_id, :uuid, public?: true)
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
