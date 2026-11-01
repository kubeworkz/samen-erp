defmodule Samen.Scopes.Finance.ReservePolicyShape do
  @moduledoc """
  The shape guard for an `InventoryReserve` policy (WS-ACCT Phase 9;
  ADR-054 D10).

  Two rules no per-attribute constraint can express:

      basis :age   → age_months is a positive integer
      basis :item  → age_months is nil AND applies_to names at least one item

  The first stops an "aged" policy that cannot say how old. The second stops
  the item basis from degenerating into "everything, at any age" — that is the
  age basis, and a policy that claims to target specific stock while naming
  none is a rule nobody can audit.

  Runs `before_action`, so the refusal lands inside the write's transaction with
  a field-level message rather than a database CHECK.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, &check/1)
  end

  defp check(changeset) do
    basis = attr(changeset, :basis)
    age = attr(changeset, :age_months)
    applies_to = attr(changeset, :applies_to) || []

    cond do
      basis == :age and not (is_integer(age) and age > 0) ->
        Ash.Changeset.add_error(changeset,
          field: :age_months,
          message: "an :age policy needs a positive age_months threshold"
        )

      basis == :item and not is_nil(age) ->
        Ash.Changeset.add_error(changeset,
          field: :age_months,
          message: "an :item policy is age-independent — leave age_months nil"
        )

      basis == :item and applies_to == [] ->
        Ash.Changeset.add_error(changeset,
          field: :applies_to,
          message: "an :item policy must name at least one item id"
        )

      length(Enum.uniq(applies_to)) != length(applies_to) ->
        Ash.Changeset.add_error(changeset,
          field: :applies_to,
          message: "applies_to names the same item more than once"
        )

      true ->
        changeset
    end
  end

  defp attr(changeset, field) do
    case Ash.Changeset.get_attribute(changeset, field) do
      %Ash.NotLoaded{} -> Map.get(changeset.data, field)
      nil -> Map.get(changeset.data, field)
      value -> value
    end
  end
end
