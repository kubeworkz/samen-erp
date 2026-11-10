defmodule Samen.Scopes.Finance.AdjustmentApply do
  @moduledoc """
  Marks an open adjustment `:applied`. This is a state transition only: the
  document's posting already reduced the ledger when it opened, so applying
  records the allocation without posting a second entry.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      if changeset.data.status == :open do
        changeset
        |> Ash.Changeset.force_change_attribute(:status, :applied)
        |> Ash.Changeset.force_change_attribute(:applied_at, now())
      else
        Ash.Changeset.add_error(changeset,
          field: :status,
          message: "only an open adjustment can be applied"
        )
      end
    end)
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
