defmodule Samen.Scopes.Hr.LeaveType do
  @moduledoc """
  HR Leave Type (WS-ERP E21; Flectra-inspired).

  Defines the types of leave available (vacation, sick, personal, etc.).

  ## Design

  - `name` — leave type name (e.g., "Annual Vacation")
  - `code` — short code (e.g., "AV", "SL", "PL")
  - `is_paid` — whether this leave type is paid
  - `is_active` — whether this leave type is available
  - `default_days` — default annual allocation
  - `carry_forward` — whether unused days carry forward
  - `max_carry_forward` — maximum days that can be carried forward
  - `requires_approval` — whether manager approval is required
  - `color` — display color for UI

  No PII (INV-1). Archivable.
  """

  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.Core.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "hlt",
    archivable: true

  postgres do
    table("hlt_leave_type")
    repo(SamenCore.TestRepo)
  end

  attributes do
    attribute(:name, :string, public?: true, allow_nil?: false)
    attribute(:code, :string, public?: true, allow_nil?: false)
    attribute(:is_paid, :boolean, public?: true, allow_nil?: false, default: true)
    attribute(:is_active, :boolean, public?: true, allow_nil?: false, default: true)
    attribute(:default_days, :integer, public?: true, allow_nil?: false, default: 0)
    attribute(:carry_forward, :boolean, public?: true, allow_nil?: false, default: false)
    attribute(:max_carry_forward, :integer, public?: true, default: 0)
    attribute(:requires_approval, :boolean, public?: true, allow_nil?: false, default: true)
    attribute(:color, :string, public?: true)
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
