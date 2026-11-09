defmodule Samen.Scopes.Finance.PreparedBy do
  @moduledoc """
  Stamps `prepared_by` from the acting principal when a journal entry is
  created (WS-ACCT journal controls).

  The write is SYSTEM-owned: `prepared_by` is not an accepted create input, so
  a caller cannot name a different preparer to evade the distinct-preparer
  check. System cascades that run without an actor leave it NULL — an honest
  absence, never a fabricated name.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, context) do
    if changeset.action && changeset.action.type == :create do
      case actor_id(context) do
        nil -> changeset
        id -> Ash.Changeset.force_change_attribute(changeset, :prepared_by, id)
      end
    else
      changeset
    end
  end

  defp actor_id(%{actor: actor}), do: extract(actor)
  defp actor_id(_), do: nil

  defp extract(%{id: id}) when is_binary(id), do: id
  defp extract(id) when is_binary(id), do: id
  defp extract(_), do: nil
end
