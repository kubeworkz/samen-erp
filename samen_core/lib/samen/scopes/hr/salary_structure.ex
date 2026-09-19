defmodule Samen.Scopes.Hr.SalaryStructure do
  @moduledoc """
  HR Salary Structure (WS-ERP E21; Flectra-inspired).

  Defines the components of an employee's salary (base, allowances,
  deductions).

  ## Design

  - `name` — structure name (e.g., "Standard Employee")
  - `code` — short code
  - `is_active` — whether this structure is in use
  - `components` — JSON array of salary components:
    - `type` — :basic | :allowance | :deduction | :benefit
    - `name` — component name
    - `code` — component code
    - `amount_type` — :fixed | :percentage
    - `amount` — fixed amount or percentage
    - `sequence` — display order

  No PII (INV-1). Archivable.
  """

  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.Core.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "hss",
    archivable: true

  postgres do
    table("hss_salary_structure")
    repo(SamenCore.TestRepo)
  end

  attributes do
    attribute(:name, :string, public?: true, allow_nil?: false)
    attribute(:code, :string, public?: true, allow_nil?: false)
    attribute(:is_active, :boolean, public?: true, allow_nil?: false, default: true)
    attribute(:components, :map, public?: true)
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
