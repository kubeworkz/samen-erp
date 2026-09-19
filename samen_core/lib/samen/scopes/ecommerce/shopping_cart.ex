defmodule Samen.Scopes.Ecommerce.ShoppingCart do
  @moduledoc """
  eCommerce ShoppingCart (WS-ERP E18; Flectra-inspired).

  A user's active shopping cart. One active cart per user per store.
  Carts older than 30 days are considered abandoned.

  ## Design

  - `store_id` — which store this cart belongs to
  - `user_id` — cart owner (nil for guest carts)
  - `session_id` — guest session identifier
  - `status` — :active | :abandoned | :converted
  - `total` — computed total in minor units

  No PII (INV-1). Archivable.
  """

  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.Core.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "qcr",
    archivable: true

  postgres do
    table("qcr_shopping_cart")
    repo(SamenCore.TestRepo)
  end

  attributes do
    attribute(:store_id, :uuid, public?: true, allow_nil?: false)
    attribute(:user_id, :uuid, public?: true)
    attribute(:session_id, :string, public?: true)
    attribute(:status, :atom, public?: true, allow_nil?: false, default: :active)
    attribute(:total, :integer, public?: true, allow_nil?: false, default: 0)
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
