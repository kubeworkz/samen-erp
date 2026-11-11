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

  ## Revision binding

  An approval is bound to the entry's material content, not just its id. The
  Gate's `subject_ref` carries a SHA-256 digest of the entry date, memo and
  persisted lines. The approved re-invocation recomputes that digest and
  refuses if it differs, so a draft changed after the approver consented cannot
  ride the old approval. The `:update` action also refuses any edit while a
  post/void approval is pending, which keeps the approval and the stored entry
  in sync at the source.
  """

  use Ash.Resource.Change

  require Ash.Query

  @impl true
  def change(changeset, opts, context) do
    cond do
      Keyword.get(opts, :mode) == :edit_guard ->
        refuse_edits_while_pending(changeset)

      approved_context?(changeset) ->
        stamp_approval(changeset, context)

      true ->
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
          revision = entry_digest(changeset)

          Samen.Approvals.Gate.change(
            changeset,
            [
              reason:
                "manual journal entry #{changeset.data.id} prepared by #{actor_id} " <>
                  "requires a distinct approver",
              subject_ref: revisioned_subject_ref(changeset, revision)
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

  defp policy_applies?(%{enabled: true} = policy, changeset) do
    lines = load_lines(changeset)

    total_cents(lines) >= Map.get(policy, :threshold_cents, 0) and
      account_scope?(policy, lines) and period_scope?(policy, changeset)
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
      {:error, :entry_changed} ->
        error(
          changeset,
          "the journal entry changed after approval was requested; request a new approval " <>
            "for the current entry"
        )

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
    expected_subject_ref = revisioned_subject_ref(changeset, entry_digest(changeset))
    kind = "#{changeset.resource}:#{changeset.action.name}"

    cond do
      approval.state != :approved ->
        {:error, :not_approved}

      approval.org_id != org_id ->
        {:error, :wrong_org}

      approval.kind != kind ->
        {:error, :wrong_kind}

      approval.subject_ref != expected_subject_ref ->
        {:error, :entry_changed}

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

  defp refuse_edits_while_pending(changeset) do
    org_id = loaded_attribute(changeset, :org_id)
    resource = changeset.resource
    entry_id = changeset.data.id

    kinds = [
      Samen.Approvals.Gate.kind_for(resource, :post),
      Samen.Approvals.Gate.kind_for(resource, :void)
    ]

    Enum.reduce_while(kinds, changeset, fn kind, current ->
      case pending_for_entry?(org_id, kind, resource, entry_id) do
        {:ok, true} ->
          {:halt,
           error(
             current,
             "a journal approval is pending for this entry; cancel or decide it before " <>
               "editing the draft"
           )}

        {:ok, false} ->
          {:cont, current}

        {:error, :no_approvals_module} ->
          {:cont, current}

        {:error, reason} ->
          {:halt,
           error(
             current,
             "could not check pending journal approvals: #{inspect(reason)}"
           )}
      end
    end)
  end

  defp pending_for_entry?(org_id, kind, resource, entry_id) do
    case Samen.Approvals.list_pending(org_id, kind) do
      {:ok, approvals} ->
        prefix = "samen:#{Samen.Info.abbrev(resource)}:#{entry_id}"

        {:ok,
         Enum.any?(approvals, fn approval ->
           approval.subject_ref == prefix or
             String.starts_with?(approval.subject_ref, prefix <> ":")
         end)}

      {:error, _reason} = error ->
        error
    end
  end

  defp revisioned_subject_ref(changeset, revision) do
    "samen:#{Samen.Info.abbrev(changeset.resource)}:#{changeset.data.id}:#{revision}"
  end

  defp entry_digest(changeset) do
    entry = Ash.load!(changeset.data, [:lines], authorize?: false)

    payload = [
      entry_date: entry.entry_date && Date.to_iso8601(entry.entry_date),
      memo: entry.memo,
      lines: entry.lines |> Enum.map(&line_payload/1) |> Enum.sort_by(&elem(&1, 0))
    ]

    :crypto.hash(:sha256, :erlang.term_to_binary(payload))
    |> Base.encode16(case: :lower)
  end

  defp line_payload(line) do
    {
      line.id,
      line.account_id,
      line.debit_cents,
      line.credit_cents,
      line.memo,
      line.dimension_refs
    }
  end

  defp load_lines(changeset), do: Ash.load!(changeset.data, [:lines], authorize?: false).lines

  defp account_scope?(policy, lines) do
    case Map.get(policy, :account_ids) do
      ids when is_list(ids) and ids != [] ->
        Enum.any?(lines, fn line -> line.account_id in ids end)

      _ ->
        true
    end
  end

  defp period_scope?(policy, changeset) do
    case Map.get(policy, :period_keys) do
      keys when is_list(keys) and keys != [] ->
        case loaded_attribute(changeset, :entry_date) do
          %Date{} = date -> (date |> Date.to_iso8601() |> String.slice(0, 7)) in keys
          _ -> false
        end

      _ ->
        true
    end
  end

  defp total_cents(lines) do
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
