defmodule Samen.Scopes.Finance.ExpenseTransition do
  @moduledoc """
  The one-way `ExpenseReport` state machine.

  Each action declares its allowed source states and destination; an invalid
  transition adds a changeset error so no later posting can run. The timestamp
  field, when named, is stamped in the same transaction.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, opts, _context) do
    from = Keyword.fetch!(opts, :from)
    to = Keyword.fetch!(opts, :to)
    at = Keyword.get(opts, :at)
    current = changeset.data.status

    if current in from do
      changeset
      |> Ash.Changeset.force_change_attribute(:status, to)
      |> maybe_stamp(at)
    else
      Ash.Changeset.add_error(changeset,
        field: :status,
        message: "cannot transition an expense report from #{inspect(current)} to #{inspect(to)}"
      )
    end
  end

  defp maybe_stamp(changeset, nil), do: changeset

  defp maybe_stamp(changeset, field) do
    Ash.Changeset.force_change_attribute(changeset, field, now())
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
