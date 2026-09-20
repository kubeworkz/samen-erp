defmodule Samen.Scopes.Fleet.Fuel do
  @moduledoc """
  Fleet Vehicle Fuel (WS-ERP E23;).

  A fuel transaction record for a vehicle.

  ## Design

  - `vehicle_id` — which vehicle
  - `date` — when fuel was added
  - `liters` — amount of fuel in liters
  - `cost` — total cost in minor units
  - `odometer_km` — odometer reading at fill-up
  - `fuel_type` — :diesel | :petrol | :electric | :hybrid
  - `station` — fuel station name (optional)
  - `is_full_tank` — whether the tank was filled completely
  - `consumption_l_per_100km` — computed fuel consumption

  No PII (INV-1). Archivable.
  """

  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.Core.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "fvf",
    archivable: true

  postgres do
    table("fvf_fuel")
    repo(SamenCore.TestRepo)
  end

  attributes do
    attribute(:vehicle_id, :uuid, public?: true, allow_nil?: false)
    attribute(:date, :date, public?: true, allow_nil?: false)
    attribute(:liters, :float, public?: true, allow_nil?: false)
    attribute(:cost, :integer, public?: true, allow_nil?: false)
    attribute(:odometer_km, :integer, public?: true, allow_nil?: false)
    attribute(:fuel_type, :atom, public?: true, allow_nil?: false, default: :diesel)
    attribute(:station, :string, public?: true)
    attribute(:is_full_tank, :boolean, public?: true, allow_nil?: false, default: true)
    attribute(:consumption_l_per_100km, :float, public?: true)
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
