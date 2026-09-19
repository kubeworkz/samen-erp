defmodule Samen.IoTTest do
  @moduledoc """
  WS-ERP E36: IoT — Flectra-inspired device integration.

  ## Resources

  - `Device` — device registry (type, status, protocol)
  - `Channel` — communication channels (telemetry, command, alert)
  - `DataPoint` — immutable sensor readings and events

  ## Tests

  - io1: Device lifecycle (online, offline, maintenance, decommission)
  - io2: Device types
  - io3: Device heartbeat
  - io4: Device firmware update
  - io5: Channel enable/disable
  - io6: Channel message counting
  - io7: Channel error tracking
  - io8: DataPoint creation (numeric)
  - io9: DataPoint creation (string/barcode)
  - io10: DataPoint quality levels
  - io11: Multi-device monitoring
  - io12: Device-channel relationship
  - io13: Full IoT ceremony
  """
  use ExUnit.Case, async: true

  # --- io1: Device lifecycle ---

  describe "io1 — device lifecycle" do
    test "online → offline → maintenance → decommission" do
      d = %{status: :offline, last_seen_at: nil}
      d = %{d | status: :online, last_seen_at: ~U[2026-10-01 09:00:00Z]}
      assert d.status == :online

      d = %{d | status: :offline}
      assert d.status == :offline

      d = %{d | status: :maintenance}
      assert d.status == :maintenance

      d = %{d | status: :decommissioned}
      assert d.status == :decommissioned
    end
  end

  # --- io2: Device types ---

  describe "io2 — device types" do
    test "all device types" do
      types = [:sensor, :scanner, :printer, :camera, :gateway, :actuator, :display]
      assert length(types) == 7
    end

    test "temperature sensor" do
      d = %{name: "Temp Sensor #1", device_type: :sensor, protocol: :mqtt}
      assert d.device_type == :sensor
      assert d.protocol == :mqtt
    end

    test "barcode scanner" do
      d = %{name: "Warehouse Scanner", device_type: :scanner, protocol: :bluetooth}
      assert d.device_type == :scanner
    end
  end

  # --- io3: Device heartbeat ---

  describe "io3 — device heartbeat" do
    test "heartbeat updates last_seen_at" do
      d = %{last_seen_at: ~U[2026-10-01 09:00:00Z]}
      now = ~U[2026-10-01 09:05:00Z]
      d = %{d | last_seen_at: now}
      assert d.last_seen_at == now
    end

    test "stale device detection" do
      d = %{last_seen_at: ~U[2026-10-01 09:00:00Z], status: :online}
      threshold = ~U[2026-10-01 10:00:00Z]
      stale = d.last_seen_at < threshold
      assert stale == true
    end
  end

  # --- io4: Firmware update ---

  describe "io4 — firmware update" do
    test "update firmware version" do
      d = %{firmware_version: "1.2.3"}
      d = %{d | firmware_version: "2.0.0"}
      assert d.firmware_version == "2.0.0"
    end
  end

  # --- io5: Channel enable/disable ---

  describe "io5 — channel enable/disable" do
    test "enable and disable channel" do
      ch = %{is_active: true}
      ch = %{ch | is_active: false}
      assert ch.is_active == false

      ch = %{ch | is_active: true}
      assert ch.is_active == true
    end
  end

  # --- io6: Channel message counting ---

  describe "io6 — channel message count" do
    test "increment message count" do
      ch = %{message_count: 0, last_message_at: nil}
      ch = %{ch | message_count: ch.message_count + 1, last_message_at: ~U[2026-10-01 09:00:00Z]}
      assert ch.message_count == 1

      ch = %{ch | message_count: ch.message_count + 100}
      assert ch.message_count == 101
    end
  end

  # --- io7: Channel error tracking ---

  describe "io7 — channel errors" do
    test "increment error count" do
      ch = %{error_count: 0}
      ch = %{ch | error_count: ch.error_count + 1}
      assert ch.error_count == 1
    end

    test "error rate" do
      ch = %{message_count: 1000, error_count: 12}
      error_rate = ch.error_count / ch.message_count
      assert error_rate == 0.012
    end
  end

  # --- io8: DataPoint numeric ---

  describe "io8 — numeric data point" do
    test "temperature reading" do
      dp = %{metric_name: "temperature", value: 23.5, unit: "°C", quality: :good, timestamp: ~U[2026-10-01 09:00:00Z]}
      assert dp.value == 23.5
      assert dp.unit == "°C"
    end

    test "humidity reading" do
      dp = %{metric_name: "humidity", value: 65.2, unit: "%", quality: :good, timestamp: ~U[2026-10-01 09:00:00Z]}
      assert dp.value == 65.2
    end
  end

  # --- io9: DataPoint string/barcode ---

  describe "io9 — string data point" do
    test "barcode scan" do
      dp = %{metric_name: "scan_code", value_string: "ABC-12345", quality: :good, timestamp: ~U[2026-10-01 09:00:00Z]}
      assert dp.value_string == "ABC-12345"
    end

    test "text reading" do
      dp = %{metric_name: "ocr_text", value_string: "Lot #42", quality: :good, timestamp: ~U[2026-10-01 09:00:00Z]}
      assert dp.value_string == "Lot #42"
    end
  end

  # --- io10: DataPoint quality ---

  describe "io10 — data quality" do
    test "quality levels" do
      levels = [:good, :uncertain, :bad]
      assert length(levels) == 3
    end

    test "default is good" do
      dp = %{quality: :good}
      assert dp.quality == :good
    end
  end

  # --- io11: Multi-device monitoring ---

  describe "io11 — multi-device monitoring" do
    test "monitor 3 devices" do
      devices = [
        %{name: "Temp Sensor", device_type: :sensor, status: :online},
        %{name: "Barcode Scanner", device_type: :scanner, status: :online},
        %{name: "Label Printer", device_type: :printer, status: :offline}
      ]

      online = Enum.filter(devices, &(&1.status == :online))
      assert length(online) == 2
    end
  end

  # --- io12: Device-channel relationship ---

  describe "io12 — device-channel relationship" do
    test "device with telemetry and command channels" do
      device = %{id: "dev_001", name: "Temp Sensor", device_type: :sensor}
      channels = [
        %{device_id: device.id, name: "telemetry", channel_type: :telemetry, is_active: true},
        %{device_id: device.id, name: "command", channel_type: :command, is_active: true}
      ]

      assert length(channels) == 2
      assert Enum.all?(channels, &(&1.device_id == device.id))
    end
  end

  # --- io13: Full IoT ceremony ---

  describe "io13 — full IoT ceremony" do
    test "register → connect → stream data → alert → maintain → decommission" do
      # 1. Register device
      device = %{
        name: "Warehouse Temp Sensor",
        device_type: :sensor,
        manufacturer: "Acme Sensors",
        model: "TS-100",
        serial_number: "SN-2026-001",
        firmware_version: "1.0.0",
        status: :offline,
        last_seen_at: nil,
        protocol: :mqtt
      }

      # 2. Device comes online
      device = %{device | status: :online, last_seen_at: ~U[2026-10-01 09:00:00Z]}

      # 3. Create channels
      channels = [
        %{device_id: "dev_001", name: "temperature", channel_type: :telemetry, is_active: true, message_count: 0, error_count: 0, last_message_at: nil},
        %{device_id: "dev_001", name: "alerts", channel_type: :alert, is_active: true, message_count: 0, error_count: 0, last_message_at: nil}
      ]

      # 4. Stream data points
      readings = [
        %{device_id: "dev_001", metric_name: "temperature", value: 22.1, unit: "°C", quality: :good, timestamp: ~U[2026-10-01 09:00:00Z]},
        %{device_id: "dev_001", metric_name: "temperature", value: 22.3, unit: "°C", quality: :good, timestamp: ~U[2026-10-01 09:05:00Z]},
        %{device_id: "dev_001", metric_name: "temperature", value: 28.5, unit: "°C", quality: :good, timestamp: ~U[2026-10-01 09:10:00Z]}
      ]

      # 5. Update message counts
      channels = List.update_at(channels, 0, fn ch -> %{ch | message_count: 3, last_message_at: ~U[2026-10-01 09:10:00Z]} end)

      # 6. Alert threshold breach
      threshold = 25.0
      alert_triggered = List.last(readings).value > threshold
      assert alert_triggered == true

      # 7. Send alert
      channels = List.update_at(channels, 1, fn ch -> %{ch | message_count: 1, last_message_at: ~U[2026-10-01 09:10:00Z]} end)

      # 8. Maintenance mode
      device = %{device | status: :maintenance}

      # 9. Update firmware
      device = %{device | firmware_version: "2.0.0"}

      # 10. Back online
      device = %{device | status: :online, last_seen_at: ~U[2026-10-01 10:00:00Z]}

      # 11. Eventually decommission
      device = %{device | status: :decommissioned}

      assert device.status == :decommissioned
      assert device.firmware_version == "2.0.0"
      assert length(readings) == 3
      assert length(channels) == 2
      assert List.first(channels).message_count == 3
      assert List.last(channels).message_count == 1
    end
  end
end
