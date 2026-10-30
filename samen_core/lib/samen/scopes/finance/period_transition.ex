defmodule Samen.Scopes.Finance.PeriodTransition do
  @moduledoc """
  The **one-way period state machine** (WS-ACCT Phase 3; ADR-054 D7).

  `:open → :soft_closed → :closed`, and open may jump straight to `:closed`.
  There is no edge backwards and none sideways: a period that has been closed
  cannot be reopened, and a soft-closed period cannot be un-soft-closed.

  ## Why one-way is the whole point

  A close is a *publication*. Once a period's figures have gone into a board
  package or a grant claim, an entry dated inside it has to be impossible —
  reopening the period would make the published figure quietly wrong. So the
  only route to a closed period is forward, and the only way to correct a
  closed period's numbers is a journal entry in the period that is still open
  (`Samen.Scopes.Finance.PeriodGuard`'s message says exactly that).

  The refusal is enforced in `before_action` — inside the action's transaction,
  against the PERSISTED status, so a caller holding a stale record cannot close
  twice or slip a reopen through. `PostGuard`'s one-way `:draft → :posted`
  transition is the precedent; this is the same shape with three states.

  ## The stamp

  `:closed` stamps `closed_at` and `closed_by` (the acting principal's id, when
  the changeset carries one) as SYSTEM attribute writes — never caller input, so
  the audit facts cannot be forged by the caller that performs the close.
  """

  use Ash.Resource.Change

  @transitions %{
    open: [:soft_closed, :closed],
    soft_closed: [:closed],
    closed: []
  }

  @doc "The legal target states from `from`. Empty means the period is final."
  def allowed_from(from), do: Map.get(@transitions, from, [])

  @impl true
  def change(changeset, opts, context) do
    target = Keyword.fetch!(opts, :to)
    Ash.Changeset.before_action(changeset, &transition(&1, target, context))
  end

  defp transition(changeset, target, context) do
    current = persisted_status(changeset)

    if target in allowed_from(current) do
      changeset = Ash.Changeset.force_change_attribute(changeset, :status, target)

      if target == :closed do
        changeset
        |> Ash.Changeset.force_change_attribute(:closed_at, now())
        |> Ash.Changeset.force_change_attribute(:closed_by, actor_id(context))
      else
        changeset
      end
    else
      Ash.Changeset.add_error(changeset,
        field: :status,
        message:
          "illegal close transition: the period is #{current} and may not become #{target} " <>
            "(the period state machine is one-way: open → soft_closed → closed). " <>
            "A closed period is final — to correct its figures, post a journal entry in an " <>
            "open period."
      )
    end
  end

  # The PERSISTED status, never a pending change: the point of the guard is that
  # the row on disk decides, so two concurrent closes cannot both be "first".
  defp persisted_status(changeset) do
    case changeset.data.status do
      %Ash.NotLoaded{} -> Ash.Changeset.get_attribute(changeset, :status) || :open
      nil -> :open
      status -> status
    end
  end

  defp actor_id(%{actor: %{id: id}}) when is_binary(id) do
    # Principals are string-keyed in the tenant plane (`u:<uuid>`); the column
    # is a uuid, so only a real uuid is stamped.
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end

  defp actor_id(_context), do: nil

  # Not truncated here: `closed_at` is an `:utc_datetime` (second precision, the
  # same as the entries' `posted_at`), so the type already fixes the granularity
  # and a second truncate would only restate it.
  defp now, do: DateTime.utc_now()
end
