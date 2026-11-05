defmodule Samen.Scopes.Finance.GrantRecognitionOpening do
  @moduledoc """
  Open a grant's recognition schedule (WS-ACCT Phase 11; ADR-054 D8).

  A grant does not carry its own revenue engine. `:open_recognition` creates
  the Phase-6 `RevenueSchedule` that releases the award's `grant_deferred`
  liability as allowable cost is incurred:

    * `method: :cost_incurred` — the release is capped by the period's
      incurred allowable cost, never ahead of it;
    * `deferred_key: :grant_deferred` — the award receipt and the recognition
      meet in the same liability account;
    * `cost_object_id: grant.fund_cost_object_id` — the same `:fund` dimension
      the receipt and the allowable-cost postings carry, which is what makes
      R11 a join over one axis.

  The schedule is created inside the grant's transaction, so a grant never
  ends up half-opened. `schedule_id` is stamped once; a second call refuses.
  The monthly `RecognitionRun` owns every later posting.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset -> open(changeset, opts) end)
  end

  defp open(changeset, opts) do
    grant = changeset.data
    schedule_mod = Keyword.fetch!(opts, :schedule)

    if grant.schedule_id != nil do
      add_error(changeset, "this grant already has an open recognition schedule")
    else
      months =
        Samen.Scopes.Finance.GrantShape.months_between(grant.period_start, grant.period_end)

      attrs = %{
        org_id: org_id(changeset),
        source_key: "grant",
        source_id: grant.id,
        memo: "Grant recognition — #{grant.award_ref}",
        total_cents: grant.award_cents,
        start_on: grant.period_start,
        months: months,
        method: :cost_incurred,
        deferred_key: :grant_deferred,
        cost_object_id: grant.fund_cost_object_id
      }

      case schedule_mod
           |> Ash.Changeset.for_create(:create, attrs, authorize?: false)
           |> Ash.create(authorize?: false) do
        {:ok, schedule} ->
          Ash.Changeset.force_change_attribute(changeset, :schedule_id, schedule.id)

        {:error, reason} ->
          add_error(
            changeset,
            "the grant's recognition schedule cannot be opened: #{inspect(reason)}"
          )
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
