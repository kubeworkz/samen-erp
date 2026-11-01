defmodule Samen.Scopes.Finance.ReserveDrafting do
  @moduledoc """
  The drafting cascade for an obsolescence write-down (WS-ACCT Phase 9;
  ADR-054 D10).

  Runs on `:draft`'s `before_action`: it loads the policy, runs
  `Samen.Scopes.Finance.ReserveAssessment`, and — only if the assessment found
  bookable stock — forces the total onto the header and materializes one line
  per eligible item in the same transaction.

  It accepts NO amounts from the caller. The draft's cents are the assessment's
  cents; a caller who wants a different number changes the policy or the stock,
  not the proposal. The refusal when there is nothing to write down is
  deliberate: a zero-cent write-down is not a fact, and an empty draft would
  sit in an approval queue asking a human to consent to nothing.

  An eligible item without an inventory account aborts the whole draft with the
  SKU named. Posting half a write-down because one item was not linked would
  leave the ledger disagreeing with the stock it claims to have written down —
  the fail-honest posture is to refuse and let the operator link the item.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      draft(changeset, org_id(changeset), opts)
    end)
  end

  defp draft(changeset, org_id, opts) do
    assessment_modules = Keyword.fetch!(opts, :assessment)

    if Enum.any?(assessment_modules, fn {_key, mod} -> is_nil(mod) end) do
      error(
        changeset,
        "this host has not wired an Inventory scope into Finance — a write-down " <>
          "cannot be assessed against stock it cannot read (pass `inventory:` to " <>
          "`use Samen.Scopes.Finance`)"
      )
    else
      policy_mod = Keyword.fetch!(opts, :policy)
      line_mod = Keyword.fetch!(opts, :line)

      with {:ok, policy} <- load_policy(policy_mod, org_id, changeset),
           {:ok, assessment} <- assess(changeset, org_id, policy, assessment_modules, line_mod),
           :ok <- require_candidates(assessment),
           :ok <- require_bookable(assessment) do
        changeset
        |> Ash.Changeset.force_change_attribute(:amount_cents, assessment.total_cents)
        |> Ash.Changeset.force_change_attribute(:status, :draft)
        |> Ash.Changeset.after_action(fn _changeset, header ->
          materialize_lines(header, org_id, line_mod, assessment.candidates)
        end)
      else
        {:error, message} -> error(changeset, message)
      end
    end
  end

  defp load_policy(policy_mod, org_id, changeset) do
    policy_id = Ash.Changeset.get_attribute(changeset, :policy_id)

    # `org_id` is not in the default select (a tenant column), so it is loaded
    # explicitly and compared — a foreign policy is refused, never assessed.
    with {:ok, policy} <- Ash.get(policy_mod, policy_id, authorize?: false),
         %{org_id: ^org_id} <- Ash.load!(policy, [:org_id], authorize?: false) do
      {:ok, policy}
    else
      {:ok, _foreign} -> {:error, "the reserve policy does not belong to this org"}
      {:error, _reason} -> {:error, "the reserve policy does not exist"}
    end
  end

  defp assess(changeset, org_id, policy, modules, line_mod) do
    assessed_on =
      Ash.Changeset.get_attribute(changeset, :assessed_on) || Date.utc_today()

    {:ok,
     Samen.Scopes.Finance.ReserveAssessment.assess(org_id, policy,
       items: Keyword.fetch!(modules, :items),
       levels: Keyword.fetch!(modules, :levels),
       ledger: Keyword.fetch!(modules, :ledger),
       write_downs: changeset.resource,
       lines: line_mod,
       as_of: assessed_on
     )}
  end

  defp require_candidates(%{candidates: []}) do
    {:error,
     "the assessment found no bookable stock for this policy — there is nothing to " <>
       "draft (an empty write-down is not a fact)"}
  end

  defp require_candidates(_assessment), do: :ok

  defp require_bookable(%{bookable?: true}), do: :ok

  defp require_bookable(%{missing_accounts: skus}) do
    {:error,
     "these eligible items have no default inventory account, so the credit leg " <>
       "cannot be named: #{Enum.join(skus, ", ")}"}
  end

  defp materialize_lines(header, org_id, line_mod, candidates) do
    Enum.reduce_while(candidates, {:ok, header}, fn candidate, {:ok, header} ->
      attrs = %{
        org_id: org_id,
        write_down_id: header.id,
        item_id: candidate.item_id,
        quantity: candidate.quantity,
        cost_cents: candidate.cost_cents,
        write_down_cents: candidate.write_down_cents,
        inventory_account_id: candidate.inventory_account_id
      }

      case line_mod
           |> Ash.Changeset.for_create(:materialize, attrs, authorize?: false)
           |> Ash.create(authorize?: false) do
        {:ok, _line} -> {:cont, {:ok, header}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp org_id(changeset) do
    case Ash.Changeset.get_attribute(changeset, :org_id) do
      %Ash.NotLoaded{} -> persisted_org_id(changeset.data)
      nil -> persisted_org_id(changeset.data)
      value -> value
    end
  end

  # `org_id` is a tenant column and not in the default select; a record loaded
  # by a gate handler carries it unloaded. Load it explicitly rather than
  # comparing against an #Ash.NotLoaded{} placeholder.
  defp persisted_org_id(record) do
    case record.org_id do
      %Ash.NotLoaded{} -> Ash.load!(record, [:org_id], authorize?: false).org_id
      value -> value
    end
  end

  defp error(changeset, message) do
    Ash.Changeset.add_error(changeset, field: :base, message: message)
  end
end
