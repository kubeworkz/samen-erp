defmodule Samen.Scopes.Finance.JournalApproval do
  @moduledoc """
  Journal-entry approval and segregation of duties (WS-ACCT journal controls).

  A `JournalApprovalPolicy` row turns approval on for one org. When the policy
  applies, a HUMAN `:post`/`:void` is refused with
  `Samen.Approvals.ApprovalRequired`; a DISTINCT approver's decision re-invokes
  the same action as the preparer through `Samen.Approvals.Gate`.

  ## Who is the requester?

  The approval is bound to the entry's `prepared_by`, not to whoever happens to
  click Post. If a different principal tries to submit the entry, the action is
  refused before an approval is opened. Without that binding, colleague B could
  open the approval for colleague A's entry and then A could approve it —
  two names, but the preparer would still have approved their own work.

  ## What is outside the policy?

  * A posting with no actor is a SYSTEM cascade (accrual reversals,
    depreciation, recognition, document posting). Those actions have their own
    guards and are not human journal submissions; they are deliberately not
    sent through a human approval queue.
  * A policy that is absent or `enabled: false` leaves the ledger's existing
    behavior intact. This is an org control that must be turned on, not a
    silent migration of every historical posting.
  * The period lock, `PostBalance`, `DimensionBalance`, `PostGuard` and the DB
    immutability trigger still run on the approved invocation. Approval adds
    consent; it never bypasses a ledger invariant.

  ## Threshold

  `threshold_cents` is the minimum absolute entry size that needs approval
  (sum of debit cents). `0` means every human posting. The total is read from
  the PERSISTED lines, the same source `PostBalance` uses, so an approver
  consents to the entry that is actually stored.
  """

  use Ash.Resource.Change

  require Ash.Query

  @impl true
  def change(changeset, opts, context) do
    if approved_context?(changeset) do
      stamp_approval(changeset, context)
    else
      maybe_gate(changeset, opts, context)
    end
  end

  defp maybe_gate(changeset, opts, context) do
    actor_id = actor_id(context)

    cond do
      is_nil(actor_id) ->
        # A system cascade: no human to approve, and no human to hold
        # accountable. The action's own guards still apply.
        changeset

      true ->
        with {:ok, policy} <- load_policy(changeset, opts),
             true <- policy_applies?(policy, changeset),
             {:ok, changeset} <- bind_preparer(changeset, actor_id) do
          Samen.Approvals.Gate.change(
            changeset,
            [
              reason:
                "manual journal entry #{changeset.data.id} prepared by #{actor_id} " <>
                  "requires a distinct approver"
            ],
            context
          )
        else
          :no_policy -> changeset
          false -> changeset
          {:error, changeset} -> changeset
        end
    end
  end

  defp load_policy(changeset, opts) do
    policy_mod = Keyword.fetch!(opts, :policy)
    org_id = loaded_attribute(changeset, :org_id)

    case policy_mod
         |> Ash.Query.filter(org_id == ^org_id)
         |> Ash.read_one(authorize?: false) do
      {:ok, nil} ->
        :no_policy

      {:ok, policy} ->
        {:ok, policy}

      {:error, reason} ->
        {:error,
         error(changeset, "the journal approval policy could not be read: #{inspect(reason)}")}
    end
  end

  defp policy_applies?(%{enabled: false}, _changeset), do: false

  defp policy_applies?(%{threshold_cents: threshold}, changeset) do
    total_cents(changeset) >= threshold
  end

  defp policy_applies?(_, _changeset), do: false

  # The approval requester is the preparer. A different principal may not
  # submit someone else's entry: otherwise B could open the approval and A
  # (the preparer) could approve it, defeating the two-party control.
  defp bind_preparer(changeset, actor_id) do
    prepared_by = loaded_attribute(changeset, :prepared_by)

    cond do
      prepared_by in [nil, %Ash.NotLoaded{}] ->
        {:ok, Ash.Changeset.force_change_attribute(changeset, :prepared_by, actor_id)}

      prepared_by == actor_id ->
        {:ok, changeset}

      true ->
        {:error,
         error(
           changeset,
           "this entry was prepared by #{prepared_by}, not by the principal attempting to " <>
             "post it (#{actor_id}). Only the preparer may submit it for approval — that " <>
             "binding is what keeps the preparer from also being the approver."
         )}
    end
  end

  # The approved re-invocation carries the Gate's evidence. The context alone is
  # not trusted: a caller can set changeset context, so we re-read the approval
  # row and bind it to THIS resource, action, org, subject and preparer. Without
  # that check `context: %{approval_ok: true}` would be a universal bypass.
  defp stamp_approval(changeset, _context) do
    context = changeset.context || %{}
    approved_by = Map.get(context, :approved_by)
    approval_id = Map.get(context, :approval_id)

    with true <- is_binary(approved_by) and approved_by != "",
         true <- is_binary(approval_id),
         {:ok, approval} <- Samen.Approvals.get(approval_id),
         :ok <- verify_approval(changeset, approval, approved_by) do
      changeset
      |> bind_missing_preparer(approval.requested_by)
      |> Ash.Changeset.force_change_attribute(:approved_by, approved_by)
      |> Ash.Changeset.force_change_attribute(:approved_at, now())
      |> Ash.Changeset.force_change_attribute(:approval_id, approval_id)
    else
      _ ->
        error(
          changeset,
          "the approved journal posting could not be verified against its approval record"
        )
    end
  end

  defp verify_approval(changeset, approval, approved_by) do
    org_id = loaded_attribute(changeset, :org_id)
    prepared_by = loaded_attribute(changeset, :prepared_by)
    subject_ref = "samen:#{Samen.Info.abbrev(changeset.resource)}:#{changeset.data.id}"
    kind = "#{changeset.resource}:#{changeset.action.name}"

    cond do
      approval.state != :approved ->
        {:error, :not_approved}

      approval.org_id != org_id ->
        {:error, :wrong_org}

      approval.kind != kind ->
        {:error, :wrong_kind}

      approval.subject_ref != subject_ref ->
        {:error, :wrong_subject}

      approval.decided_by != approved_by ->
        {:error, :wrong_approver}

      approved_by == approval.requested_by ->
        {:error, :self_approval}

      is_binary(prepared_by) and prepared_by != approval.requested_by ->
        {:error, :wrong_preparer}

      true ->
        :ok
    end
  end

  defp bind_missing_preparer(changeset, requested_by) do
    case loaded_attribute(changeset, :prepared_by) do
      nil -> Ash.Changeset.force_change_attribute(changeset, :prepared_by, requested_by)
      _ -> changeset
    end
  end

  defp total_cents(changeset) do
    %{lines: lines} = Ash.load!(changeset.data, [:lines], authorize?: false)

    Enum.reduce(lines, 0, fn line, sum ->
      sum + (line.debit_cents || 0)
    end)
  end

  # `for_update` may hand us a sparse record; the attribute accessor then
  # returns `%Ash.NotLoaded{}`. Load exactly the field we need rather than
  # filtering a policy query with the sentinel.
  defp loaded_attribute(changeset, name) do
    case Ash.Changeset.get_attribute(changeset, name) do
      %Ash.NotLoaded{} -> Map.fetch!(Ash.load!(changeset.data, [name], authorize?: false), name)
      value -> value
    end
  end

  defp approved_context?(changeset) do
    Map.get(changeset.context || %{}, :approval_ok) == true
  end

  defp actor_id(%{actor: actor}), do: extract_id(actor)
  defp actor_id(_), do: nil

  defp extract_id(%{id: id}) when is_binary(id), do: id
  defp extract_id(id) when is_binary(id), do: id
  defp extract_id(_), do: nil

  defp error(changeset, message) do
    Ash.Changeset.add_error(changeset, field: :base, message: message)
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
