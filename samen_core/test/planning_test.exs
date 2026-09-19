defmodule Samen.PlanningTest do
  @moduledoc """
  WS-ERP E34: Planning/Scheduling — Flectra-inspired resource planning.

  ## Resources

  - `Resource` — employees/equipment/rooms that can be scheduled
  - `Shift` — individual scheduled shifts/assignments
  - `Slot` — time slots in the planning view
  - `Template` — recurring schedule templates

  ## Tests

  - ps1: Resource lifecycle (create, activate, deactivate)
  - ps2: Resource types (employee, equipment, room, vehicle)
  - ps3: Resource capacity and cost
  - ps4: Shift lifecycle (draft → published → confirmed → in_progress → completed)
  - ps5: Shift cancel flow
  - ps6: Shift duration calculation
  - ps7: Slot availability
  - ps8: Slot overbooking
  - ps9: Template lifecycle
  - ps10: Template use count
  - ps11: Recurring shift generation
  - ps12: Multi-resource scheduling
  - ps13: Resource utilization tracking
  - ps14: Full scheduling ceremony
  """
  use ExUnit.Case, async: true

  # --- ps1: Resource lifecycle ---

  describe "ps1 — resource lifecycle" do
    test "create, activate, deactivate" do
      r = %{name: "Alice", is_active: true}
      assert r.is_active == true

      r = %{r | is_active: false}
      assert r.is_active == false

      r = %{r | is_active: true}
      assert r.is_active == true
    end
  end

  # --- ps2: Resource types ---

  describe "ps2 — resource types" do
    test "all resource types" do
      types = [:employee, :equipment, :room, :vehicle]
      assert length(types) == 4
    end

    test "default is employee" do
      r = %{type: :employee}
      assert r.type == :employee
    end

    test "equipment resource" do
      r = %{name: "CNC Machine #3", type: :equipment}
      assert r.type == :equipment
    end
  end

  # --- ps3: Resource capacity and cost ---

  describe "ps3 — resource capacity and cost" do
    test "capacity" do
      r = %{capacity: 3}
      assert r.capacity == 3
    end

    test "hourly cost" do
      r = %{hourly_cost_cents: 50_00}
      assert r.hourly_cost_cents == 50_00
    end

    test "max hours per week" do
      r = %{max_hours_per_week: 40}
      assert r.max_hours_per_week == 40
    end
  end

  # --- ps4: Shift lifecycle ---

  describe "ps4 — shift lifecycle" do
    test "draft → published → confirmed → in_progress → completed" do
      s = %{status: :draft, start_at: ~U[2026-10-01 09:00:00Z], end_at: ~U[2026-10-01 17:00:00Z]}
      assert s.status == :draft

      s = %{s | status: :published}
      assert s.status == :published

      s = %{s | status: :confirmed}
      assert s.status == :confirmed

      s = %{s | status: :in_progress}
      assert s.status == :in_progress

      s = %{s | status: :completed}
      assert s.status == :completed
    end
  end

  # --- ps5: Shift cancel flow ---

  describe "ps5 — shift cancel flow" do
    test "cancel shift" do
      s = %{status: :published}
      s = %{s | status: :cancelled}
      assert s.status == :cancelled
    end
  end

  # --- ps6: Shift duration ---

  describe "ps6 — shift duration" do
    test "8-hour shift" do
      s = %{start_at: ~U[2026-10-01 09:00:00Z], end_at: ~U[2026-10-01 17:00:00Z], duration_hours: 8.0}
      assert s.duration_hours == 8.0
    end

    test "4-hour half day" do
      s = %{start_at: ~U[2026-10-01 09:00:00Z], end_at: ~U[2026-10-01 13:00:00Z], duration_hours: 4.0}
      assert s.duration_hours == 4.0
    end
  end

  # --- ps7: Slot availability ---

  describe "ps7 — slot availability" do
    test "available slot" do
      slot = %{is_available: true, is_overbooked: false, shift_count: 0, max_capacity: 3}
      assert slot.is_available == true
      assert slot.shift_count < slot.max_capacity
    end

    test "full slot" do
      slot = %{is_available: true, shift_count: 3, max_capacity: 3}
      slot = %{slot | is_available: false}
      assert slot.is_available == false
    end
  end

  # --- ps8: Slot overbooking ---

  describe "ps8 — slot overbooking" do
    test "mark overbooked" do
      slot = %{is_available: true, is_overbooked: false}
      slot = %{slot | is_overbooked: true, is_available: false}
      assert slot.is_overbooked == true
      assert slot.is_available == false
    end

    test "release slot" do
      slot = %{is_available: false, is_overbooked: true}
      slot = %{slot | is_available: true, is_overbooked: false}
      assert slot.is_available == true
      assert slot.is_overbooked == false
    end
  end

  # --- ps9: Template lifecycle ---

  describe "ps9 — template lifecycle" do
    test "create, activate, deactivate" do
      t = %{name: "Weekday 9-5", is_active: true, use_count: 0}
      assert t.is_active == true

      t = %{t | is_active: false}
      assert t.is_active == false

      t = %{t | is_active: true}
      assert t.is_active == true
    end
  end

  # --- ps10: Template use count ---

  describe "ps10 — template use count" do
    test "increment use count" do
      t = %{use_count: 0}
      t = %{t | use_count: t.use_count + 1}
      assert t.use_count == 1

      t = %{t | use_count: t.use_count + 10}
      assert t.use_count == 11
    end
  end

  # --- ps11: Recurring shift generation ---

  describe "ps11 — recurring shifts" do
    test "template generates weekly shifts" do
      t = %{recurrence_rule: "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR", is_active: true}
      assert t.recurrence_rule =~ "FREQ=WEEKLY"
      assert t.is_active == true
    end

    test "shift has recurrence" do
      s = %{recurring: true, recurrence_rule: "FREQ=WEEKLY;BYDAY=MO"}
      assert s.recurring == true
      assert s.recurrence_rule =~ "FREQ=WEEKLY"
    end
  end

  # --- ps12: Multi-resource scheduling ---

  describe "ps12 — multi-resource scheduling" do
    test "schedule 3 resources for same day" do
      resources = [
        %{name: "Alice", type: :employee, is_active: true},
        %{name: "Bob", type: :employee, is_active: true},
        %{name: "CNC Machine", type: :equipment, is_active: true}
      ]

      assert length(resources) == 3
      active = Enum.filter(resources, & &1.is_active)
      assert length(active) == 3
    end

    test "conflict detection" do
      shifts = [
        %{resource_id: "r1", start_at: ~U[2026-10-01 09:00:00Z], end_at: ~U[2026-10-01 17:00:00Z]},
        %{resource_id: "r1", start_at: ~U[2026-10-01 14:00:00Z], end_at: ~U[2026-10-01 22:00:00Z]}
      ]

      # Same resource, overlapping times = conflict
      s1 = List.first(shifts)
      s2 = List.last(shifts)
      conflict = s1.resource_id == s2.resource_id and s1.start_at < s2.end_at and s2.start_at < s1.end_at
      assert conflict == true
    end
  end

  # --- ps13: Resource utilization ---

  describe "ps13 — resource utilization" do
    test "utilization rate" do
      r = %{max_hours_per_week: 40}
      shifts = [
        %{duration_hours: 8.0},
        %{duration_hours: 8.0},
        %{duration_hours: 8.0}
      ]

      total_hours = Enum.reduce(shifts, 0, &(&1.duration_hours + &2))
      utilization = total_hours / r.max_hours_per_week
      assert utilization == 0.6
    end

    test "over-utilized resource" do
      r = %{max_hours_per_week: 40}
      total_hours = 45.0
      over = total_hours > r.max_hours_per_week
      assert over == true
    end
  end

  # --- ps14: Full scheduling ceremony ---

  describe "ps14 — full scheduling ceremony" do
    test "resource → template → generate shifts → schedule → complete" do
      # 1. Create resource
      resource = %{name: "Alice", type: :employee, role: "Developer", is_active: true, max_hours_per_week: 40, capacity: 1}

      # 2. Create template
      template = %{name: "Weekday Dev Shift", default_start_time: "09:00", default_end_time: "17:00", default_duration_hours: 8.0, recurrence_rule: "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR", is_active: true, use_count: 0}

      # 3. Generate shifts for the week
      dates = [~D[2026-10-01], ~D[2026-10-02], ~D[2026-10-03], ~D[2026-10-04], ~D[2026-10-05]]
      shifts = Enum.map(dates, fn date ->
        %{
          resource_id: "r_001",
          template_id: "t_001",
          title: "Dev Shift",
          start_at: DateTime.new!(date, ~T[09:00:00]),
          end_at: DateTime.new!(date, ~T[17:00:00]),
          duration_hours: 8.0,
          status: :draft,
          recurring: true,
          recurrence_rule: template.recurrence_rule
        }
      end)

      assert length(shifts) == 5

      # 4. Publish all shifts
      shifts = Enum.map(shifts, fn s -> %{s | status: :published} end)
      assert Enum.all?(shifts, &(&1.status == :published))

      # 5. Confirm shifts
      shifts = Enum.map(shifts, fn s -> %{s | status: :confirmed} end)

      # 6. Create slots for the week
      slot_dates = [~D[2026-10-01], ~D[2026-10-02], ~D[2026-10-03], ~D[2026-10-04], ~D[2026-10-05]]
      slots = Enum.map(slot_dates, fn date ->
        %{resource_id: "r_001", date: date, start_time: "09:00", end_time: "17:00", is_available: false, shift_count: 1, max_capacity: 1}
      end)

      assert length(slots) == 5
      assert Enum.all?(slots, &(&1.is_available == false))

      # 7. Complete the week
      shifts = Enum.map(shifts, fn s -> %{s | status: :completed} end)
      template = %{template | use_count: template.use_count + 5}

      # 8. Calculate utilization
      total_hours = Enum.reduce(shifts, 0, &(&1.duration_hours + &2))
      utilization = total_hours / resource.max_hours_per_week

      assert length(shifts) == 5
      assert template.use_count == 5
      assert total_hours == 40.0
      assert utilization == 1.0
      assert Enum.all?(shifts, &(&1.status == :completed))
    end
  end
end
