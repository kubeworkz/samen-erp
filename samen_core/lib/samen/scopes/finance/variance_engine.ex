defmodule Samen.Scopes.Finance.VarianceEngine do
  @moduledoc """
  The period's variance run (WS-ACCT Phase 7; ADR-054 D4, R8): compute all
  seven classes from the card and the declared actuals, then post each
  **non-zero** one as its own variance row and journal entry, in ONE
  transaction.

  ## The run is exactly-once, and a retry is a no-op

  The run's identity is `{org, cost object, period}`. If ANY variance row
  already exists for that tuple the whole run is skipped, silently and
  successfully: the period has been posted, and recomputing it against a
  different set of actuals would silently replace a reported fact. A
  correction is a reversing entry, not a second run. The table's unique index
  on `{org, cost object, period, type}` is the belt under that read.

  Because the entire run is one transaction, a partial state cannot exist:
  either every non-zero class posted or none did. That is what makes the
  no-op-on-retry posture safe rather than merely convenient.

  ## The card must be the one IN FORCE

  `StandardCard.in_force/4` resolves the period's card, and the run refuses to
  use a different one (`:standard_not_in_force`). A caller holding last
  quarter's card id, or a card that starts next month, cannot price this
  period with it. This is the guard sabotage 407 removes: the caller "always
  passes the right card" is exactly the assumption that lets a revised
  standard silently reprice a closed period.

  ## Measured zero is a fact; unmeasured is not

  A class the card MEASURES (it has a labour line) is recorded even when its
  difference is exactly zero: "March's labour variance was nil" is a real
  period-end finding, and the row is also the run's marker, which is what makes
  a retry a clean no-op after a zero-variance period. A class the card does not
  measure at all (no labour line) records nothing -- a zero there would be a
  fact about nothing and would hide which classes the card actually prices.
  Only a non-zero row posts an entry; a measured-zero row names its accounts
  and posts none.

  ## Our error, not an exception

  Every refusal is added to the card action's changeset as an error, so the
  transaction rolls back and the caller gets a governed `{:error, changeset}`.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      run(changeset, opts)
    end)
  end

  defp run(changeset, opts) do
    standard = changeset.data
    line_mod = Keyword.fetch!(opts, :standard_line)
    variance_mod = Keyword.fetch!(opts, :variance)

    # An update changeset built from a record the caller holds may carry an
    # `Ash.NotLoaded` org_id (the EntryLines discipline): load it explicitly
    # rather than filtering on a placeholder.
    org_id =
      case Ash.Changeset.get_attribute(changeset, :org_id) do
        %Ash.NotLoaded{} -> Ash.load!(standard, [:org_id], authorize?: false).org_id
        nil -> Ash.load!(standard, [:org_id], authorize?: false).org_id
        value -> value
      end

    period_key = Ash.Changeset.get_argument(changeset, :period_key)
    actuals = Ash.Changeset.get_argument(changeset, :actuals)

    case post(standard, org_id, period_key, actuals, line_mod, variance_mod) do
      :ok ->
        changeset

      {:error, reason} ->
        Ash.Changeset.add_error(changeset,
          field: :base,
          message: "the variance run cannot post: #{format(reason)}"
        )
    end
  end

  defp post(standard, org_id, period_key, actuals, line_mod, variance_mod) do
    with {:ok, period_end} <- Samen.Scopes.Finance.StandardCard.period_end(period_key),
         {:ok, in_force} <-
           Samen.Scopes.Finance.StandardCard.in_force(
             standard.__struct__,
             org_id,
             standard.cost_object_id,
             period_end
           ),
         :ok <- ensure_in_force(in_force, standard),
         {:ok, posted?} <-
           already_posted?(variance_mod, org_id, standard.cost_object_id, period_key) do
      if posted? do
        :ok
      else
        compute_and_post(
          standard,
          org_id,
          period_key,
          actuals,
          line_mod,
          variance_mod
        )
      end
    end
  end

  defp ensure_in_force(nil, standard),
    do: {:error, {:no_standard, standard.cost_object_id}}

  defp ensure_in_force(%{id: id}, %{id: id}), do: :ok

  defp ensure_in_force(in_force, standard),
    do: {:error, {:standard_not_in_force, standard.id, in_force.id}}

  defp already_posted?(variance_mod, org_id, cost_object_id, period_key) do
    require Ash.Query

    rows =
      variance_mod
      |> Ash.Query.filter(
        org_id == ^org_id and cost_object_id == ^cost_object_id and period_key == ^period_key
      )
      |> Ash.Query.limit(1)
      |> Ash.read!(authorize?: false)

    {:ok, rows != []}
  end

  defp compute_and_post(standard, org_id, period_key, actuals, line_mod, variance_mod) do
    require Ash.Query

    lines =
      line_mod
      |> Ash.Query.filter(org_id == ^org_id and standard_id == ^standard.id)
      |> Ash.read!(authorize?: false)

    with :ok <- ensure_card_has_lines(lines),
         {:ok, normalized} <- Samen.Scopes.Finance.VarianceMath.normalize(lines, actuals) do
      lines
      |> Samen.Scopes.Finance.VarianceMath.plan(normalized)
      |> Enum.reduce_while(:ok, fn spec, :ok ->
        if spec.measured? do
          post_one(variance_mod, standard, org_id, period_key, spec)
        else
          {:cont, :ok}
        end
      end)
    end
  end

  defp ensure_card_has_lines([]), do: {:error, :empty_card}
  defp ensure_card_has_lines(_lines), do: :ok

  defp post_one(variance_mod, standard, org_id, period_key, spec) do
    attrs = %{
      org_id: org_id,
      standard_id: standard.id,
      cost_object_id: standard.cost_object_id,
      period_key: period_key,
      type: spec.type,
      amount_cents: spec.amount_cents,
      actual_amount_cents: spec.actual_amount_cents,
      standard_amount_cents: spec.standard_amount_cents,
      inputs: spec.inputs
    }

    case variance_mod
         |> Ash.Changeset.for_create(:post, attrs, authorize?: false)
         |> Ash.create(authorize?: false) do
      {:ok, _variance} -> {:cont, :ok}
      {:error, reason} -> {:halt, {:error, {:variance_failed, spec.type, reason}}}
    end
  end

  defp format(:empty_card),
    do: "the card has no standard lines, so there is nothing to price"

  defp format({:no_standard, cost_object_id}),
    do:
      "no standard card is in force for cost object #{cost_object_id} in that period " <>
        "(fail-honest — a variance on no standard is not zero, it is unknown)"

  defp format({:standard_not_in_force, given, in_force}),
    do:
      "the card #{given} is not the card in force for that period (#{in_force} is) — " <>
        "a revised standard must not reprice a period it does not govern"

  defp format({:missing_actual_line, id}),
    do:
      "no actual was declared for standard line #{id} — a cost the period did not report " <>
        "cannot be priced"

  defp format({:unknown_actual_line, id}),
    do: "the actuals name line #{id}, which is not on this card"

  defp format({:invalid_actual, field}), do: "the actual `#{field}` is not a non-negative integer"

  defp format({:variance_failed, type, reason}),
    do: "the #{type} variance could not be posted: #{inspect_reason(reason)}"

  defp format(:bad_period), do: "the period key is not a valid \"YYYY-MM\" month"
  defp format(other), do: inspect(other)

  defp inspect_reason(%Ash.Error.Invalid{} = error), do: Exception.message(error)
  defp inspect_reason(other), do: inspect(other)
end
