defmodule Samen.Scopes.Finance.GrantShape do
  @moduledoc """
  The grant document's shape guard (WS-ACCT Phase 11; ADR-054 D8).

  Three fail-closed checks on create — all inside the action's transaction:

    * the period is a real term (`period_end >= period_start`);
    * the award can fund its own schedule (`award_cents >= months`, the
      `ScheduleShape` floor — a term of 12 months with 6 cents cannot release
      one cent per month);
    * `fund_cost_object_id` names a SAME-ORG `CostObject` whose `kind` is
      `:fund`. A grant dimensioned to a `:project` or `:chip` would reconcile
      against the wrong axis, so it is refused rather than silently accepted.

  The budget and schedule references are covered by `SameOrgFk`; this module
  only checks what a generic FK cannot (the kind, and the date arithmetic).
  """

  use Ash.Resource.Change

  require Ash.Query

  @impl true
  def change(changeset, opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      with :ok <- check_period(changeset),
           :ok <- check_award(changeset),
           :ok <- check_fund(changeset, Keyword.fetch!(opts, :cost_object)) do
        changeset
      else
        {:error, message} -> add_error(changeset, message)
      end
    end)
  end

  @doc "Inclusive months between two dates (the grant schedule's term)."
  def months_between(%Date{} = start_on, %Date{} = end_on) do
    end_on.year * 12 + end_on.month - (start_on.year * 12 + start_on.month) + 1
  end

  defp check_period(changeset) do
    start_on = Ash.Changeset.get_attribute(changeset, :period_start)
    end_on = Ash.Changeset.get_attribute(changeset, :period_end)

    cond do
      is_nil(start_on) or is_nil(end_on) ->
        {:error, "a grant needs both period_start and period_end"}

      Date.compare(end_on, start_on) == :lt ->
        {:error, "period_end must not be before period_start"}

      true ->
        :ok
    end
  end

  defp check_award(changeset) do
    award = Ash.Changeset.get_attribute(changeset, :award_cents)
    start_on = Ash.Changeset.get_attribute(changeset, :period_start)
    end_on = Ash.Changeset.get_attribute(changeset, :period_end)

    cond do
      not is_integer(award) or award <= 0 ->
        {:error, "award_cents must be a positive integer"}

      is_nil(start_on) or is_nil(end_on) ->
        :ok

      award < months_between(start_on, end_on) ->
        {:error,
         "award_cents must be at least the term in months — a schedule cannot release " <>
           "less than one cent per month"}

      true ->
        :ok
    end
  end

  defp check_fund(changeset, cost_object_mod) do
    fund_id = Ash.Changeset.get_attribute(changeset, :fund_cost_object_id)
    org_id = org_id(changeset)

    if is_nil(fund_id) do
      {:error, "a grant must name its fund cost object"}
    else
      case cost_object_mod
           |> Ash.Query.filter(id == ^fund_id)
           |> Ash.Query.ensure_selected([:org_id, :kind])
           |> Ash.read_one(authorize?: false) do
        {:ok, %{org_id: ^org_id, kind: :fund}} ->
          :ok

        {:ok, %{org_id: ^org_id}} ->
          {:error, "fund_cost_object_id must name a CostObject of kind :fund"}

        {:ok, _foreign} ->
          {:error, "fund_cost_object_id must name a cost object in this org"}

        {:error, _reason} ->
          {:error, "fund_cost_object_id does not name a known CostObject"}
      end
    end
  end

  defp org_id(changeset) do
    case Ash.Changeset.get_attribute(changeset, :org_id) do
      %Ash.NotLoaded{} -> Ash.load!(changeset.data, [:org_id], authorize?: false).org_id
      nil -> Ash.load!(changeset.data, [:org_id], authorize?: false).org_id
      value -> value
    end
  end

  defp add_error(changeset, message) do
    Ash.Changeset.add_error(changeset, field: :base, message: message)
  end
end
