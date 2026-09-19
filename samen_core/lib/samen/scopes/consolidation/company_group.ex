defmodule Samen.Scopes.Consolidation.CompanyGroup do
  @moduledoc """
  Multi-Company Group (WS-ERP E24; Flectra-inspired).

  Defines a group of companies for consolidation reporting.
  A group has one parent (holding) company and zero or more subsidiaries.

  ## Design

  - `name` — group name (e.g., "Acme Holdings")
  - `parent_org_id` — the parent/holding org
  - `subsidiary_org_ids` — JSON array of subsidiary org IDs
  - `base_currency` — group-level base currency (e.g., "USD")
  - `fiscal_year_end` — month/day when fiscal year ends (e.g., "12-31")
  - `is_active` — whether this group is active
  - `consolidation_method` — :full | :proportional | :equity

  No PII (INV-1). Archivable.
  """

  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.Core.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "ccg",
    archivable: true

  postgres do
    table("ccg_company_group")
    repo(SamenCore.TestRepo)
  end

  attributes do
    attribute(:name, :string, public?: true, allow_nil?: false)
    attribute(:parent_org_id, :uuid, public?: true, allow_nil?: false)
    attribute(:subsidiary_org_ids, :map, public?: true, allow_nil?: false)
    attribute(:base_currency, :string, public?: true, allow_nil?: false, default: "USD")
    attribute(:fiscal_year_end, :string, public?: true, allow_nil?: false, default: "12-31")
    attribute(:is_active, :boolean, public?: true, allow_nil?: false, default: true)
    attribute(:consolidation_method, :atom, public?: true, allow_nil?: false, default: :full)
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
