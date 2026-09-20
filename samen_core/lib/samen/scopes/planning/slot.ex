defmodule Samen.Scopes.Planning.Slot do
  @moduledoc """
  Planning Slot (WS-ERP E34;).

  A time slot in the planning view representing available capacity.

  ## Design

  - `resource_id` — reference to PlanningResource
  - `date` — slot date
  - `start_time` — slot start time (HH:MM)
  - `end_time` — slot end time (HH:MM)
  - `is_available` — whether slot is available
  - `is_overbooked` — whether capacity exceeded
  - `shift_count` — number of shifts in this slot
  - `max_capacity` — maximum shifts allowed
  - `subject_key` / `subject_id` — object-ref attachment

  Archivable.
  """

  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.Core.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "pls",
    archivable: true

  postgres do
    table("pls_slot")
    repo(SamenCore.TestRepo)
  end

  attributes do
    uuid_primary_key :id
    attribute :resource_id, :uuid, allow_nil?: false
    attribute :date, :date, allow_nil?: false
    attribute :start_time, :string, allow_nil?: false
    attribute :end_time, :string, allow_nil?: false
    attribute :is_available, :boolean, default: true
    attribute :is_overbooked, :boolean, default: false
    attribute :shift_count, :integer, default: 0
    attribute :max_capacity, :integer, default: 1
    attribute :subject_key, :string
    attribute :subject_id, :string

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  actions do
    defaults [:create, :read, :update, :destroy]

    update :mark_overbooked do
      require_atomic? false

      change fn changeset, _context ->
        Ash.Changeset.force_change_attribute(changeset, :is_overbooked, true)
        Ash.Changeset.force_change_attribute(changeset, :is_available, false)
      end
    end

    update :release do
      require_atomic? false

      change fn changeset, _context ->
        Ash.Changeset.force_change_attribute(changeset, :is_available, true)
        Ash.Changeset.force_change_attribute(changeset, :is_overbooked, false)
      end
    end
  end

  policies do
    policy action_type([:read, :create, :update, :destroy]) do
      authorize_if always()
    end
  end
end
