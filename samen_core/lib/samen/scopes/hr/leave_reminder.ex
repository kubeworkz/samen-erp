defmodule Samen.Scopes.Hr.LeaveReminder do
  @moduledoc """
  Schedules the leave reminder AFTER a governed `:approve` decision lands
  (WS-ERP E7; design §5 — approvals + Automation reminders).

  Runs in `after_action` (inside the decision transaction, the
  `ConvertLead` cross-row discipline) but the side-effect is FAIL-SOFT: the
  reminder seam (`Samen.Scopes.Hr.Reminders`) never raises and never blocks —
  an unwired automation module degrades to `{:ok, :reminder_skipped}`. The
  decision transaction never rolls back because a notification could not be
  scheduled: reminders are observability, not the decision.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, opts, _context) do
    employee_mod = Keyword.fetch!(opts, :employee)

    Ash.Changeset.after_action(changeset, fn changeset, leave_request ->
      org_id = resolve_org_id(changeset, leave_request, employee_mod)

      case org_id do
        nil ->
          # Fail-soft even in the pathological case (no org to scope the
          # reminder by): the decision stands, the reminder degrades.
          {:ok, leave_request}

        org_id ->
          start_dt = DateTime.new!(leave_request.start_date, ~T[09:00:00], "Etc/UTC")

          case Samen.Scopes.Hr.Reminders.schedule_leave_reminder(
                 org_id,
                 leave_request.employee_id,
                 leave_request.id,
                 start_dt
               ) do
            {:ok, _reminder_or_skipped} -> {:ok, leave_request}
          end
      end
    end)
  end

  # The decision's org: prefer the changeset's resolved org_id, then the
  # record's own; fall back to one re-fetch (the NotLoaded discipline from
  # E4's resolve_org lessons — a re-fetch beats a crash).
  defp resolve_org_id(changeset, leave_request, employee_mod) do
    cond do
      org = Ash.Changeset.get_attribute(changeset, :org_id) ->
        org

      is_binary(leave_request.org_id) and byte_size(leave_request.org_id) == 36 ->
        leave_request.org_id

      match?(%{org_id: org_id} when is_binary(org_id), changeset.data) and
          is_binary(changeset.data.org_id) ->
        changeset.data.org_id

      true ->
        require Ash.Query

        employee_mod
        |> Ash.Query.filter(id == ^leave_request.employee_id)
        |> Ash.Query.select(:org_id)
        |> Ash.read_one(authorize?: false)
        |> case do
          {:ok, %{org_id: org_id}} -> org_id
          _ -> nil
        end
    end
  end
end
