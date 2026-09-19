defmodule Samen.Scopes.Ecommerce.StoreOrder do
  @moduledoc """
  eCommerce StoreOrder (WS-ERP E18; Flectra-inspired).

  An order created when a cart is checked out. Tracks the full
  lifecycle from checkout to delivery.

  ## Design

  - `store_id` — which store
  - `cart_id` — source cart (nil after archive)
  - `user_id` — customer (nil for guest)
  - `order_number` — human-readable number (unique per store)
  - `status` — :pending | :confirmed | :processing | :shipped | :delivered | :cancelled
  - `subtotal` — sum of line totals (minor units)
  - `tax_total` — computed tax
  - `shipping_total` — shipping cost
  - `grand_total` — subtotal + tax + shipping
  - `shipping_address` — JSON address blob
  - `billing_address` — JSON address blob
  - `notes` — optional order notes

  No PII (INV-1). Archivable.
  """

  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.Core.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "qso",
    archivable: true

  postgres do
    table("qso_store_order")
    repo(SamenCore.TestRepo)
  end

  attributes do
    attribute(:store_id, :uuid, public?: true, allow_nil?: false)
    attribute(:cart_id, :uuid, public?: true)
    attribute(:user_id, :uuid, public?: true)
    attribute(:order_number, :string, public?: true, allow_nil?: false)
    attribute(:status, :atom, public?: true, allow_nil?: false, default: :pending)
    attribute(:subtotal, :integer, public?: true, allow_nil?: false, default: 0)
    attribute(:tax_total, :integer, public?: true, allow_nil?: false, default: 0)
    attribute(:shipping_total, :integer, public?: true, allow_nil?: false, default: 0)
    attribute(:grand_total, :integer, public?: true, allow_nil?: false, default: 0)
    attribute(:shipping_address, :map, public?: true)
    attribute(:billing_address, :map, public?: true)
    attribute(:notes, :string, public?: true)
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
