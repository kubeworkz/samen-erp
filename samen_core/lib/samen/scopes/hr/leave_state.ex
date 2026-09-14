defmodule Samen.Scopes.Hr.LeaveState do
  @moduledoc """
  The `LeaveRequest` state machine (WS-ERP E7; design §5):
  `pending → approved | rejected | cancelled`; every terminal state refuses
  (an approved/rejected/cancelled request is a decided fact — the ADR-040
  lifecycle: terminal states refuse re-transition, exactly-once decisions).

  Runs on `:approve`/`:reject`/`:cancel` (all `accept([])` — the Gate's
  bounded-transition contract). The `:approve` path's caller-supplied data is
  the pre-approval record; the Gate's re-invocation happens as the requester
  inside the decision transaction, so the pre-state read here is the SAME row
  the Gate vetted.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, &refuse_bad_transition/1)
  end

  defp refuse_bad_transition(changeset) do
    case changeset.action.name do
      :approve ->
        refuse_unless_pending(changeset)

      :reject ->
        refuse_unless_pending(changeset)

      :cancel ->
        refuse_unless_pending(changeset)
    end
  end

  defp refuse_unless_pending(changeset) do
    case changeset.data.status do
      :pending ->
        changeset
        |> Ash.Changeset.force_change_attribute(:status, decision_status(changeset.action.name))
        |> Ash.Changeset.force_change_attribute(
          :decided_at,
          DateTime.utc_now() |> DateTime.truncate(:second)
        )

      other ->
        Ash.Changeset.add_error(changeset,
          field: :status,
          message:
            "a leave request that is already #{other} cannot be #{changeset.action.name}d — " <>
              "a decision is a fact, exactly once"
        )
    end
  end

  defp decision_status(:approve), do: :approved
  defp decision_status(:reject), do: :rejected
  defp decision_status(:cancel), do: :cancelled
  defp decision_status(_), do: nil
end
