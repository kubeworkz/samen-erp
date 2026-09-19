defmodule Samen.Scopes.Ecommerce.Product do
  @moduledoc """
  eCommerce Product (WS-ERP E18; Flectra-inspired).

  A sellable item in the store catalog. Maps to the inventory Item
  for stock tracking.

  ## Design

  - `name` — product name
  - `slug` — URL-friendly identifier (unique per store)
  - `description` — product description (Markdown)
  - `base_price` — price in minor units (cents)
  - `compare_at_price` — optional "was" price for discounts
  - `sku` — stock-keeping unit (unique per store)
  - `barcode` — optional barcode for POS scanning
  - `is_active` — whether the product is visible in the catalog
  - `weight` — optional weight in grams
  - `tax_rate` — optional tax rate override (decimal)

  Links to inventory Item for stock tracking.
  No PII (INV-1). Archivable.
  """

  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.Core.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "qpd",
    archivable: true

  postgres do
    table("qpd_product")
    repo(SamenCore.TestRepo)
  end

  attributes do
    attribute(:name, :string, public?: true, allow_nil?: false)
    attribute(:slug, :string, public?: true, allow_nil?: false)
    attribute(:description, :string, public?: true)
    attribute(:base_price, :integer, public?: true, allow_nil?: false)
    attribute(:compare_at_price, :integer, public?: true)
    attribute(:sku, :string, public?: true, allow_nil?: false)
    attribute(:barcode, :string, public?: true)
    attribute(:is_active, :boolean, public?: true, allow_nil?: false, default: true)
    attribute(:weight, :integer, public?: true)
    attribute(:tax_rate, :decimal, public?: true)
    attribute(:item_id, :uuid, public?: true)
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
