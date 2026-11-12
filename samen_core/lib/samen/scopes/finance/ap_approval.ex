defmodule Samen.Scopes.Finance.ApApproval do
  @moduledoc """
  Amount-threshold and ordered-step routing for AP bill approval.

  The org policy is the generic `ApprovalPolicy` row keyed
  `\"ap_invoice:approve\"`:

    * below `threshold_cents`, when `auto_approve_below` is explicitly true, the
      bill may be approved directly;
    * otherwise the ordinary ADR-040 Gate opens an approval whose `steps` are a
      snapshot of the policy's ordered chain;
    * named-user and tenant-role steps are enforced by `Samen.Approvals`; a
      named-user step may also require a tenant role, and the engine enforces
      the id and the role together. Only the final step executes the gated
      `:approve` action and posting;
    * `account_ids` / `period_keys` scope the configured threshold and chain.
      An out-of-scope bill keeps the ordinary single-decision Gate and is never
      auto-approved by the scoped policy;
    * an absent policy, empty steps, a disabled auto-approval flag, an
      out-of-scope bill, or an unreadable policy all fall back to the historical
      single-decision Gate.

  This change runs AFTER `ApInvoiceMatch`, so an over-tolerance bill is refused
  before any approval is opened. It runs BEFORE `PostingMarker` and `ApPosting`,
  so a directly approved bill still posts through the ordinary guarded
  transaction.
  """

  use Ash.Resource.Change

  require Ash.Query

  alias Samen.Approvals.Gate
  alias Samen.Scopes.Finance.ApprovalPolicySteps

  @policy_kind "ap_invoice:approve"

  @doc "Stable policy key for AP bill approval."
  def policy_kind, do: @policy_kind

  @impl true
  def change(changeset, opts, context) do
    if approved_context?(changeset) do
      changeset
    else
      maybe_gate(changeset, opts, context)
    end
  end

  defp maybe_gate(changeset, opts, context) do
    policy_mod = Keyword.fetch!(opts, :policy)
    org_id = loaded_attribute(changeset, :org_id)
    total_cents = total_cents(changeset)

    case load_policy(policy_mod, org_id) do
      {:ok, nil} ->
        gate(changeset, context, total_cents, nil)

      {:ok, policy} ->
        if policy_applies?(policy, changeset) do
          if auto_approve?(policy, total_cents) do
            changeset
          else
            gate(changeset, context, total_cents, policy)
          end
        else
          # Scoped policy: outside its account/period scope the bill keeps the
          # ordinary one-decision Gate. Never auto-approve merely because a
          # configured condition did not match.
          gate(changeset, context, total_cents, nil)
        end

      {:error, _reason} ->
        # Fail closed: an unreadable policy must never become an implicit
        # auto-approval. The Gate's own failure is honest if the engine is
        # unwired as well.
        gate(changeset, context, total_cents, nil)
    end
  end

  defp load_policy(policy_mod, org_id) do
    policy_mod
    |> Ash.Query.filter(org_id == ^org_id and kind == ^@policy_kind)
    |> Ash.Query.limit(1)
    |> Ash.read_one(authorize?: false)
  end

  defp auto_approve?(%{auto_approve_below: true, threshold_cents: threshold}, total_cents)
       when is_integer(threshold) and total_cents < threshold,
       do: true

  defp auto_approve?(_policy, _total_cents), do: false

  defp policy_applies?(policy, changeset) do
    account_scope_matches?(Map.get(policy, :account_ids, []), lines(changeset)) and
      period_scope_matches?(Map.get(policy, :period_keys, []), changeset)
  end

  defp account_scope_matches?([], _lines), do: true

  defp account_scope_matches?(account_ids, lines) when is_list(account_ids) do
    scoped = MapSet.new(account_ids, &to_string/1)

    Enum.any?(lines, fn line ->
      account_id = Map.get(line, :account_id) || Map.get(line, "account_id")
      is_binary(account_id) and MapSet.member?(scoped, account_id)
    end)
  end

  defp account_scope_matches?(_account_ids, _lines), do: false

  defp period_scope_matches?([], _changeset), do: true

  defp period_scope_matches?(period_keys, changeset) when is_list(period_keys) do
    case loaded_attribute(changeset, :bill_date) do
      %Date{} = date -> Calendar.strftime(date, "%Y-%m") in period_keys
      _ -> false
    end
  end

  defp period_scope_matches?(_period_keys, _changeset), do: false

  defp lines(changeset) do
    case loaded_attribute(changeset, :lines) do
      lines when is_list(lines) -> lines
      _ -> []
    end
  end

  defp gate(changeset, context, total_cents, policy) do
    threshold = if is_map(policy), do: Map.get(policy, :threshold_cents), else: nil
    steps = if is_map(policy), do: ApprovalPolicySteps.step_specs(policy), else: []

    reason =
      case {threshold, length(steps)} do
        {threshold, count} when is_integer(threshold) and count > 1 ->
          "AP bill #{changeset.data.id} total #{total_cents} is at or above the org " <>
            "approval threshold of #{threshold} cents and needs #{count} sequential approvals"

        {threshold, _count} when is_integer(threshold) ->
          "AP bill #{changeset.data.id} total #{total_cents} is at or above the org " <>
            "approval threshold of #{threshold} cents and needs a distinct approver"

        {_threshold, count} when count > 1 ->
          "AP bill #{changeset.data.id} needs #{count} sequential approvals"

        _ ->
          "AP bill #{changeset.data.id} needs a distinct approver"
      end

    Gate.change(changeset, [reason: reason, steps: steps], context)
  end

  defp total_cents(changeset) do
    Enum.reduce(lines(changeset), 0, fn line, sum ->
      sum + (Map.get(line, :amount_cents) || Map.get(line, "amount_cents") || 0)
    end)
  end

  defp loaded_attribute(changeset, name) do
    case Ash.Changeset.get_attribute(changeset, name) do
      %Ash.NotLoaded{} ->
        Map.fetch!(Ash.load!(changeset.data, [name], authorize?: false), name)

      value ->
        value
    end
  end

  defp approved_context?(changeset),
    do: Map.get(changeset.context || %{}, :approval_ok) == true
end
