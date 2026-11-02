defmodule Samen.Scopes.Work.TimesheetEntryGuard do
  @moduledoc """
  Freezes a `TimesheetEntry` once its sheet leaves `:draft`, and keeps every
  entry's `worked_on` inside the sheet's capture window (WS-ACCT Unit 10.2).

  An approved timesheet is the evidence behind a posted payroll allocation, so
  an entry write after submission would move hours the ledger already consumed.
  The guard refuses create/update/destroy unless the parent sheet is still a
  draft, and refuses a work date outside `[period_start, period_end]` (an entry
  dated outside the window would be invisible to the payroll period's driver
  read or land in the wrong one). The database trigger is the belt.

  Options: `timesheet` (the Timesheet module).

  ## Why a bare read

  The sheet lookup is `Ash.get(..., authorize?: false)`: it is an
  opaque-parent status/org check, not a leak surface (the entry's own org is
  checked against the sheet's), and a hidden-but-existing parent must not turn
  into "not found" ambiguity. Same idiom as
  `Samen.Scopes.Finance.PostGuard` and `Work.CycleGuard`.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, opts, _context) do
    Ash.Changeset.before_action(changeset, &guard(&1, opts))
  end

  defp guard(changeset, opts) do
    timesheet_mod = Keyword.fetch!(opts, :timesheet)
    timesheet_id = attribute(changeset, :timesheet_id)

    with true <- is_binary(timesheet_id),
         {:ok, sheet} <- Ash.get(timesheet_mod, timesheet_id, authorize?: false),
         sheet <- Ash.load!(sheet, [:org_id], authorize?: false),
         true <- same_uuid?(sheet.org_id, org_id(changeset)) do
      cond do
        sheet.status != :draft ->
          error(
            changeset,
            "entries can only be written while the timesheet is a draft (it is #{sheet.status})"
          )

        true ->
          check_worked_on(changeset, sheet)
      end
    else
      _ -> error(changeset, "timesheet not found in this organization")
    end
  end

  defp check_worked_on(changeset, sheet) do
    worked_on = attribute(changeset, :worked_on)

    cond do
      is_nil(worked_on) ->
        # An update that does not touch the date: the stored date was already
        # validated when it was first written.
        changeset

      Date.compare(worked_on, sheet.period_start) == :lt or
          Date.compare(worked_on, sheet.period_end) == :gt ->
        error(
          changeset,
          "worked_on #{worked_on} falls outside the timesheet window " <>
            "(#{sheet.period_start}..#{sheet.period_end})"
        )

      true ->
        changeset
    end
  end

  defp attribute(changeset, name) do
    case Ash.Changeset.get_attribute(changeset, name) do
      %Ash.NotLoaded{} -> persisted(changeset, name)
      nil -> persisted(changeset, name)
      value -> value
    end
  end

  defp persisted(changeset, name) do
    case changeset.data && Map.get(changeset.data, name) do
      %Ash.NotLoaded{} -> nil
      value -> value
    end
  end

  # `org_id` is not selected on ordinary reads; load it from the row itself
  # rather than treating `%Ash.NotLoaded{}` as a value.
  defp org_id(changeset) do
    case attribute(changeset, :org_id) do
      nil -> Ash.load!(changeset.data, [:org_id], authorize?: false).org_id
      value -> value
    end
  end

  defp same_uuid?(a, b) when is_binary(a) and is_binary(b), do: a == b
  defp same_uuid?(a, b), do: to_string(a) == to_string(b)

  defp error(changeset, message), do: Ash.Changeset.add_error(changeset, message: message)
end
