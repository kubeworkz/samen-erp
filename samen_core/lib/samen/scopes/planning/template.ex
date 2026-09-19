defmodule Samen.Scopes.Planning.Template do
  @moduledoc """
  Planning Template (WS-ERP E34; Flectra-inspired).

  Recurring schedule templates for generating shifts.

  ## Design

  - `name` — template name
  - `description` — template description
  - `role` — target role for this template
  - `default_start_time` — default shift start (HH:MM)
  - `default_end_time` — default shift end (HH:MM)
  - `default_duration_hours` — default duration
  - `recurrence_rule` — RRULE string (e.g. "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR")
  - `is_active` — whether template generates shifts
  - `use_count` — number of shifts generated
  - `subject_key` / `subject_id` — object-ref attachment

  Archivable.
  """

  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.Core.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "pln",
    archivable: true

  postgres do
    table("pln_template")
    repo(SamenCore.TestRepo)
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string, allow_nil?: false
    attribute :description, :string
    attribute :role, :string
    attribute :default_start_time, :string
    attribute :default_end_time, :string
    attribute :default_duration_hours, :float
    attribute :recurrence_rule, :string
    attribute :is_active, :boolean, default: true
    attribute :use_count, :integer, default: 0
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

    update :increment_use_count do
      require_atomic? false

      change fn changeset, _context ->
        current = Ash.Changeset.get_attribute(changeset, :use_count) || 0
        Ash.Changeset.force_change_attribute(changeset, :use_count, current + 1)
      end
    end
  end

  policies do
    policy action_type([:read, :create, :update, :destroy]) do
      authorize_if always()
    end
  end
end
