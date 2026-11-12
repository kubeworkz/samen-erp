defmodule Samen.Scopes.Finance.ApprovalPolicyPeriods do
  @moduledoc """
  Validation for an approval policy's optional period scope.

  A period key is a fiscal month (`YYYY-MM`). Empty means every period. Invalid
  keys would silently make the control look scoped while never matching, so they
  are refused at the policy boundary instead. Duplicates are folded to one key
  before the approval Gate snapshots the proposed change.
  """

  use Ash.Resource.Change

  @period ~r/^\d{4}-(0[1-9]|1[0-2])$/

  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :period_keys) do
      nil ->
        changeset

      keys when is_list(keys) ->
        case Enum.reject(keys, &valid?/1) do
          [] ->
            Ash.Changeset.force_change_attribute(changeset, :period_keys, Enum.uniq(keys))

          invalid ->
            Ash.Changeset.add_error(
              changeset,
              field: :period_keys,
              message: "period keys must be YYYY-MM fiscal months; invalid: #{inspect(invalid)}"
            )
        end

      _other ->
        Ash.Changeset.add_error(changeset,
          field: :period_keys,
          message: "period keys must be a list"
        )
    end
  end

  defp valid?(key) when is_binary(key), do: Regex.match?(@period, key)
  defp valid?(_), do: false
end
