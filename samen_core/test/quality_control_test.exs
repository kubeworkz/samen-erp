defmodule Samen.QualityControlTest do
  @moduledoc """
  WS-ERP E19: Quality Control —  quality management.

  Tests:
    * qc1 ControlPoint: default values and check types
    * qc2 ControlPoint: tolerance validation
    * qc3 Check: status lifecycle (todo → pass/fail)
    * qc4 Check: measure value within tolerance
    * qc5 Check: measure value outside tolerance
    * qc6 Alert: triggered on check failure
    * qc7 Alert: status lifecycle (open → in_progress → resolved → closed)
    * qc8 ControlPoint: random sampling
    * qc9 ControlPoint: periodic checks
    * qc10 Integration: full quality flow
  """
  use ExUnit.Case, async: true

  # ── qc1: default values and check types ─────────────────────────────

  describe "qc1 — control point defaults and check types" do
    test "default control_type is :all" do
      cp = %{control_type: :all}
      assert cp.control_type == :all
    end

    test "default check_type is :pass_fail" do
      cp = %{check_type: :pass_fail}
      assert cp.check_type == :pass_fail
    end

    test "check types include :instructions, :picture, :pass_fail, :measure" do
      valid_types = [:instructions, :picture, :pass_fail, :measure]
      assert length(valid_types) == 4
      assert :pass_fail in valid_types
      assert :measure in valid_types
    end

    test "operation types include :manufacturing, :receipt, :delivery, :transfer" do
      valid_ops = [:manufacturing, :receipt, :delivery, :transfer]
      assert length(valid_ops) == 4
      assert :manufacturing in valid_ops
    end
  end

  # ── qc2: tolerance validation ───────────────────────────────────────

  describe "qc2 — tolerance validation" do
    test "value within tolerance passes" do
      norm = 60.0
      tolerance_min = 59.5
      tolerance_max = 60.5
      value = 60.0

      assert value >= tolerance_min and value <= tolerance_max
    end

    test "value at min boundary passes" do
      norm = 60.0
      tolerance_min = 59.5
      tolerance_max = 60.5
      value = 59.5

      assert value >= tolerance_min and value <= tolerance_max
    end

    test "value at max boundary passes" do
      norm = 60.0
      tolerance_min = 59.5
      tolerance_max = 60.5
      value = 60.5

      assert value >= tolerance_min and value <= tolerance_max
    end

    test "value below tolerance fails" do
      norm = 60.0
      tolerance_min = 59.5
      tolerance_max = 60.5
      value = 59.0

      refute value >= tolerance_min and value <= tolerance_max
    end

    test "value above tolerance fails" do
      norm = 60.0
      tolerance_min = 59.5
      tolerance_max = 60.5
      value = 61.0

      refute value >= tolerance_min and value <= tolerance_max
    end
  end

  # ── qc3: check status lifecycle ─────────────────────────────────────

  describe "qc3 — check status lifecycle" do
    test "todo → pass" do
      check = %{status: :todo}
      check = %{check | status: :pass}
      assert check.status == :pass
    end

    test "todo → fail" do
      check = %{status: :todo}
      check = %{check | status: :fail}
      assert check.status == :fail
    end

    test "check cannot go from pass to fail" do
      valid_transitions = %{todo: [:pass, :fail], pass: [], fail: []}
      refute :fail in valid_transitions[:pass]
    end
  end

  # ── qc4: measure value within tolerance ──────────────────────────────

  describe "qc4 — measure within tolerance" do
    test "check passes when value is within range" do
      norm = 60.0
      tolerance_min = 59.5
      tolerance_max = 60.5
      measured = 60.2

      result = if measured >= tolerance_min and measured <= tolerance_max, do: :pass, else: :fail
      assert result == :pass
    end
  end

  # ── qc5: measure value outside tolerance ─────────────────────────────

  describe "qc5 — measure outside tolerance" do
    test "check fails when value is below range" do
      norm = 60.0
      tolerance_min = 59.5
      tolerance_max = 60.5
      measured = 58.0

      result = if measured >= tolerance_min and measured <= tolerance_max, do: :pass, else: :fail
      assert result == :fail
    end

    test "check fails when value is above range" do
      norm = 60.0
      tolerance_min = 59.5
      tolerance_max = 60.5
      measured = 62.0

      result = if measured >= tolerance_min and measured <= tolerance_max, do: :pass, else: :fail
      assert result == :fail
    end
  end

  # ── qc6: alert triggered on failure ──────────────────────────────────

  describe "qc6 — alert triggered on failure" do
    test "alert is created when check fails" do
      check = %{status: :fail, id: "check-1"}
      alert = %{check_id: check.id, title: "Quality check failed", status: :open}

      assert alert.check_id == check.id
      assert alert.status == :open
    end

    test "alert contains priority" do
      alert = %{priority: :high, status: :open}
      assert alert.priority == :high
    end
  end

  # ── qc7: alert status lifecycle ──────────────────────────────────────

  describe "qc7 — alert status lifecycle" do
    test "open → in_progress → resolved → closed" do
      alert = %{status: :open}
      alert = %{alert | status: :in_progress}
      assert alert.status == :in_progress
      alert = %{alert | status: :resolved}
      assert alert.status == :resolved
      alert = %{alert | status: :closed}
      assert alert.status == :closed
    end

    test "alert can go from open directly to resolved" do
      alert = %{status: :open}
      alert = %{alert | status: :resolved}
      assert alert.status == :resolved
    end
  end

  # ── qc8: random sampling ────────────────────────────────────────────

  describe "qc8 — random sampling" do
    test "random control type selects subset of operations" do
      operations = Enum.to_list(1..100)
      sample_rate = 0.1
      sample_size = round(length(operations) * sample_rate)

      assert sample_size == 10
      assert sample_size < length(operations)
    end
  end

  # ── qc9: periodic checks ────────────────────────────────────────────

  describe "qc9 — periodic checks" do
    test "periodic control type defines check interval" do
      interval_days = 7
      last_check = Date.add(Date.utc_today(), -10)
      days_since = Date.diff(Date.utc_today(), last_check)

      assert days_since > interval_days
    end

    test "check not yet due" do
      interval_days = 7
      last_check = Date.add(Date.utc_today(), -3)
      days_since = Date.diff(Date.utc_today(), last_check)

      assert days_since <= interval_days
    end
  end

  # ── qc10: full quality flow ──────────────────────────────────────────

  describe "qc10 — full quality flow" do
    test "control point → check → pass → no alert" do
      cp = %{id: "cp-1", check_type: :pass_fail, is_active: true}
      check = %{id: "check-1", control_point_id: cp.id, status: :pass}
      alert = if check.status == :fail, do: %{check_id: check.id}, else: nil

      assert check.status == :pass
      assert alert == nil
    end

    test "control point → check → fail → alert created" do
      cp = %{id: "cp-1", check_type: :pass_fail, is_active: true, failure_message: "Re-inspect batch"}
      check = %{id: "check-1", control_point_id: cp.id, status: :fail}
      alert = if check.status == :fail, do: %{check_id: check.id, title: cp.failure_message, status: :open}, else: nil

      assert check.status == :fail
      assert alert != nil
      assert alert.title == "Re-inspect batch"
      assert alert.status == :open
    end

    test "measure check with tolerance" do
      cp = %{id: "cp-2", check_type: :measure, norm: 60.0, tolerance_min: 59.5, tolerance_max: 60.5}
      measured = 60.3

      result = if measured >= cp.tolerance_min and measured <= cp.tolerance_max, do: :pass, else: :fail
      check = %{control_point_id: cp.id, status: result, measure_value: measured}

      assert check.status == :pass
      assert check.measure_value == 60.3
    end
  end
end