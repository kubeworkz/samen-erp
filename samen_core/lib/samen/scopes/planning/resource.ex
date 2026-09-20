defmodule Samen.Scopes.Planning.Resource do
  @moduledoc """
  Planning Resource (WS-ERP E34;).

  An employee or piece of equipment that can be scheduled.

  ## Design

  - `name` — resource name (e.g. "John Smith", "CNC Machine #3")
  - `type` — :employee | :equipment | :room | :vehicle
  - `role` — role or skill set (e.g. "Developer", "Forklift Operator")
  - `department_id` — reference to department
  - `capacity` — how many parallel shifts (default 1)
  - `hourly_cost_cents` — cost per hour for scheduling optimization
  - `calendar_id` — reference to working calendar
  - `is_active` — whether resource is available for scheduling
  - `max_hours_per_week` — weekly hour cap
  - `tags` — skill tags for matching
  - `subject_key` / `subject_id` — object-ref attachment

  Archivable.
  """

  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.Core.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "plr",
    archivable: true

  postgres do
    table("plr_resource")
    repo(SamenCore.TestRepo)
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string, allow_nil?: false
    attribute :type, :atom, default: :employee,
      constraints: [one_of: [:employee, :equipment, :room, :vehicle]]
    attribute :role, :string
    attribute :department_id, :uuid
    attribute :capacity, :integer, default: 1
    attribute :hourly_cost_cents, :integer
    attribute :calendar_id, :uuid
    attribute :is_active, :boolean, default: true
    attribute :max_hours_per_week, :integer, default: 40
    attribute :tags, {:array, :string}, default: []
    attribute :subject_key, :string
    attribute :subject_id, :string

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  actions do
    defaults [:create, :read, :update, :destroy]

    update :deactivate do
      require_atomic? false
      change set_attribute(:is_active, false)
    end

    update :activate do
      require_atomic? false
      change set_attribute(:is_active, true)
    end
  end

  policies do
    policy action_type([:read, :create, :update, :destroy]) do
      authorize_if always()
    end
  end
end
