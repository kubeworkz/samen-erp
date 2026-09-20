defmodule Samen.Scopes.Ecommerce.ProductVariant do
  @moduledoc """
  eCommerce ProductVariant (WS-ERP E18;).

  Variants of a product (e.g., "Red / Large / XL"). Each variant
  has its own SKU, price, and optional barcode.

  ## Design

  - `product_id` — parent product
  - `name` — variant name (e.g., "Red / Large")
  - `sku` — variant-specific SKU (unique per store)
  - `barcode` — variant-specific barcode
  - `price` — variant-specific price override (minor units)
  - `is_active` — whether this variant is purchasable

  No PII (INV-1). Archivable.
  """

  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.Core.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "qva",
    archivable: true

  postgres do
    table("qva_product_variant")
    repo(SamenCore.TestRepo)
  end

  attributes do
    attribute(:product_id, :uuid, public?: true, allow_nil?: false)
    attribute(:name, :string, public?: true, allow_nil?: false)
    attribute(:sku, :string, public?: true, allow_nil?: false)
    attribute(:barcode, :string, public?: true)
    attribute(:price, :integer, public?: true, allow_nil?: false)
    attribute(:is_active, :boolean, public?: true, allow_nil?: false, default: true)
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
