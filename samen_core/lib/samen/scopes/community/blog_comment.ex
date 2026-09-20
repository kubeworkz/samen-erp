defmodule Samen.Scopes.Community.BlogComment do
  @moduledoc """
  Community Blog Comment (WS-ERP E25;).

  A comment on a blog post.

  ## Design

  - `post_id` — parent blog post
  - `author_id` — who wrote the comment
  - `body` — comment content
  - `state` — :pending | :approved | :rejected | :spam
  - `parent_comment_id` — for nested replies (nil = top-level)
  - `upvotes` — number of upvotes
  - `downvotes` — number of downvotes

  No PII (INV-1). Archivable.
  """

  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.Core.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "bcc",
    archivable: true

  postgres do
    table("bcc_blog_comment")
    repo(SamenCore.TestRepo)
  end

  attributes do
    attribute(:post_id, :uuid, public?: true, allow_nil?: false)
    attribute(:author_id, :uuid, public?: true, allow_nil?: false)
    attribute(:body, :string, public?: true, allow_nil?: false)
    attribute(:state, :atom, public?: true, allow_nil?: false, default: :pending)
    attribute(:parent_comment_id, :uuid, public?: true)
    attribute(:upvotes, :integer, public?: true, allow_nil?: false, default: 0)
    attribute(:downvotes, :integer, public?: true, allow_nil?: false, default: 0)
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
