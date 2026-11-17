defmodule Samen.Scopes.Finance.PayrollHold do
  @moduledoc """
  Record a named exception on one imported payroll register.

  A hold is the only way an imported payroll entry may be omitted from the
  close without being posted or voided. It is therefore attributable and
  final: the action requires an authenticated principal, a non-blank bounded
  exception, and cannot overwrite an earlier hold. The close check accepts the
  hold only when all three facts (`exception`, `held_at`, `held_by`) agree.
  """

  use Ash.Resource.Change

  @max_exception_length 500

  @impl true
  def change(changeset, _opts, context) do
    actor =
      actor_id(Map.get(context, :actor)) ||
        actor_id(get_in(changeset.context, [:private, :actor]))

    exception = Ash.Changeset.get_argument(changeset, :exception)
    trimmed = if is_binary(exception), do: String.trim(exception)

    cond do
      Map.get(changeset.data, :held_at) != nil ->
        error(changeset, "this payroll import is already held; a hold is final")

      is_nil(actor) ->
        error(changeset, "a principal identity is required to record a payroll hold exception")

      not valid_exception?(trimmed) ->
        error(
          changeset,
          "a named payroll hold exception is required (1-#{@max_exception_length} characters)"
        )

      true ->
        changeset
        |> Ash.Changeset.force_change_attribute(:exception, trimmed)
        |> Ash.Changeset.force_change_attribute(:held_at, now())
        |> Ash.Changeset.force_change_attribute(:held_by, actor)
    end
  end

  defp valid_exception?(value) when is_binary(value) do
    value != "" and String.length(value) <= @max_exception_length
  end

  defp valid_exception?(_value), do: false

  defp actor_id(%{id: id}) when is_binary(id), do: id
  defp actor_id(_actor), do: nil

  defp error(changeset, message),
    do: Ash.Changeset.add_error(changeset, field: :base, message: message)

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
