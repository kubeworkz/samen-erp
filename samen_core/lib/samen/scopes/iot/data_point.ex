defmodule Samen.Scopes.IoT.DataPoint do
  @moduledoc """
  IoT Data Point (WS-ERP E36;).

  Individual sensor readings or device events.

  ## Design

  - `device_id` — reference to IoTDevice
  - `channel_id` — reference to IoTChannel
  - `metric_name` — what is being measured (e.g. "temperature", "humidity", "scan_code")
  - `value` — reading value (float)
  - `value_string` — string value for non-numeric data (barcode, text)
  - `unit` — unit of measurement (e.g. "°C", "%", "count")
  - `quality` — :good | :uncertain | :bad
  - `timestamp` — when reading was taken
  - `source` — data source identifier
  - `subject_key` / `subject_id` — object-ref attachment

  Create-only (immutable time series). No PII (INV-1).
  """

  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.Core.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "iop"

  postgres do
    table("iop_data_point")
    repo(SamenCore.TestRepo)
  end

  attributes do
    uuid_primary_key :id
    attribute :device_id, :uuid, allow_nil?: false
    attribute :channel_id, :uuid
    attribute :metric_name, :string, allow_nil?: false
    attribute :value, :float
    attribute :value_string, :string
    attribute :unit, :string
    attribute :quality, :atom, default: :good,
      constraints: [one_of: [:good, :uncertain, :bad]]
    attribute :timestamp, :utc_datetime_usec, allow_nil?: false
    attribute :source, :string
    attribute :subject_key, :string
    attribute :subject_id, :string

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  actions do
    defaults [:create, :read]
  end

  policies do
    policy action_type([:read, :create, :update, :destroy]) do
      authorize_if always()
    end
  end
end
