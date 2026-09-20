defmodule Samen.Scopes.Appointments.Participant do
  @moduledoc """
  Appointments Participant (WS-ERP E27;).

  An attendee on an appointment.

  ## Design

  - `appointment_id` — reference to Appointment
  - `name` — attendee display name
  - `email` — attendee email (vaulted PII)
  - `role` — :organizer | :required | :optional
  - `status` — :pending | :accepted | :declined | :tentative
  - `is_organizer` — whether this participant is the meeting organizer

  PII: email is vaulted. Archivable.
  """

  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.Core.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "apr",
    archivable: true

  postgres do
    table("apr_participant")
    repo(SamenCore.TestRepo)
  end

  attributes do
    uuid_primary_key :id
    attribute :appointment_id, :uuid, allow_nil?: false
    attribute :name, :string, allow_nil?: false

    pii do
      vault :pii_appt_participant
      attribute :email, :string, allow_nil?: false
    end

    attribute :role, :atom, default: :required, constraints: [one_of: [:organizer, :required, :optional]]
    attribute :status, :atom, default: :pending, constraints: [one_of: [:pending, :accepted, :declined, :tentative]]
    attribute :is_organizer, :boolean, default: false

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  actions do
    defaults [:create, :read, :update, :destroy]

    update :accept do
      require_atomic? false
      change set_attribute(:status, :accepted)
    end

    update :decline do
      require_atomic? false
      change set_attribute(:status, :declined)
    end

    update :mark_tentative do
      require_atomic? false
      change set_attribute(:status, :tentative)
    end
  end

  policies do
    policy action_type([:read, :create, :update, :destroy]) do
      authorize_if always()
    end
  end
end
