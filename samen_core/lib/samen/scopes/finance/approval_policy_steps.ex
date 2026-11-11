defmodule Samen.Scopes.Finance.ApprovalPolicySteps do
  @moduledoc """
  Validation for an approval policy's ordered `steps` snapshot.

  Each step is a bounded map:

      %{"approver_type" => "user", "approver" => "user-id"}
      %{"approver_type" => "user", "approver" => "user-id", "role" => "admin"}
      %{"approver_type" => "role", "approver" => "admin"}

  A named-user step may carry an optional `"role"` filter. The engine then
  requires the approving user to hold that role as well as match the id. An
  absent or blank role means any role. The policy table is deliberately
  generic; AP is the first consumer. No domain inputs are stored here — just
  the approver routing decision.
  """

  use Ash.Resource.Change

  @roles ~w(admin member)

  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :steps) do
      nil ->
        changeset

      steps when is_list(steps) ->
        steps
        |> Enum.with_index(1)
        |> Enum.reduce(changeset, &validate_step/2)

      _ ->
        error(changeset, "steps must be a list")
    end
  end

  defp validate_step({step, index}, changeset) do
    type = value(step, "approver_type")
    approver = value(step, "approver")
    role = value(step, "role")

    cond do
      type == "user" and not user_role_ok?(role) ->
        error(changeset, "step #{index} names an unknown role filter #{inspect(role)}")

      type == "user" and is_binary(approver) and String.trim(approver) != "" ->
        changeset

      type == "role" and approver in @roles ->
        changeset

      type == "role" ->
        error(changeset, "step #{index} names an unknown role #{inspect(approver)}")

      type == "user" ->
        error(changeset, "step #{index} needs a non-blank user id")

      true ->
        error(
          changeset,
          "step #{index} must name approver_type \"user\" or \"role\" and an approver"
        )
    end
  end

  defp user_role_ok?(nil), do: true
  defp user_role_ok?(""), do: true
  defp user_role_ok?(role), do: role in @roles

  defp value(step, key) when is_map(step), do: Map.get(step, key) || Map.get(step, safe_atom(key))
  defp value(_step, _key), do: nil

  defp safe_atom(key), do: String.to_existing_atom(key)

  defp error(changeset, message),
    do: Ash.Changeset.add_error(changeset, field: :steps, message: message)
end
