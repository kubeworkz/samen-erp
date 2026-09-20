defmodule Samen.Scopes.Appointments.Slot do
  @moduledoc """
  Appointments AppointmentSlot (WS-ERP E27;).

  An available time slot for booking.

  ## Design

  - `type_id` — reference to AppointmentType
  - `date` — the slot date
  - `start_time` — slot start time (HH:MM)
  - `end_time` — slot end time (HH:MM)
  - `is_available` — whether the slot is open for booking
  - `booked_by` — reference to the booked appointment (nil if available)

  No PII (INV-1). Archivable.
  """

  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.Core.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "aps",
    archivable: true

  postgres do
    table("aps_slot")
    repo(SamenCore.TestRepo)
  end

  attributes do
    uuid_primary_key :id
    attribute :type_id, :uuid, allow_nil?: false
    attribute :date, :date, allow_nil?: false
    attribute :start_time, :string, allow_nil?: false
    attribute :end_time, :string, allow_nil?: false
    attribute :is_available, :boolean, default: true
    attribute :booked_by, :uuid

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  actions do
    defaults [:create, :read, :update, :destroy]

    update :book do
      require_atomic? false

      change fn changeset, _context ->
        Ash.Changeset.force_change_attribute(changeset, :is_available, false)
      end
    end

    update :release do
      require_atomic? false

      change fn changeset, _context ->
        Ash.Changeset.force_change_attribute(changeset, :is_available, true)
        Ash.Changeset.force_change_attribute(changeset, :booked_by, nil)
      end
    end
  end

  policies do
    policy action_type([:read, :create, :update, :destroy]) do
      authorize_if always()
    end
  end
end
