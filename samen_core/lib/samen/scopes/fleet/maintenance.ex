defmodule Samen.Scopes.Fleet.Maintenance do
  @moduledoc """
  Fleet Vehicle Maintenance (WS-ERP E23;).

  A maintenance record for a vehicle — scheduled or unscheduled.

  ## Design

  - `vehicle_id` — which vehicle
  - `maintenance_type` — :scheduled | :unscheduled | :repair | :recall
  - `description` — what was done
  - `odometer_km` — odometer reading at time of maintenance
  - `cost` — cost in minor units
  - `vendor` — who performed the work
  - `started_at` — when work started
  - `completed_at` — when work was completed
  - `next_service_km` — next service due at this odometer
  - `next_service_date` — next service due by this date

  No PII (INV-1). Archivable.
  """

  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.Core.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "fvm",
    archivable: true

  postgres do
    table("fvm_maintenance")
    repo(SamenCore.TestRepo)
  end

  attributes do
    attribute(:vehicle_id, :uuid, public?: true, allow_nil?: false)
    attribute(:maintenance_type, :atom, public?: true, allow_nil?: false, default: :scheduled)
    attribute(:description, :string, public?: true)
    attribute(:odometer_km, :integer, public?: true)
    attribute(:cost, :integer, public?: true, allow_nil?: false, default: 0)
    attribute(:vendor, :string, public?: true)
    attribute(:started_at, :utc_datetime_usec, public?: true)
    attribute(:completed_at, :utc_datetime_usec, public?: true)
    attribute(:next_service_km, :integer, public?: true)
    attribute(:next_service_date, :date, public?: true)
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
