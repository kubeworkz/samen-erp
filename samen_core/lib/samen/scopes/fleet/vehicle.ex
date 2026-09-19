defmodule Samen.Scopes.Fleet.Vehicle do
  @moduledoc """
  Fleet Vehicle (WS-ERP E23; Flectra-inspired).

  A vehicle in the company fleet.

  ## Design

  - `name` — vehicle display name (e.g., "Ford Transit #42")
  - `make` — manufacturer (e.g., "Ford")
  - `model` — model name (e.g., "Transit")
  - `year` — manufacturing year
  - `license_plate` — registration plate
  - `vin` — vehicle identification number
  - `status` — :active | :maintenance | :retired
  - `odometer_km` — current odometer reading
  - `fuel_type` — :diesel | :petrol | :electric | :hybrid
  - `acquisition_date` — when acquired
  - `acquisition_cost` — purchase/lease cost in minor units
  - `driver_id` — assigned driver (optional)
  - `insurance_expiry` — insurance expiration date
  - `notes` — additional info

  No PII (INV-1). Archivable.
  """

  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.Core.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "fvh",
    archivable: true

  postgres do
    table("fvh_vehicle")
    repo(SamenCore.TestRepo)
  end

  attributes do
    attribute(:name, :string, public?: true, allow_nil?: false)
    attribute(:make, :string, public?: true)
    attribute(:model, :string, public?: true)
    attribute(:year, :integer, public?: true)
    attribute(:license_plate, :string, public?: true)
    attribute(:vin, :string, public?: true)
    attribute(:status, :atom, public?: true, allow_nil?: false, default: :active)
    attribute(:odometer_km, :integer, public?: true, allow_nil?: false, default: 0)
    attribute(:fuel_type, :atom, public?: true, allow_nil?: false, default: :diesel)
    attribute(:acquisition_date, :date, public?: true)
    attribute(:acquisition_cost, :integer, public?: true)
    attribute(:driver_id, :uuid, public?: true)
    attribute(:insurance_expiry, :date, public?: true)
    attribute(:notes, :string, public?: true)
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
