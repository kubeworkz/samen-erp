defmodule Samen.Scopes.Community.Forum do
  @moduledoc """
  Community Forum (WS-ERP E25; Flectra-inspired).

  A discussion forum where users can create topics and reply.

  ## Design

  - `name` — forum name (e.g., "Product Support")
  - `slug` — URL-friendly identifier
  - `description` — forum description
  - `is_active` — whether the forum is visible
  - `allow_anonymous` — whether anonymous users can post
  - `moderation_required` — whether posts need approval
  - `category` — forum category (e.g., "Support", "General")
  - `sort_order` — display order

  No PII (INV-1). Archivable.
  """

  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.Core.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "cmf",
    archivable: true

  postgres do
    table("cmf_forum")
    repo(SamenCore.TestRepo)
  end

  attributes do
    attribute(:name, :string, public?: true, allow_nil?: false)
    attribute(:slug, :string, public?: true, allow_nil?: false)
    attribute(:description, :string, public?: true)
    attribute(:is_active, :boolean, public?: true, allow_nil?: false, default: true)
    attribute(:allow_anonymous, :boolean, public?: true, allow_nil?: false, default: false)
    attribute(:moderation_required, :boolean, public?: true, allow_nil?: false, default: false)
    attribute(:category, :string, public?: true)
    attribute(:sort_order, :integer, public?: true, allow_nil?: false, default: 0)
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
