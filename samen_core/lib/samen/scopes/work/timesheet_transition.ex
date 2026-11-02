defmodule Samen.Scopes.Work.TimesheetTransition do
  @moduledoc """
  The two one-way lifecycle transitions of a `Timesheet` (WS-ACCT Unit 10.2):

      draft --submit--> submitted --approve--> approved

  There is deliberately **no** reopen/withdraw and no destroy action. On
  `:submit` the sheet must have at least one entry — a blank submission would
  approve zero hours and look like a completed capture. On `:approve` the sheet
  must still be `submitted`.

  Options: `to` (`:submitted` | `:approved`) and, for submit, `entry` (the
  entry module counted for the non-empty check).

  The status/timestamp writes are forced, so a caller cannot smuggle a different
  status through the changeset. The `timesheet_*` DB trigger refuses any update
  to a sheet that is already `approved` — the belt under this Ash-only brace.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, opts, _context) do
    Ash.Changeset.before_action(changeset, &transition(&1, opts))
  end

  defp transition(changeset, opts) do
    to = Keyword.fetch!(opts, :to)
    from = changeset.data.status

    case {from, to} do
      {:draft, :submitted} ->
        if entry_count(changeset, Keyword.fetch!(opts, :entry)) == 0 do
          error(changeset, "a timesheet with no entries cannot be submitted")
        else
          changeset
          |> Ash.Changeset.force_change_attribute(:status, :submitted)
          |> Ash.Changeset.force_change_attribute(:submitted_at, now())
        end

      {:submitted, :approved} ->
        changeset
        |> Ash.Changeset.force_change_attribute(:status, :approved)
        |> Ash.Changeset.force_change_attribute(:approved_at, now())

      {^from, ^to} ->
        error(changeset, "timesheet is already #{from}")

      _ ->
        error(changeset, "cannot move a #{from} timesheet to #{to}")
    end
  end

  # Count the sheet's entries under the sheet's own org. `org_id` is not
  # selected on reads; the id is taken from the loaded row, exactly like the
  # other scope components, and the query is scoped by it explicitly.
  defp entry_count(changeset, entry_mod) do
    sheet = Ash.load!(changeset.data, [:org_id], authorize?: false)

    entry_mod
    |> Ash.Query.filter(timesheet_id == ^sheet.id and org_id == ^sheet.org_id)
    |> Ash.count!(authorize?: false)
  end

  defp error(changeset, message), do: Ash.Changeset.add_error(changeset, message: message)

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
