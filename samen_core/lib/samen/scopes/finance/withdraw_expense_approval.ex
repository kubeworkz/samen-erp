defmodule Samen.Scopes.Finance.WithdrawExpenseApproval do
  @moduledoc """
  Withdraws an expense report's pending `:approve` approval when the report is
  cancelled.

  Cancelling a submitted report makes the gated approval moot. Without this, the
  pending row outlives the decision it was opened for, the detail page keeps
  offering it, and a late approval can only fail the state machine. Runs as an
  `after_action` inside the cancellation's transaction.

  The withdrawal uses the requester's own `Samen.Approvals.cancel/3` path (the
  same path `Samen.AI.Agent` uses for a parked run), so `decided_by` stays NULL
  and the distinct-party invariant is untouched. The cancellation itself may be
  performed by a different member or an admin: the approval still belongs to the
  party recorded in `requested_by`, so that party is the one recorded as
  withdrawing it.
  """

  use Ash.Resource.Change

  alias Samen.Approvals
  alias Samen.Approvals.Gate

  @impl true
  def change(changeset, _opts, context) do
    org_id = actor_org_id(context) || loaded_org_id(changeset.data)

    Ash.Changeset.after_action(changeset, fn _changeset, report ->
      withdraw_pending(report, org_id)
      {:ok, report}
    end)
  end

  # The action result does not always load `org_id` (the detail page reads a
  # bounded field set), so take it from the acting scope — the same source the
  # Gate uses when it opens the approval.
  defp actor_org_id(%{actor: %{org_id: org_id}}), do: org_id
  defp actor_org_id(_context), do: nil

  defp loaded_org_id(%{org_id: org_id}) when is_binary(org_id), do: org_id
  defp loaded_org_id(_record), do: nil

  defp withdraw_pending(_report, nil), do: :ok

  defp withdraw_pending(report, org_id) do
    kind = Gate.kind_for(report.__struct__, :approve)
    subject_ref = "samen:#{Samen.Info.abbrev(report.__struct__)}:#{report.id}"

    case Approvals.list_pending(org_id, kind) do
      {:ok, approvals} ->
        approvals
        |> Enum.filter(&(&1.subject_ref == subject_ref))
        |> Enum.each(fn approval ->
          # The recorded requester withdraws; no handler runs, decided_by stays NULL.
          _ = Approvals.cancel(approval.id, approval.requested_by)
        end)

      # A host without approvals wiring cannot have opened one; the closing
      # transition must still work there.
      {:error, _reason} ->
        :ok
    end
  end
end
