defmodule Samen.Scopes.Ecommerce.Store do
  @moduledoc """
  eCommerce Store (WS-ERP E18;).

  The storefront configuration — one store per org (or multi-store
  with separate configs). Defines the store's identity, theme, and
  operational settings.

  ## Design

  - `name` — store name (e.g., "My Shop")
  - `slug` — URL-friendly identifier (unique per org)
  - `description` — store description (for SEO)
  - `currency` — ISO 4217 code (default USD)
  - `is_active` — whether the store is live
  - `allow_guest_checkout` — whether non-registered users can buy
  - `tax_inclusive` — whether prices include tax

  No PII (INV-1). Archivable.
  """

  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.Core.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "qst",
    archivable: true

  postgres do
    table("qst_store")
    repo(SamenCore.TestRepo)
  end

  attributes do
    attribute(:name, :string, public?: true, allow_nil?: false)
    attribute(:slug, :string, public?: true, allow_nil?: false)
    attribute(:description, :string, public?: true)
    attribute(:currency, :string, public?: true, allow_nil?: false, default: "USD")
    attribute(:is_active, :boolean, public?: true, allow_nil?: false, default: true)
    attribute(:allow_guest_checkout, :boolean, public?: true, allow_nil?: false, default: true)
    attribute(:tax_inclusive, :boolean, public?: true, allow_nil?: false, default: false)
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
