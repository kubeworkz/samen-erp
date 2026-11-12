defmodule Samen.Scopes.Finance.ApprovalPolicySteps do
  @moduledoc """
  Validation and normalization for an approval policy's ordered `steps` snapshot.

  Each step is a bounded map:

      %{"approver_type" => "user", "approver" => "user-id"}
      %{"approver_type" => "user", "approver" => "user-id", "role" => "admin"}
      %{"approver_type" => "role", "approver" => "admin"}

  A named-user step may carry an optional `"role"` filter. The engine then
  requires the approving user to hold that role as well as match the id. An
  absent or blank role means any role. The policy table is deliberately
  generic; journal and AP are consumers. No domain inputs are stored here — just
  the approver routing decision.

  An action may pass `text_argument: :steps_text` to accept a JSON array from
  the settings form. The parsed value replaces `steps`; a syntax or shape error
  is attached to the action instead of being silently treated as no chain.
  """

  use Ash.Resource.Change

  @roles ~w(admin member)

  @impl true
  def change(changeset, opts, _context) do
    changeset
    |> apply_text_argument(opts)
    |> validate_steps()
  end

  @doc "Normalize a policy or a raw step list into the Gate's string-keyed specs."
  def step_specs(%{steps: steps}), do: step_specs(steps)

  def step_specs(steps) when is_list(steps) do
    Enum.flat_map(steps, fn
      step when is_map(step) ->
        type = string_value(Map.get(step, "approver_type") || Map.get(step, :approver_type))
        approver = string_value(Map.get(step, "approver") || Map.get(step, :approver))
        role = string_value(Map.get(step, "role") || Map.get(step, :role))

        if type in ["user", "role"] and approver != "" do
          [
            %{"approver_type" => type, "approver" => approver}
            |> maybe_put_step_role(type, role)
          ]
        else
          []
        end

      _other ->
        []
    end)
  end

  def step_specs(_steps), do: []

  defp apply_text_argument(changeset, opts) do
    case Keyword.get(opts, :text_argument) do
      nil ->
        changeset

      argument ->
        case Ash.Changeset.get_argument(changeset, argument) do
          nil ->
            changeset

          value when is_binary(value) ->
            case String.trim(value) do
              "" ->
                Ash.Changeset.force_change_attribute(changeset, :steps, [])

              text ->
                case Jason.decode(text) do
                  {:ok, steps} when is_list(steps) ->
                    Ash.Changeset.force_change_attribute(changeset, :steps, steps)

                  {:ok, _other} ->
                    error(changeset, "steps must be a JSON array")

                  {:error, _reason} ->
                    error(changeset, "steps must be valid JSON")
                end
            end

          _other ->
            error(changeset, "steps must be valid JSON")
        end
    end
  end

  defp validate_steps(changeset) do
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

  defp string_value(nil), do: ""
  defp string_value(value) when is_binary(value), do: value
  defp string_value(value) when is_atom(value), do: Atom.to_string(value)
  defp string_value(_value), do: ""

  defp maybe_put_step_role(spec, "user", role) when role in @roles,
    do: Map.put(spec, "role", role)

  defp maybe_put_step_role(spec, _type, _role), do: spec

  defp error(changeset, message),
    do: Ash.Changeset.add_error(changeset, field: :steps, message: message)
end
