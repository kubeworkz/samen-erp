defmodule Samen.Scopes.Work.TimesheetShape do
  @moduledoc """
  Structural checks for a new `Timesheet` (WS-ACCT Unit 10.2):

    * `period_end` must not fall before `period_start` — a capture window with
      no days would silently produce an empty labour driver bucket.
    * the window may not span more than 366 days — the driver's approved-sheet
      scan is bounded by the payroll period anyway; a multi-year "timesheet" is
      a data-entry error, not a capture.

  Runs on create only (`Timesheet` has no update action), before the action.
  """
  use Ash.Resource.Change

  @max_days 366

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, &refuse_bad_period/1)
  end

  defp refuse_bad_period(changeset) do
    start_date = Ash.Changeset.get_attribute(changeset, :period_start)
    end_date = Ash.Changeset.get_attribute(changeset, :period_end)

    cond do
      is_nil(start_date) or is_nil(end_date) ->
        changeset

      Date.compare(end_date, start_date) == :lt ->
        Ash.Changeset.add_error(changeset,
          field: :period_end,
          message: "period_end cannot fall before period_start"
        )

      Date.diff(end_date, start_date) + 1 > @max_days ->
        Ash.Changeset.add_error(changeset,
          field: :period_end,
          message: "a timesheet window may not exceed #{@max_days} days"
        )

      true ->
        changeset
    end
  end
end
