defmodule Samen.Scopes.Hr.LeaveBalance do
  @moduledoc """
  HR Leave Balance (WS-ERP E21; Flectra-inspired).

  Tracks the remaining leave days per employee per leave type per year.

  ## Design

  - `employee_id` — which employee
  - `leave_type_id` — which leave type
  - `year` — which year (e.g., 2026)
  - `total_days` — total allocation for the year
  - `used_days` — days used so far
  - `pending_days` — days in pending requests
  - `available_days` — computed: total - used - pending
  - `carried_forward` — days carried forward from previous year

  No PII (INV-1). Archivable.
  """

  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.Core.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "hlb",
    archivable: true

  postgres do
    table("hlb_leave_balance")
    repo(SamenCore.TestRepo)
  end

  attributes do
    attribute(:employee_id, :uuid, public?: true, allow_nil?: false)
    attribute(:leave_type_id, :uuid, public?: true, allow_nil?: false)
    attribute(:year, :integer, public?: true, allow_nil?: false)
    attribute(:total_days, :integer, public?: true, allow_nil?: false, default: 0)
    attribute(:used_days, :integer, public?: true, allow_nil?: false, default: 0)
    attribute(:pending_days, :integer, public?: true, allow_nil?: false, default: 0)
    attribute(:available_days, :integer, public?: true, allow_nil?: false, default: 0)
    attribute(:carried_forward, :integer, public?: true, allow_nil?: false, default: 0)
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
