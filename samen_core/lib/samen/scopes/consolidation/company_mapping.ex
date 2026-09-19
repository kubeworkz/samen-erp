defmodule Samen.Scopes.Consolidation.CompanyMapping do
  @moduledoc """
  Multi-Company Account Mapping (WS-ERP E24; Flectra-inspired).

  Maps accounts from subsidiary companies to the parent company's
  chart of accounts for consolidation.

  ## Design

  - `group_id` — parent company group
  - `subsidiary_org_id` — which subsidiary
  - `subsidiary_account_id` — account in the subsidiary
  - `parent_account_id` — mapped account in the parent
  - `mapping_type` — :direct | :adjustment | :elimination
  - `conversion_rate` — optional currency conversion rate
  - `is_active` — whether this mapping is active

  No PII (INV-1). Archivable.
  """

  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.Core.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "ccm",
    archivable: true

  postgres do
    table("ccm_company_mapping")
    repo(SamenCore.TestRepo)
  end

  attributes do
    attribute(:group_id, :uuid, public?: true, allow_nil?: false)
    attribute(:subsidiary_org_id, :uuid, public?: true, allow_nil?: false)
    attribute(:subsidiary_account_id, :uuid, public?: true, allow_nil?: false)
    attribute(:parent_account_id, :uuid, public?: true, allow_nil?: false)
    attribute(:mapping_type, :atom, public?: true, allow_nil?: false, default: :direct)
    attribute(:conversion_rate, :float, public?: true)
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
