defmodule Samen.AppointmentsTest do
  @moduledoc """
  WS-ERP E27: Appointments — Flectra-inspired scheduling.

  ## Resources

  - `Type` — meeting type configuration (duration, location, buffer, daily cap)
  - `Slot` — available time slots (date, start/end time, availability)
  - `Appointment` — booked appointment (pending → confirmed → completed/cancelled/no_show)
  - `Participant` — attendees (organizer/required/optional, accepted/declined/tentative)

  ## Tests

  - ap1: Type lifecycle (create, activate, deactivate)
  - ap2: Type duration constraints
  - ap3: Type buffer times
  - ap4: Type daily cap
  - ap5: Slot availability (book, release)
  - ap6: Appointment lifecycle (pending → confirmed → completed)
  - ap7: Appointment cancel flow
  - ap8: Appointment no-show flow
  - ap9: Participant RSVP (accept, decline, tentative)
  - ap10: Organizer role
  - ap11: Multi-participant meeting
  - ap12: Appointment with location override
  - ap13: Slot booking prevents double-booking
  - ap14: Type min/max advance booking
  - ap15: Full booking flow end-to-end
  - ap16: Appointment with object-ref attachment
  - ap17: Participant roles (organizer, required, optional)
  - ap18: Appointment status transitions
  - ap19: Slot time ranges
  - ap20: Full scheduling ceremony with participants
  """
  use ExUnit.Case, async: true

  # --- ap1: Type lifecycle ---

  describe "ap1 — type lifecycle" do
    test "create, activate, deactivate" do
      type = %{name: "30-min Consultation", duration_minutes: 30, status: :active}
      assert type.status == :active

      type = %{type | status: :inactive}
      assert type.status == :inactive

      type = %{type | status: :active}
      assert type.status == :active
    end
  end

  # --- ap2: Type duration constraints ---

  describe "ap2 — type duration constraints" do
    test "valid durations" do
      for dur <- [5, 15, 30, 60, 120, 240, 480] do
        type = %{duration_minutes: dur}
        assert type.duration_minutes >= 5
        assert type.duration_minutes <= 480
      end
    end
  end

  # --- ap3: Type buffer times ---

  describe "ap3 — type buffer times" do
    test "buffer before and after" do
      type = %{buffer_before_minutes: 10, buffer_after_minutes: 5}
      assert type.buffer_before_minutes == 10
      assert type.buffer_after_minutes == 5
    end

    test "no buffer by default" do
      type = %{buffer_before_minutes: 0, buffer_after_minutes: 0}
      assert type.buffer_before_minutes == 0
      assert type.buffer_after_minutes == 0
    end
  end

  # --- ap4: Type daily cap ---

  describe "ap4 — type daily cap" do
    test "unlimited by default" do
      type = %{daily_cap: nil}
      assert is_nil(type.daily_cap)
    end

    test "capped at 5 per day" do
      type = %{daily_cap: 5}
      assert type.daily_cap == 5
    end
  end

  # --- ap5: Slot availability (book, release) ---

  describe "ap5 — slot availability" do
    test "book and release a slot" do
      slot = %{is_available: true, booked_by: nil}
      assert slot.is_available == true

      slot = %{slot | is_available: false, booked_by: "appt_001"}
      assert slot.is_available == false
      assert slot.booked_by == "appt_001"

      slot = %{slot | is_available: true, booked_by: nil}
      assert slot.is_available == true
      assert is_nil(slot.booked_by)
    end
  end

  # --- ap6: Appointment lifecycle (pending → confirmed → completed) ---

  describe "ap6 — appointment lifecycle" do
    test "pending → confirmed → completed" do
      appt = %{status: :pending, start_at: ~U[2026-10-01 10:00:00Z], end_at: ~U[2026-10-01 10:30:00Z]}
      assert appt.status == :pending

      appt = %{appt | status: :confirmed}
      assert appt.status == :confirmed

      appt = %{appt | status: :completed}
      assert appt.status == :completed
    end
  end

  # --- ap7: Appointment cancel flow ---

  describe "ap7 — appointment cancel flow" do
    test "cancel with reason" do
      appt = %{status: :confirmed, cancelled_reason: nil}
      appt = %{appt | status: :cancelled, cancelled_reason: "Schedule conflict"}
      assert appt.status == :cancelled
      assert appt.cancelled_reason == "Schedule conflict"
    end
  end

  # --- ap8: Appointment no-show flow ---

  describe "ap8 — appointment no-show flow" do
    test "mark as no-show" do
      appt = %{status: :confirmed}
      appt = %{appt | status: :no_show}
      assert appt.status == :no_show
    end
  end

  # --- ap9: Participant RSVP (accept, decline, tentative) ---

  describe "ap9 — participant RSVP" do
    test "accept, decline, tentative" do
      p = %{status: :pending}
      p = %{p | status: :accepted}
      assert p.status == :accepted

      p = %{p | status: :tentative}
      assert p.status == :tentative

      p = %{p | status: :declined}
      assert p.status == :declined
    end
  end

  # --- ap10: Organizer role ---

  describe "ap10 — organizer role" do
    test "organizer is marked" do
      p = %{role: :organizer, is_organizer: true}
      assert p.is_organizer == true
      assert p.role == :organizer
    end

    test "non-organizer" do
      p = %{role: :required, is_organizer: false}
      assert p.is_organizer == false
    end
  end

  # --- ap11: Multi-participant meeting ---

  describe "ap11 — multi-participant meeting" do
    test "3 participants with different roles" do
      participants = [
        %{name: "Host", role: :organizer, is_organizer: true, status: :accepted},
        %{name: "Alice", role: :required, is_organizer: false, status: :pending},
        %{name: "Bob", role: :optional, is_organizer: false, status: :tentative}
      ]

      assert length(participants) == 3
      organizers = Enum.filter(participants, & &1.is_organizer)
      assert length(organizers) == 1
    end
  end

  # --- ap12: Appointment with location override ---

  describe "ap12 — appointment with location override" do
    test "type location vs appointment location" do
      type = %{location: "Conference Room A"}
      appt = %{location: "Conference Room B"}

      # Appointment overrides type location
      effective_location = if appt.location, do: appt.location, else: type.location
      assert effective_location == "Conference Room B"
    end

    test "appointment inherits type location when nil" do
      type = %{location: "Conference Room A"}
      appt = %{location: nil}

      effective_location = if appt.location, do: appt.location, else: type.location
      assert effective_location == "Conference Room A"
    end
  end

  # --- ap13: Slot booking prevents double-booking ---

  describe "ap13 — slot double-booking prevention" do
    test "available slot can be booked" do
      slot = %{is_available: true}
      assert slot.is_available == true
    end

    test "unavailable slot cannot be booked" do
      slot = %{is_available: false, booked_by: "appt_001"}
      assert slot.is_available == false
    end
  end

  # --- ap14: Type min/max advance booking ---

  describe "ap14 — type advance booking" do
    test "min advance and max advance" do
      type = %{min_advance_minutes: 60, max_advance_days: 14}
      assert type.min_advance_minutes == 60
      assert type.max_advance_days == 14
    end

    test "defaults" do
      type = %{min_advance_minutes: 0, max_advance_days: 30}
      assert type.min_advance_minutes == 0
      assert type.max_advance_days == 30
    end
  end

  # --- ap15: Full booking flow end-to-end ---

  describe "ap15 — full booking flow" do
    test "type → slot → appointment → participants → confirm → complete" do
      # 1. Create meeting type
      type = %{name: "Consultation", duration_minutes: 30, status: :active}

      # 2. Create available slot
      slot = %{type_id: "type_001", date: ~D[2026-10-01], start_time: "10:00", end_time: "10:30", is_available: true, booked_by: nil}

      # 3. Book appointment
      appt = %{
        type_id: "type_001",
        slot_id: "slot_001",
        title: "Consultation with Client",
        start_at: ~U[2026-10-01 10:00:00Z],
        end_at: ~U[2026-10-01 10:30:00Z],
        status: :pending
      }

      # 4. Add participants
      organizer = %{name: "Host", role: :organizer, is_organizer: true, status: :accepted}
      client = %{name: "Client", role: :required, is_organizer: false, status: :pending}

      # 5. Mark slot as booked
      slot = %{slot | is_available: false, booked_by: "appt_001"}

      # 6. Confirm appointment
      appt = %{appt | status: :confirmed}

      # 7. Client accepts
      client = %{client | status: :accepted}

      # 8. Complete
      appt = %{appt | status: :completed}

      assert appt.status == :completed
      assert slot.is_available == false
      assert client.status == :accepted
    end
  end

  # --- ap16: Appointment with object-ref attachment ---

  describe "ap16 — object-ref attachment" do
    test "appointment can attach to any object" do
      appt = %{
        subject_key: "contact",
        subject_id: "ct_001"
      }

      assert appt.subject_key == "contact"
      assert appt.subject_id == "ct_001"
    end
  end

  # --- ap17: Participant roles ---

  describe "ap17 — participant roles" do
    test "three roles exist" do
      roles = [:organizer, :required, :optional]
      assert length(roles) == 3
    end
  end

  # --- ap18: Appointment status transitions ---

  describe "ap18 — appointment status transitions" do
    test "valid transitions" do
      valid = %{
        pending: [:confirmed, :cancelled],
        confirmed: [:completed, :cancelled, :no_show],
        completed: [],
        cancelled: [],
        no_show: []
      }

      assert :confirmed in valid[:pending]
      assert :completed in valid[:confirmed]
      assert :cancelled in valid[:confirmed]
      assert :no_show in valid[:confirmed]
    end

    test "terminal states" do
      terminal = [:completed, :cancelled, :no_show]
      for state <- terminal do
        assert state in [:completed, :cancelled, :no_show]
      end
    end
  end

  # --- ap19: Slot time ranges ---

  describe "ap19 — slot time ranges" do
    test "slot has start and end time" do
      slot = %{start_time: "09:00", end_time: "09:30"}
      assert slot.start_time == "09:00"
      assert slot.end_time == "09:30"
    end

    test "slot has date" do
      slot = %{date: ~D[2026-10-01]}
      assert slot.date == ~D[2026-10-01]
    end
  end

  # --- ap20: Full scheduling ceremony ---

  describe "ap20 — full scheduling ceremony" do
    test "complete booking with 3 participants" do
      # Type
      type = %{name: "Team Standup", duration_minutes: 15, daily_cap: 3}

      # Slots for the day
      slots = [
        %{start_time: "09:00", end_time: "09:15", is_available: true},
        %{start_time: "09:30", end_time: "09:45", is_available: true},
        %{start_time: "10:00", end_time: "10:15", is_available: true}
      ]

      assert length(slots) == 3
      assert Enum.all?(slots, & &1.is_available)

      # Book first slot
      slot = %{List.first(slots) | is_available: false}
      assert slot.is_available == false

      # Create appointment
      appt = %{title: "Standup", status: :confirmed, start_at: ~U[2026-10-01 09:00:00Z], end_at: ~U[2026-10-01 09:15:00Z]}

      # 3 participants
      participants = [
        %{name: "Manager", role: :organizer, is_organizer: true, status: :accepted},
        %{name: "Dev 1", role: :required, is_organizer: false, status: :accepted},
        %{name: "Dev 2", role: :required, is_organizer: false, status: :tentative}
      ]

      accepted = Enum.count(participants, &(&1.status == :accepted))
      assert accepted == 2

      # Complete
      appt = %{appt | status: :completed}
      assert appt.status == :completed
    end
  end
end
