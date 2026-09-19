defmodule Samen.Scopes.IoT.Channel do
  @moduledoc """
  IoT Channel (WS-ERP E36; Flectra-inspired).

  Communication channel configuration for IoT devices.

  ## Design

  - `device_id` — reference to IoTDevice
  - `name` — channel name
  - `channel_type` — :telemetry | :command | :alert | :file | :log
  - `protocol` — :mqtt | :http | :websocket | :serial
  - `endpoint` — connection endpoint URL or topic
  - `is_active` — whether channel is enabled
  - `message_count` — total messages processed
  - `error_count` — total errors
  - `last_message_at` — last message timestamp
  - `config_json` — JSON configuration (retained, QoS, etc.)
  - `subject_key` / `subject_id` — object-ref attachment

  Archivable.
  """

  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.Core.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "ioc",
    archivable: true

  postgres do
    table("ioc_channel")
    repo(SamenCore.TestRepo)
  end

  attributes do
    uuid_primary_key :id
    attribute :device_id, :uuid, allow_nil?: false
    attribute :name, :string, allow_nil?: false
    attribute :channel_type, :atom, allow_nil?: false,
      constraints: [one_of: [:telemetry, :command, :alert, :file, :log]]
    attribute :protocol, :atom, constraints: [one_of: [:mqtt, :http, :websocket, :serial]]
    attribute :endpoint, :string
    attribute :is_active, :boolean, default: true
    attribute :message_count, :integer, default: 0
    attribute :error_count, :integer, default: 0
    attribute :last_message_at, :utc_datetime_usec
    attribute :config_json, :string
    attribute :subject_key, :string
    attribute :subject_id, :string

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  actions do
    defaults [:create, :read, :update, :destroy]

    update :enable do
      require_atomic? false
      change set_attribute(:is_active, true)
    end

    update :disable do
      require_atomic? false
      change set_attribute(:is_active, false)
    end

    update :increment_message_count do
      require_atomic? false

      change fn changeset, _context ->
        current = Ash.Changeset.get_attribute(changeset, :message_count) || 0
        Ash.Changeset.force_change_attribute(changeset, :message_count, current + 1)
        Ash.Changeset.force_change_attribute(changeset, :last_message_at, DateTime.utc_now())
      end
    end

    update :increment_error_count do
      require_atomic? false

      change fn changeset, _context ->
        current = Ash.Changeset.get_attribute(changeset, :error_count) || 0
        Ash.Changeset.force_change_attribute(changeset, :error_count, current + 1)
      end
    end
  end

  policies do
    policy action_type([:read, :create, :update, :destroy]) do
      authorize_if always()
    end
  end
end
