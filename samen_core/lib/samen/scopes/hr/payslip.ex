defmodule Samen.Scopes.Hr.Payslip do
  @moduledoc """
  HR Payslip (WS-ERP E21;).

  An individual employee's payslip for a pay run. Contains the
  breakdown of earnings, deductions, and net pay.

  ## Design

  - `pay_run_id` — parent pay run
  - `employee_id` — which employee
  - `salary_structure_id` — which salary structure applies
  - `state` — :draft | :computed | :approved | :paid
  - `period_start` — pay period start
  - `period_end` — pay period end
  - `worked_days` — number of days worked
  - `gross_amount` — total earnings before deductions
  - `total_deductions` — total deductions
  - `net_amount` — gross - deductions
  - `earnings` — JSON array of earning components
  - `deductions` — JSON array of deduction components
  - `paid_at` — when the payslip was paid

  No PII (INV-1). Archivable.
  """

  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.Core.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "hps",
    archivable: true

  postgres do
    table("hps_payslip")
    repo(SamenCore.TestRepo)
  end

  attributes do
    attribute(:pay_run_id, :uuid, public?: true, allow_nil?: false)
    attribute(:employee_id, :uuid, public?: true, allow_nil?: false)
    attribute(:salary_structure_id, :uuid, public?: true)
    attribute(:state, :atom, public?: true, allow_nil?: false, default: :draft)
    attribute(:period_start, :date, public?: true, allow_nil?: false)
    attribute(:period_end, :date, public?: true, allow_nil?: false)
    attribute(:worked_days, :integer, public?: true, allow_nil?: false, default: 0)
    attribute(:gross_amount, :integer, public?: true, allow_nil?: false, default: 0)
    attribute(:total_deductions, :integer, public?: true, allow_nil?: false, default: 0)
    attribute(:net_amount, :integer, public?: true, allow_nil?: false, default: 0)
    attribute(:earnings, :map, public?: true)
    attribute(:deductions, :map, public?: true)
    attribute(:paid_at, :utc_datetime_usec, public?: true)
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
