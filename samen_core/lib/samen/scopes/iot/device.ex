defmodule Samen.Scopes.IoT.Device do
  @moduledoc """
  IoT Device (WS-ERP E36;).

  Registry of connected IoT devices.

  ## Design

  - `name` — device name
  - `device_type` — :sensor | :scanner | :printer | :camera | :gateway | :actuator | :display
  - `manufacturer` — device manufacturer
  - `model` — device model
  - `serial_number` — unique serial
  - `firmware_version` — current firmware
  - `location_id` — physical location reference
  - `status` — :online | :offline | :maintenance | :decommissioned
  - `last_seen_at` — last heartbeat timestamp
  - `ip_address` — current IP
  - `mac_address` — MAC address
  - `protocol` — :mqtt | :http | :bluetooth | :zigbee | :modbus | :opc_ua
  - `tags` — categorization tags
  - `subject_key` / `subject_id` — object-ref attachment

  Archivable.
  """

  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.Core.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "iot",
    archivable: true

  postgres do
    table("iot_device")
    repo(SamenCore.TestRepo)
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string, allow_nil?: false
    attribute :device_type, :atom, allow_nil?: false,
      constraints: [one_of: [:sensor, :scanner, :printer, :camera, :gateway, :actuator, :display]]
    attribute :manufacturer, :string
    attribute :model, :string
    attribute :serial_number, :string
    attribute :firmware_version, :string
    attribute :location_id, :uuid
    attribute :status, :atom, default: :offline,
      constraints: [one_of: [:online, :offline, :maintenance, :decommissioned]]
    attribute :last_seen_at, :utc_datetime_usec
    attribute :ip_address, :string
    attribute :mac_address, :string
    attribute :protocol, :atom, constraints: [one_of: [:mqtt, :http, :bluetooth, :zigbee, :modbus, :opc_ua]]
    attribute :tags, {:array, :string}, default: []
    attribute :subject_key, :string
    attribute :subject_id, :string

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  actions do
    defaults [:create, :read, :update, :destroy]

    update :online do
      require_atomic? false

      change fn changeset, _context ->
        Ash.Changeset.force_change_attribute(changeset, :status, :online)
        Ash.Changeset.force_change_attribute(changeset, :last_seen_at, DateTime.utc_now())
      end
    end

    update :offline do
      require_atomic? false
      change set_attribute(:status, :offline)
    end

    update :maintenance do
      require_atomic? false
      change set_attribute(:status, :maintenance)
    end

    update :decommission do
      require_atomic? false
      change set_attribute(:status, :decommissioned)
    end

    update :heartbeat do
      require_atomic? false
      change set_attribute(:last_seen_at, DateTime.utc_now())
    end

    update :update_firmware do
      require_atomic? false

      change fn changeset, _context ->
        version = Ash.Changeset.get_attribute(changeset, :new_firmware_version)
        Ash.Changeset.force_change_attribute(changeset, :firmware_version, version)
      end
    end
  end

  policies do
    policy action_type([:read, :create, :update, :destroy]) do
      authorize_if always()
    end
  end
end
