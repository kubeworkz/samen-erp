defmodule Samen.Scopes.Hr.LeaveRequest do
  @moduledoc """
  HR Leave Request (WS-ERP E21; Flectra-inspired).

  An employee's request for time off. Goes through an approval workflow.

  ## Design

  - `employee_id` — who is requesting
  - `leave_type_id` — which leave type
  - `start_date` — first day of leave
  - `end_date` — last day of leave
  - `num_days` — number of working days
  - `reason` — optional reason
  - `state` — :draft | :pending | :approved | :rejected | :cancelled
  - `approver_id` — who approved/rejected
  - `approved_at` — when approved
  - `rejection_reason` — why rejected

  No PII (INV-1). Archivable.
  """

  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.Core.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "hlr",
    archivable: true

  postgres do
    table("hlr_leave_request")
    repo(SamenCore.TestRepo)
  end

  attributes do
    attribute(:employee_id, :uuid, public?: true, allow_nil?: false)
    attribute(:leave_type_id, :uuid, public?: true, allow_nil?: false)
    attribute(:start_date, :date, public?: true, allow_nil?: false)
    attribute(:end_date, :date, public?: true, allow_nil?: false)
    attribute(:num_days, :integer, public?: true, allow_nil?: false)
    attribute(:reason, :string, public?: true)
    attribute(:state, :atom, public?: true, allow_nil?: false, default: :draft)
    attribute(:approver_id, :uuid, public?: true)
    attribute(:approved_at, :utc_datetime_usec, public?: true)
    attribute(:rejection_reason, :string, public?: true)
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
