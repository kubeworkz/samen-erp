defmodule Samen.Scopes.Finance.JournalTemplateSchedule do
  @moduledoc """
  Rejects an incoherent recurring cadence.

  A recurring template without `next_run_on` would never be selected by the
  due sweep; silently accepting it would look configured while doing nothing.
  A manual (`:none`) template may leave the date blank.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      frequency = Ash.Changeset.get_attribute(changeset, :frequency)
      next_run_on = Ash.Changeset.get_attribute(changeset, :next_run_on)

      if frequency not in [nil, :none] and is_nil(next_run_on) do
        Ash.Changeset.add_error(changeset,
          field: :next_run_on,
          message: "a recurring journal template requires next_run_on"
        )
      else
        changeset
      end
    end)
  end
end
