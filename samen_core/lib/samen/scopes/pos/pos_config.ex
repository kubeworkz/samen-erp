defmodule Samen.Scopes.Pos.PosConfig do
  @moduledoc """
  POS Configuration (WS-ERP E17; point of sale).

  Tier-0 config row: one POS terminal per org (or per location).
  Defines the terminal's behavior, default payment method, receipt
  settings, and operational parameters.

  ## Design

  - `name` — human-readable terminal name (e.g., "Front Counter")
  - `default_payment_method_id` — the default payment method for this terminal
  - `pricelist_id` — the pricing rule set (optional)
  - `receipt_header` / `receipt_footer` — custom receipt text
  - `cash_control` — whether to require cash drawer reconciliation
  - `is_active` — whether the terminal is available for use

  No PII (INV-1). Archivable.
  """

  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.Core.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "zcf",
    archivable: true

  postgres do
    table("zcf_pos_config")
    repo(SamenCore.TestRepo)
  end

  attributes do
    attribute(:name, :string, public?: true, allow_nil?: false)
    attribute(:default_payment_method_id, :uuid, public?: true)
    attribute(:pricelist_id, :uuid, public?: true)
    attribute(:receipt_header, :string, public?: true)
    attribute(:receipt_footer, :string, public?: true)
    attribute(:cash_control, :boolean, public?: true, allow_nil?: false, default: false)
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
