defmodule Samen.Scopes.Ecommerce.CartItem do
  @moduledoc """
  eCommerce CartItem (WS-ERP E18; Flectra-inspired).

  An item in a shopping cart. Tracks the product, variant, quantity,
  and price at time of add (frozen for price consistency).

  ## Design

  - `cart_id` — parent cart
  - `product_id` — the product
  - `variant_id` — optional variant
  - `quantity` — number of items (positive integer)
  - `unit_price` — price at time of add (minor units, frozen)
  - `total` — computed: quantity × unit_price

  No PII (INV-1). Not archivable (cart items are ephemeral).
  """

  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.Core.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "qci"

  postgres do
    table("qci_cart_item")
    repo(SamenCore.TestRepo)
  end

  attributes do
    attribute(:cart_id, :uuid, public?: true, allow_nil?: false)
    attribute(:product_id, :uuid, public?: true, allow_nil?: false)
    attribute(:variant_id, :uuid, public?: true)
    attribute(:quantity, :integer, public?: true, allow_nil?: false)
    attribute(:unit_price, :integer, public?: true, allow_nil?: false)
    attribute(:total, :integer, public?: true, allow_nil?: false)
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
