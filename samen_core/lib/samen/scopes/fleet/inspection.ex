defmodule Samen.Scopes.Fleet.Inspection do
  @moduledoc """
  Fleet Vehicle Inspection (WS-ERP E23;).

  An inspection record for a vehicle — pre-trip, annual, or safety.

  ## Design

  - `vehicle_id` — which vehicle
  - `inspection_type` — :pre_trip | :annual | :safety | :custom
  - `result` — :pass | :fail | :conditional
  - `checklist` — JSON array of checklist items with pass/fail
  - `findings` — inspector's notes
  - `inspector_id` — who performed the inspection
  - `inspected_at` — when the inspection was done
  - `odometer_km` — odometer at inspection
  - `next_inspection_date` — when next inspection is due

  No PII (INV-1). Archivable.
  """

  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.Core.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "fvi",
    archivable: true

  postgres do
    table("fvi_inspection")
    repo(SamenCore.TestRepo)
  end

  attributes do
    attribute(:vehicle_id, :uuid, public?: true, allow_nil?: false)
    attribute(:inspection_type, :atom, public?: true, allow_nil?: false, default: :pre_trip)
    attribute(:result, :atom, public?: true, allow_nil?: false, default: :pass)
    attribute(:checklist, :map, public?: true)
    attribute(:findings, :string, public?: true)
    attribute(:inspector_id, :uuid, public?: true)
    attribute(:inspected_at, :utc_datetime_usec, public?: true)
    attribute(:odometer_km, :integer, public?: true)
    attribute(:next_inspection_date, :date, public?: true)
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
