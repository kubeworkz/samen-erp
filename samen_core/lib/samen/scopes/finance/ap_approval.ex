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
    * an absent policy, empty steps, a disabled auto-approval flag, or an
      unreadable policy all fall back to the historical single-decision Gate.

  This change runs AFTER `ApInvoiceMatch`, so an over-tolerance bill is refused
  before any approval is opened. It runs BEFORE `PostingMarker` and `ApPosting`,
  so a directly approved bill still posts through the ordinary guarded
  transaction.
  """

  use Ash.Resource.Change

  require Ash.Query

  alias Samen.Approvals.Gate

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
      {:ok, policy} ->
        if auto_approve?(policy, total_cents) do
          changeset
        else
          gate(changeset, context, total_cents, policy)
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

  defp gate(changeset, context, total_cents, policy) do
    threshold = if is_map(policy), do: Map.get(policy, :threshold_cents), else: nil
    steps = if is_map(policy), do: step_specs(policy), else: []

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

  defp step_specs(%{steps: steps}) when is_list(steps) do
    steps
    |> Enum.map(fn step ->
      type = to_string(Map.get(step, "approver_type") || Map.get(step, :approver_type))
      approver = to_string(Map.get(step, "approver") || Map.get(step, :approver))
      role = Map.get(step, "role") || Map.get(step, :role)

      %{"approver_type" => type, "approver" => approver}
      |> maybe_put_step_role(type, role)
    end)
    |> Enum.filter(fn
      %{"approver_type" => type, "approver" => approver}
      when type in ["user", "role"] and is_binary(approver) and approver != "" ->
        true

      _ ->
        false
    end)
  end

  defp step_specs(_policy), do: []

  defp maybe_put_step_role(spec, "user", role) when role in ["admin", "member"],
    do: Map.put(spec, "role", role)

  defp maybe_put_step_role(spec, _type, _role), do: spec

  defp total_cents(changeset) do
    case loaded_attribute(changeset, :lines) do
      lines when is_list(lines) ->
        Enum.reduce(lines, 0, fn line, sum ->
          sum + (Map.get(line, :amount_cents) || Map.get(line, "amount_cents") || 0)
        end)

      _ ->
        0
    end
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
