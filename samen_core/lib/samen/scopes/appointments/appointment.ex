defmodule Samen.Scopes.Appointments.Appointment do
  @moduledoc """
  Appointments Appointment (WS-ERP E27; Flectra-inspired).

  A booked appointment.

  ## Design

  - `type_id` — reference to AppointmentType
  - `slot_id` — reference to AppointmentSlot (optional)
  - `title` — appointment title
  - `description` — appointment description
  - `location` — meeting location (overrides type default)
  - `location_url` — video conference URL (overrides type default)
  - `start_at` — appointment start datetime
  - `end_at` — appointment end datetime
  - `status` — :pending | :confirmed | :completed | :cancelled | :no_show
  - `cancelled_reason` — reason for cancellation
  - `notes` — private notes
  - `subject_key` / `subject_id` — object-ref attachment

  Lifecycle: pending → confirmed → completed/cancelled/no_show
  No PII (INV-1). Archivable.
  """

  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.Core.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "apn",
    archivable: true

  postgres do
    table("apn_appointment")
    repo(SamenCore.TestRepo)
  end

  attributes do
    uuid_primary_key :id
    attribute :type_id, :uuid
    attribute :slot_id, :uuid
    attribute :title, :string, allow_nil?: false
    attribute :description, :string
    attribute :location, :string
    attribute :location_url, :string
    attribute :start_at, :utc_datetime_usec, allow_nil?: false
    attribute :end_at, :utc_datetime_usec, allow_nil?: false
    attribute :status, :atom, default: :pending, constraints: [one_of: [:pending, :confirmed, :completed, :cancelled, :no_show]]
    attribute :cancelled_reason, :string
    attribute :notes, :string
    attribute :subject_key, :string
    attribute :subject_id, :string

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  actions do
    defaults [:create, :read, :update, :destroy]

    update :confirm do
      require_atomic? false
      change set_attribute(:status, :confirmed)
    end

    update :complete do
      require_atomic? false
      change set_attribute(:status, :completed)
    end

    update :cancel do
      require_atomic? false
      change set_attribute(:status, :cancelled)
    end

    update :mark_no_show do
      require_atomic? false
      change set_attribute(:status, :no_show)
    end
  end

  policies do
    policy action_type([:read, :create, :update, :destroy]) do
      authorize_if always()
    end
  end
end
