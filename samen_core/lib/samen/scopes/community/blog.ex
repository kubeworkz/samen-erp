defmodule Samen.Scopes.Community.Blog do
  @moduledoc """
  Community Blog (WS-ERP E25; Flectra-inspired).

  A blog publication with posts, categories, and author management.

  ## Design

  - `name` — blog name (e.g., "Company News")
  - `slug` — URL-friendly identifier
  - `description` — blog description
  - `is_active` — whether the blog is visible
  - `default_author_id` — default author for posts
  - `allow_comments` — whether comments are enabled

  No PII (INV-1). Archivable.
  """

  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.Core.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "cmb",
    archivable: true

  postgres do
    table("cmb_blog")
    repo(SamenCore.TestRepo)
  end

  attributes do
    attribute(:name, :string, public?: true, allow_nil?: false)
    attribute(:slug, :string, public?: true, allow_nil?: false)
    attribute(:description, :string, public?: true)
    attribute(:is_active, :boolean, public?: true, allow_nil?: false, default: true)
    attribute(:default_author_id, :uuid, public?: true)
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
      forbid_unless({Samen.Policy.RoleAtLeast, role: :admin})
      authorize_if(always())
    end
  end
end
