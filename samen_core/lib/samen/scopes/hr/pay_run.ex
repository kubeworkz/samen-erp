defmodule Samen.Scopes.Hr.PayRun do
  @moduledoc """
  HR Pay Run (WS-ERP E21; Flectra-inspired).

  A payroll processing period (e.g., "January 2026 Monthly Payroll").

  ## Design

  - `name` — pay run name (e.g., "Jan 2026 Monthly")
  - `period_start` — pay period start date
  - `period_end` — pay period end date
  - `pay_date` — when employees are paid
  - `state` — :draft | :processing | :done | :paid
  - `total_gross` — sum of all gross amounts
  - `total_net` — sum of all net amounts
  - `total_deductions` — sum of all deductions

  No PII (INV-1). Archivable.
  """

  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.Core.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "hpr",
    archivable: true

  postgres do
    table("hpr_pay_run")
    repo(SamenCore.TestRepo)
  end

  attributes do
    attribute(:name, :string, public?: true, allow_nil?: false)
    attribute(:period_start, :date, public?: true, allow_nil?: false)
    attribute(:period_end, :date, public?: true, allow_nil?: false)
    attribute(:pay_date, :date, public?: true, allow_nil?: false)
    attribute(:state, :atom, public?: true, allow_nil?: false, default: :draft)
    attribute(:total_gross, :integer, public?: true, allow_nil?: false, default: 0)
    attribute(:total_net, :integer, public?: true, allow_nil?: false, default: 0)
    attribute(:total_deductions, :integer, public?: true, allow_nil?: false, default: 0)
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
