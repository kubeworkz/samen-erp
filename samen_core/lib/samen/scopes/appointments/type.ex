defmodule Samen.Scopes.Appointments.Type do
  @moduledoc """
  Appointments AppointmentType (WS-ERP E27;).

  A meeting type with scheduling rules.

  ## Design

  - `name` — meeting type name (e.g., "30-min Consultation")
  - `description` — meeting description
  - `duration_minutes` — meeting length in minutes
  - `location` — meeting location (physical address or "online")
  - `location_url` — video conference URL
  - `buffer_before_minutes` — buffer time before each meeting
  - `buffer_after_minutes` — buffer time after each meeting
  - `daily_cap` — max meetings per day (nil = unlimited)
  - `min_advance_minutes` — minimum booking lead time
  - `max_advance_days` — maximum booking window in days
  - `status` — :active | :inactive

  No PII (INV-1). Archivable.
  """

  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.Core.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "apt",
    archivable: true

  postgres do
    table("apt_type")
    repo(SamenCore.TestRepo)
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string, allow_nil?: false
    attribute :description, :string
    attribute :duration_minutes, :integer, allow_nil?: false, constraints: [min: 5, max: 480]
    attribute :location, :string
    attribute :location_url, :string
    attribute :buffer_before_minutes, :integer, default: 0
    attribute :buffer_after_minutes, :integer, default: 0
    attribute :daily_cap, :integer
    attribute :min_advance_minutes, :integer, default: 0
    attribute :max_advance_days, :integer, default: 30
    attribute :status, :atom, default: :active, constraints: [one_of: [:active, :inactive]]

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  actions do
    defaults [:create, :read, :update, :destroy]

    update :activate do
      require_atomic? false
      change set_attribute(:status, :active)
    end

    update :deactivate do
      require_atomic? false
      change set_attribute(:status, :inactive)
    end
  end

  policies do
    policy action_type([:read, :create, :update, :destroy]) do
      authorize_if always()
    end
  end
end
