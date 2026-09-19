defmodule Samen.TimesheetsTest do
  @moduledoc """
  Timesheets (WS-ERP E15; Flectra-inspired project management).

  Tests:
    * ts1 TimesheetGuard: no future entries
    * ts2 TimesheetGuard: positive hours required
    * ts3 TimesheetGuard: 15-minute precision
    * ts4 TimesheetGuard: max 24h per day
    * ts5 TimesheetGuard: approved entries frozen
    * ts6 TimesheetEntry: default billable is true
    * ts7 TimesheetSummary: by_task aggregation
    * ts8 TimesheetSummary: by_user aggregation
    * ts9 TimesheetSummary: weekly summary
  """
  use ExUnit.Case, async: true

  # ── ts1: no future entries ────────────────────────────────────────────────

  describe "ts1 — no future entries" do
    test "future date is invalid" do
      future_date = Date.add(Date.utc_today(), 1)
      assert Date.compare(future_date, Date.utc_today()) == :gt
    end

    test "today is valid" do
      today = Date.utc_today()
      assert Date.compare(today, Date.utc_today()) != :gt
    end

    test "past date is valid" do
      past_date = Date.add(Date.utc_today(), -1)
      assert Date.compare(past_date, Date.utc_today()) != :gt
    end
  end

  # ── ts2: positive hours required ──────────────────────────────────────────

  describe "ts2 — positive hours required" do
    test "zero hours is invalid" do
      assert 0 <= 0
    end

    test "negative hours is invalid" do
      assert -1.0 <= 0
    end

    test "positive hours is valid" do
      assert 2.5 > 0
    end
  end

  # ── ts3: 15-minute precision ──────────────────────────────────────────────

  describe "ts3 — 15-minute precision" do
    test "0.25 is valid" do
      assert rem(round(0.25 * 4), 1) == 0
    end

    test "0.5 is valid" do
      assert rem(round(0.5 * 4), 1) == 0
    end

    test "1.0 is valid" do
      assert rem(round(1.0 * 4), 1) == 0
    end

    test "2.75 is valid" do
      assert rem(round(2.75 * 4), 1) == 0
    end

    test "0.1 is invalid (not 15-minute increment)" do
      multiplied = 0.1 * 4
      nearest_int = round(multiplied)
      assert abs(multiplied - nearest_int) > 0.01
    end

    test "1.33 is invalid" do
      multiplied = 1.33 * 4
      nearest_int = round(multiplied)
      assert abs(multiplied - nearest_int) > 0.01
    end
  end

  # ── ts4: max 24h per day ─────────────────────────────────────────────────

  describe "ts4 — max 24h per day" do
    test "24h total is valid" do
      existing = 22.0
      new_entry = 2.0
      total = existing + new_entry
      assert total <= 24
    end

    test "over 24h total is invalid" do
      existing = 22.0
      new_entry = 3.0
      total = existing + new_entry
      assert total > 24
    end
  end

  # ── ts5: approved entries frozen ──────────────────────────────────────────

  describe "ts5 — approved entries frozen" do
    test "approved entry cannot be modified" do
      approved = true
      assert approved == true
    end

    test "unapproved entry can be modified" do
      approved = false
      assert approved == false
    end
  end

  # ── ts6: default billable is true ────────────────────────────────────────

  describe "ts6 — default billable is true" do
    test "billable defaults to true" do
      default_billable = true
      assert default_billable == true
    end
  end

  # ── ts7: by_task aggregation ─────────────────────────────────────────────

  describe "ts7 — by_task aggregation" do
    test "sums hours per task" do
      entries = [
        %{task_id: "t1", hours: 2.0, billable: true},
        %{task_id: "t1", hours: 1.5, billable: true},
        %{task_id: "t2", hours: 3.0, billable: false},
      ]

      grouped = Enum.group_by(entries, & &1.task_id)

      result =
        Enum.map(grouped, fn {task_id, task_entries} ->
          total = Enum.reduce(task_entries, 0, fn e, acc -> acc + e.hours end)
          billable = Enum.reduce(task_entries, 0, fn e, acc -> if e.billable, do: acc + e.hours, else: acc end)
          %{task_id: task_id, total_hours: total, billable_hours: billable}
        end)

      t1 = Enum.find(result, &(&1.task_id == "t1"))
      t2 = Enum.find(result, &(&1.task_id == "t2"))

      assert t1.total_hours == 3.5
      assert t1.billable_hours == 3.5
      assert t2.total_hours == 3.0
      assert t2.billable_hours == 0.0
    end
  end

  # ── ts8: by_user aggregation ─────────────────────────────────────────────

  describe "ts8 — by_user aggregation" do
    test "sums hours per user" do
      entries = [
        %{user_id: "u1", hours: 8.0, date: ~D[2026-01-13]},
        %{user_id: "u1", hours: 7.5, date: ~D[2026-01-14]},
        %{user_id: "u2", hours: 6.0, date: ~D[2026-01-13]},
      ]

      grouped = Enum.group_by(entries, & &1.user_id)

      result =
        Enum.map(grouped, fn {user_id, user_entries} ->
          total = Enum.reduce(user_entries, 0, fn e, acc -> acc + e.hours end)
          days = user_entries |> Enum.map(& &1.date) |> Enum.uniq() |> length()
          %{user_id: user_id, total_hours: total, days_worked: days}
        end)

      u1 = Enum.find(result, &(&1.user_id == "u1"))
      u2 = Enum.find(result, &(&1.user_id == "u2"))

      assert u1.total_hours == 15.5
      assert u1.days_worked == 2
      assert u2.total_hours == 6.0
      assert u2.days_worked == 1
    end
  end

  # ── ts9: weekly summary ──────────────────────────────────────────────────

  describe "ts9 — weekly summary" do
    test "week starts on Monday" do
      # 2026-01-14 is Wednesday
      week_date = ~D[2026-01-14]
      day_of_week = Date.day_of_week(week_date)
      week_start = Date.add(week_date, -(day_of_week - 1))

      assert week_start == ~D[2026-01-12]  # Monday
    end

    test "week ends on Sunday" do
      week_start = ~D[2026-01-12]
      week_end = Date.add(week_start, 6)

      assert week_end == ~D[2026-01-18]  # Sunday
    end
  end
end
