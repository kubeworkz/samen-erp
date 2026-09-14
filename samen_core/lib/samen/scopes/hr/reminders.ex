defmodule Samen.Scopes.Hr.Reminders do
  @moduledoc """
  The HR reminder seam (WS-ERP E7; design §5 — LeaveRequest approvals +
  Automation reminders): a thin, fail-soft wrapper over the shipped
  `Samen.Automation.Remind` scheduler.

  A governed leave decision schedules a reminder for the employee (e.g. the
  approved leave's start). Reminders are OBSERVABILITY, not the decision: a
  failure or an unwired automation module degrades the side-effect honestly
  (`{:ok, :reminder_skipped}`) while the leave transition itself stands — the
  same fail-soft posture `Samen.Automation.Breaker` takes to its own audit
  writes. The decision transaction never rolls back because a notification
  could not be scheduled.

  Unwired ⇒ `{:ok, :reminder_skipped}` (fail-soft, `Remind` refuses honestly
  with `{:error, :no_automation_module}` and we degrade); a wired scheduler
  that ACCEPTS the row ⇒ `{:ok, reminder}`. The test suite pins both postures.
  """

  @doc """
  Schedule a leave reminder for `employee_id` about `leave_request_id` at
  `remind_at`. Fail-soft: never raises, never blocks a decision — an unwired
  or refusing scheduler degrades to `{:ok, :reminder_skipped}`.
  """
  @spec schedule_leave_reminder(
          org_id :: binary(),
          employee_id :: binary(),
          leave_request_id :: binary(),
          remind_at :: DateTime.t(),
          opts :: keyword()
        ) :: {:ok, struct()} | {:ok, :reminder_skipped}
  def schedule_leave_reminder(org_id, employee_id, leave_request_id, remind_at, opts \\ []) do
    case Samen.Automation.Remind.schedule(
           %{
             org_id: org_id,
             recipient_id: employee_id,
             subject_ref: "hr_leave_request:#{leave_request_id}",
             remind_at: remind_at,
             note: "Your leave starts soon",
             source: :automation
           },
           opts
         ) do
      {:ok, reminder} -> {:ok, reminder}
      {:error, :no_automation_module} -> {:ok, :reminder_skipped}
      {:error, _reason} -> {:ok, :reminder_skipped}
    end
  end
end
