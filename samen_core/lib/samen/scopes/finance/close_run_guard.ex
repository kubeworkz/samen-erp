defmodule Samen.Scopes.Finance.CloseRunGuard do
  @moduledoc """
  The `CloseRun` checklist lifecycle (WS-ACCT Phase 3; ADR-054 D7):

    * `op: :seed` — on `:start`, copies `Samen.Scopes.Finance.ClosePhases.seeded/0`
      onto the row and stamps `started_at`. The phases are never caller input:
      the doc's ten are the checklist, and a caller inventing an eleventh would
      be editing the close policy through a create argument.
    * `op: :complete_phase` — the `:complete_phase` action's `phase` argument
      (a key from `ClosePhases.keys/0`) gets `done_at`. An UNKNOWN key is
      refused fail-honest rather than appended (a typo must not silently create
      a phase nobody checks); re-completing an already-done phase is a no-op, so
      a retried click is not an error.
    * `op: :finish` — `:in_progress → :completed`, one-way (the
      `PeriodTransition` posture), and only when EVERY phase is done. A run
      marked complete with a phase outstanding would be a close certificate that
      certifies nothing.

  ## Work anchoring (WS-ACCT Phase 12)

  When the host wires its Work scope (`work: [task: MyApp.Work.Task]`), the
  same guard makes the checklist CHECKABLE:

    * `:seed` creates the ten anchored Work tasks in the SAME transaction as
      the run (`Samen.Scopes.Finance.CloseChecklist`) — a run whose checklist
      could not be created is not a started close;
    * `:complete_phase` refuses while that phase's task is still open, so the
      governed sign-off and the operational fact cannot disagree. The dashboard
      (`CloseBoard`) still re-derives the status from both, which is what makes
      an out-of-band task reopen visible rather than silently "done".

  Without `work_task`, both operations behave exactly as Phase 3 shipped them.

  A completed run is final: `:complete_phase` and `:finish` both refuse on it, so
  the checklist cannot be rewritten after the close it describes was signed.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, opts, _context) do
    op = Keyword.fetch!(opts, :op)
    work_task = Keyword.get(opts, :work_task)

    changeset
    |> Ash.Changeset.before_action(&apply_op(&1, op, work_task))
    |> seed_tasks_after(op, work_task)
  end

  # Phase 12: the ten phases become Work tasks anchored to the run, in this
  # action's transaction. `CloseChecklist.seed/2` is idempotent, so a retried
  # start that somehow got past the unique period index converges rather than
  # duplicating the board.
  defp seed_tasks_after(changeset, :seed, task_mod) when not is_nil(task_mod) do
    Ash.Changeset.after_action(changeset, fn changeset, run ->
      case Samen.Scopes.Finance.CloseChecklist.seed(run, task: task_mod) do
        {:ok, _tasks} ->
          {:ok, run}

        {:error, reason} ->
          {:error,
           Ash.Changeset.add_error(changeset,
             field: :base,
             message:
               "the close run was started but its Work checklist could not be created: " <>
                 inspect(reason)
           )}
      end
    end)
  end

  defp seed_tasks_after(changeset, _op, _task_mod), do: changeset

  defp apply_op(changeset, :seed, _work_task) do
    changeset
    |> Ash.Changeset.force_change_attribute(:phases, Samen.Scopes.Finance.ClosePhases.seeded())
    |> Ash.Changeset.force_change_attribute(:started_at, now())
  end

  defp apply_op(changeset, :complete_phase, work_task) do
    key = Ash.Changeset.get_argument(changeset, :phase)
    phases = phases(changeset)
    open_task = open_task(work_task, changeset.data, key)

    cond do
      current_status(changeset) == :completed ->
        error(changeset, "this close run is COMPLETED — its checklist is a signed fact and " <>
          "cannot be edited. Start the next period's run instead.")

      Samen.Scopes.Finance.ClosePhases.fetch(key) == nil ->
        error(changeset, "unknown close phase #{inspect(key)} — the checklist is the source " <>
          "manual's ten phases (see Samen.Scopes.Finance.ClosePhases.keys/0)")

      open_task != nil ->
        error(
          changeset,
          "the Work task for close phase #{inspect(key)} is still #{open_task.status} — " <>
            "complete the task before signing the phase off. The close dashboard reads the " <>
            "task and would keep reporting the phase open, so a sign-off now would be a " <>
            "checklist that disagrees with itself."
        )

      true ->
        Ash.Changeset.force_change_attribute(changeset, :phases, mark_done(phases, key))
    end
  end

  defp apply_op(changeset, :finish, _work_task) do
    phases = phases(changeset)

    cond do
      current_status(changeset) == :completed ->
        error(changeset, "illegal close-run transition: the run is already COMPLETED " <>
          "(the run is one-way — in_progress → completed)")

      pending(phases) != [] ->
        error(changeset, "the close run cannot be completed while #{length(pending(phases))} " <>
          "phase(s) are still open: #{Enum.join(pending(phases), ", ")}. Complete every phase " <>
          "or leave the run in progress — a close certificate with phases outstanding would " <>
          "certify nothing.")

      true ->
        changeset
        |> Ash.Changeset.force_change_attribute(:status, :completed)
        |> Ash.Changeset.force_change_attribute(:completed_at, now())
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  # The anchored task, when the host wired Work. `nil` means "no obligation" —
  # either the mount has no Work scope, or this run's tasks were never created.
  # A task that exists and is not completed is the operational fact that
  # refuses the sign-off.
  defp open_task(nil, _run, _key), do: nil

  defp open_task(task_mod, run, key) do
    case Samen.Scopes.Finance.CloseChecklist.task_for(run, key, task: task_mod) do
      %{status: :completed} -> nil
      %{status: _} = task -> task
      nil -> nil
    end
  end

  defp mark_done(phases, key) do
    Enum.map(phases, fn phase ->
      if get(phase, "key") == key and get(phase, "done_at") == nil do
        put(phase, "done_at", DateTime.to_iso8601(now()))
      else
        phase
      end
    end)
  end

  defp pending(phases) do
    phases
    |> Enum.filter(&(get(&1, "done_at") == nil))
    |> Enum.map(&get(&1, "key"))
  end

  defp phases(changeset) do
    case Ash.Changeset.get_attribute(changeset, :phases) do
      list when is_list(list) -> list
      _ -> Map.get(changeset.data, :phases) || []
    end
  end

  defp current_status(changeset) do
    case Ash.Changeset.get_attribute(changeset, :status) do
      %Ash.NotLoaded{} -> Map.get(changeset.data, :status)
      nil -> Map.get(changeset.data, :status)
      status -> status
    end
  end

  # The stored maps come back from jsonb with STRING keys; the seeded ones are
  # string-keyed too, so one accessor covers both.
  defp get(phase, key) when is_map(phase) do
    Map.get(phase, key) || Map.get(phase, safe_atom(key))
  end

  defp get(_phase, _key), do: nil

  defp put(phase, key, value) when is_map(phase) do
    phase
    |> Map.put(key, value)
    |> Map.drop([safe_atom(key)])
  end

  defp safe_atom("key"), do: :key
  defp safe_atom("done_at"), do: :done_at
  defp safe_atom(_), do: :__never__

  defp error(changeset, message) do
    Ash.Changeset.add_error(changeset, field: :base, message: message)
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
