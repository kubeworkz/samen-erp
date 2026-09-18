defmodule Samen.Scopes.Finance.OrgFxSettings do
  @moduledoc """
  Per-org FX settings (WS-ERP E10; BigCapital-inspired multi-currency).

  Stores the organization's base currency — the currency in which all
  reports are denominated. Defaults to "USD".

  This is a Tier-0 config row: one row per org, editable by admin+
  members. The base currency is set once at org creation and rarely
  changed (changing it would require re-valuing all historical
  transactions — a migration concern, not a runtime one).

  ## Design

  - `base_currency` — ISO 4217 code (e.g., "USD", "EUR", "GBP")
  - `org_id` — unique per org (one settings row per org)

  No PII (INV-1). Archivable (soft-delete only — the settings row is
  a config row, not a fact).
  """

  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.Core.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "fxf",
    archivable: true

  postgres do
    table("fxf_org_fx_settings")
    repo(SamenCore.TestRepo)
  end

  attributes do
    attribute(:org_id, :uuid, public?: true, allow_nil?: false)
    attribute(:base_currency, :string, public?: true, allow_nil?: false, default: "USD")
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
