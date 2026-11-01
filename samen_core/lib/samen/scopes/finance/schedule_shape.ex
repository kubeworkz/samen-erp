defmodule Samen.Scopes.Finance.ScheduleShape do
  @moduledoc """
  The shape guards for a `RevenueSchedule` (WS-ACCT Phase 6; ADR-054 D5).

  Two rules that no single attribute constraint can express:

    * `:cost_incurred` needs a `cost_object_id` — the dimension whose incurred
      cost drives the recognition. Without it the run cannot compute an amount,
      and a schedule that recognizes nothing forever is worse than a refusal.
    * `total_cents >= months` — a straight-line term releases at least one cent
      per period; below that the schedule would have to release zero for most
      of its life and dump the remainder in the last month, which is not a
      schedule, it is a rounding accident.

  Both run `before_action`, so the refusal lands inside the create's
  transaction with a field-level message rather than a database CHECK.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, &check/1)
  end

  defp check(changeset) do
    method = Ash.Changeset.get_attribute(changeset, :method) || :straight_line
    cost_object_id = Ash.Changeset.get_attribute(changeset, :cost_object_id)
    total = Ash.Changeset.get_attribute(changeset, :total_cents)
    months = Ash.Changeset.get_attribute(changeset, :months)

    changeset
    |> require_cost_object(method, cost_object_id)
    |> require_slice(total, months)
  end

  defp require_cost_object(changeset, :cost_incurred, nil) do
    Ash.Changeset.add_error(changeset,
      field: :cost_object_id,
      message:
        "a :cost_incurred schedule must name the cost object whose incurred cost it " <>
          "recognizes — otherwise the run has nothing to read and the schedule would " <>
          "recognize zero forever"
    )
  end

  defp require_cost_object(changeset, _method, _cost_object_id), do: changeset

  defp require_slice(changeset, total, months)
       when is_integer(total) and is_integer(months) and months > 0 and total < months do
    Ash.Changeset.add_error(changeset,
      field: :total_cents,
      message:
        "total_cents (#{total}) must be at least the term in months (#{months}) — a " <>
          "straight-line schedule releases at least one cent per period"
    )
  end

  defp require_slice(changeset, _total, _months), do: changeset
end
