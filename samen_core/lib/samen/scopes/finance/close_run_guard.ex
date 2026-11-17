defmodule Samen.Scopes.Finance.CloseRunGuard do
  @moduledoc """
  The `CloseRun` checklist lifecycle (WS-ACCT Phase 3; ADR-054 D7):

    * `op: :seed` — on `:start`, copies `Samen.Scopes.Finance.ClosePhases.seeded/0`
      onto the row and stamps `started_at` and `started_by`, the acting
      principal's id when the caller supplies one. The phases are never caller input:
      the doc's ten are the checklist, and a caller inventing an eleventh would
      be editing the close policy through a create argument.
    * `op: :review_phase` — the `:review_phase` action's `phase` argument
      records the reviewer (the acting principal) and the Docs file ids the
      reviewer accepted as evidence. An unknown, already-signed or task-open
      phase is refused; an empty evidence list is refused, because a review
      with nothing to review is not evidence.
    * `op: :complete_phase` — the `:complete_phase` action's `phase` argument
      (a key from `ClosePhases.keys/0`) gets `done_at` and `done_by`, the
      acting principal's id when the caller supplies one. It refuses unless the
      phase has evidence and a reviewer OTHER than the signer. An UNKNOWN key is
      refused fail-honest rather than appended (a typo must not silently create
      a phase nobody checks); re-completing an already-done phase is a no-op, so
      a retried click is not an error.
    * `op: :finish` — `:in_progress → :completed`, one-way (the
      `PeriodTransition` posture), and only when EVERY phase is done. A run
      marked complete with a phase outstanding would be a close certificate that
      certifies nothing. It also refuses while an imported payroll register for
      the run's fiscal month is neither posted, voided, nor held with a named
      exception (`PayrollCloseCheck`), so payroll cannot be omitted from a
      signed close. It stamps `completed_at` and `completed_by`, the acting
      principal's id when the caller supplies one.

  ## Work anchoring (WS-ACCT Phase 12)

  When the host wires its Work scope (`work: [task: MyApp.Work.Task]`), the
  same guard makes the checklist CHECKABLE:

    * `:seed` creates the ten anchored Work tasks in the SAME transaction as
      the run (`Samen.Scopes.Finance.CloseChecklist`) — a run whose checklist
      could not be created is not a started close;
    * `:review_phase` and `:complete_phase` refuse while that phase's task is
      still open, so the governed sign-off and the operational fact cannot
      disagree. `:complete_phase` also requires the evidence list recorded by
      `:review_phase` and a reviewer whose id differs from the signer's. The
      dashboard (`CloseBoard`) still re-derives the status from every fact,
      which is what makes an out-of-band task reopen visible rather than
      silently "done".

  Without `work_task`, the task precondition is skipped; the evidence, reviewer
  and signer checks still apply.

  A completed run is final: `:complete_phase` and `:finish` both refuse on it, so
  the checklist cannot be rewritten after the close it describes was signed.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, opts, context) do
    op = Keyword.fetch!(opts, :op)
    work_task = Keyword.get(opts, :work_task)
    payroll = Keyword.get(opts, :payroll, [])

    # Captured at change-REGISTRATION time, the same posture as
    # `Samen.Pii.WriteGuard`: a nested action can rebuild the changeset's private
    # context by the time `before_action` runs, but the registration-time
    # changeset still carries the caller's actor. A caller with no actor records
    # no starter; review and sign-off refuse because no identity can be named.
    actor =
      actor_id(Map.get(context, :actor)) ||
        actor_id(get_in(changeset.context, [:private, :actor]))

    changeset
    |> Ash.Changeset.before_action(&apply_op(&1, op, work_task, actor, payroll))
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

  defp apply_op(changeset, :seed, _work_task, actor, _payroll) do
    changeset
    |> Ash.Changeset.force_change_attribute(:phases, Samen.Scopes.Finance.ClosePhases.seeded())
    |> Ash.Changeset.force_change_attribute(:started_at, now())
    |> Ash.Changeset.force_change_attribute(:started_by, actor)
  end

  defp apply_op(changeset, :review_phase, work_task, actor, _payroll) do
    key = Ash.Changeset.get_argument(changeset, :phase)
    evidence_files = Ash.Changeset.get_argument(changeset, :evidence_files) || []
    phases = phases(changeset)
    phase = phase_for(phases, key)
    open_task = open_task(work_task, changeset.data, key)

    cond do
      current_status(changeset) == :completed ->
        error(
          changeset,
          "this close run is COMPLETED — its checklist is a signed fact and " <>
            "cannot be edited. Start the next period's run instead."
        )

      Samen.Scopes.Finance.ClosePhases.fetch(key) == nil ->
        error(
          changeset,
          "unknown close phase #{inspect(key)} — the checklist is the source " <>
            "manual's ten phases (see Samen.Scopes.Finance.ClosePhases.keys/0)"
        )

      phase == nil ->
        error(changeset, "close phase #{inspect(key)} is not present in this run's checklist")

      get(phase, "done_at") != nil ->
        error(changeset, "close phase #{inspect(key)} is already signed; its review is final")

      is_nil(actor) ->
        error(changeset, "a reviewer identity is required to sign a close phase review")

      open_task != nil ->
        error(
          changeset,
          "the Work task for close phase #{inspect(key)} is still #{open_task.status} — " <>
            "complete the task before reviewing the phase. The close dashboard reads the " <>
            "task and would keep reporting the phase open."
        )

      not evidence_present?(evidence_files) ->
        error(
          changeset,
          "close phase #{inspect(key)} needs at least one evidence file id before a reviewer " <>
            "can sign it off"
        )

      true ->
        Ash.Changeset.force_change_attribute(
          changeset,
          :phases,
          mark_reviewed(phases, key, evidence_files, actor)
        )
    end
  end

  defp apply_op(changeset, :complete_phase, work_task, actor, _payroll) do
    key = Ash.Changeset.get_argument(changeset, :phase)
    phases = phases(changeset)
    phase = phase_for(phases, key)
    open_task = open_task(work_task, changeset.data, key)
    evidence_files = if phase, do: get(phase, "evidence_files") || [], else: []
    reviewed_by = if phase, do: get(phase, "reviewed_by")
    reviewed_at = if phase, do: get(phase, "reviewed_at")

    cond do
      current_status(changeset) == :completed ->
        error(
          changeset,
          "this close run is COMPLETED — its checklist is a signed fact and " <>
            "cannot be edited. Start the next period's run instead."
        )

      Samen.Scopes.Finance.ClosePhases.fetch(key) == nil ->
        error(
          changeset,
          "unknown close phase #{inspect(key)} — the checklist is the source " <>
            "manual's ten phases (see Samen.Scopes.Finance.ClosePhases.keys/0)"
        )

      phase == nil ->
        error(changeset, "close phase #{inspect(key)} is not present in this run's checklist")

      get(phase, "done_at") != nil ->
        changeset

      is_nil(actor) ->
        error(changeset, "a signer identity is required to sign a close phase off")

      open_task != nil ->
        error(
          changeset,
          "the Work task for close phase #{inspect(key)} is still #{open_task.status} — " <>
            "complete the task before signing the phase off. The close dashboard reads the " <>
            "task and would keep reporting the phase open, so a sign-off now would be a " <>
            "checklist that disagrees with itself."
        )

      not evidence_present?(evidence_files) ->
        error(
          changeset,
          "close phase #{inspect(key)} has no evidence files — record the evidence and its " <>
            "reviewer before signing the phase off"
        )

      is_nil(reviewed_by) or is_nil(reviewed_at) ->
        error(
          changeset,
          "close phase #{inspect(key)} has no independent reviewer sign-off — review the " <>
            "evidence before signing the phase off"
        )

      reviewed_by == actor ->
        error(
          changeset,
          "the reviewer of close phase #{inspect(key)} cannot also sign it off — an " <>
            "independent reviewer is required"
        )

      true ->
        Ash.Changeset.force_change_attribute(changeset, :phases, mark_done(phases, key, actor))
    end
  end

  defp apply_op(changeset, :finish, _work_task, actor, payroll) do
    phases = phases(changeset)

    cond do
      current_status(changeset) == :completed ->
        error(
          changeset,
          "illegal close-run transition: the run is already COMPLETED " <>
            "(the run is one-way — in_progress → completed)"
        )

      pending(phases) != [] ->
        error(
          changeset,
          "the close run cannot be completed while #{length(pending(phases))} " <>
            "phase(s) are still open: #{Enum.join(pending(phases), ", ")}. Complete every phase " <>
            "or leave the run in progress — a close certificate with phases outstanding would " <>
            "certify nothing."
        )

      true ->
        case payroll_block(changeset, payroll) do
          :ok ->
            changeset
            |> Ash.Changeset.force_change_attribute(:status, :completed)
            |> Ash.Changeset.force_change_attribute(:completed_at, now())
            |> Ash.Changeset.force_change_attribute(:completed_by, actor)

          {:error, message} ->
            error(changeset, message)
        end
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  # The payroll precondition is deliberately checked only after every phase is
  # done, so an early finish keeps its existing "phases open" refusal and the
  # payroll read is paid only on the transition that could actually complete.
  defp payroll_block(_changeset, payroll) when payroll in [nil, []], do: :ok

  defp payroll_block(changeset, payroll) do
    import_module = Keyword.get(payroll, :import)
    period_module = Keyword.get(payroll, :period)
    run = changeset.data

    cond do
      is_nil(import_module) ->
        :ok

      is_nil(period_module) ->
        {:error,
         "the payroll close check is not wired with its fiscal period; refusing to close " <>
           "rather than certifying payroll unseen"}

      true ->
        case org_id(run) do
          nil ->
            {:error,
             "the payroll close check could not resolve this run's org; refusing to close " <>
               "rather than certifying payroll unseen"}

          org_id ->
            case Ash.get(period_module, run.period_id, authorize?: false) do
              {:ok, period} ->
                payroll_result(payroll, import_module, org_id, period)

              _ ->
                {:error,
                 "the payroll close check could not load this run's fiscal period; refusing " <>
                   "to close rather than certifying payroll unseen"}
            end
        end
    end
  end

  defp payroll_result(payroll, import_module, org_id, period) do
    opts =
      case Keyword.get(payroll, :labour_allocation) do
        allocation_module when is_atom(allocation_module) and not is_nil(allocation_module) ->
          [import_module: import_module, labour_allocation_module: allocation_module]

        _ ->
          [import_module: import_module]
      end

    case Samen.Scopes.Finance.PayrollCloseCheck.report(org_id, period, opts) do
      %{clear?: true} ->
        :ok

      %{truncated?: true} ->
        {:error,
         "the payroll close check found more than 500 imported payroll entries for this " <>
           "period; refusing to close until the payroll inbox can be read within the bound"}

      %{labour_tie_out: %{status: :drift} = tie_out} ->
        {:error, labour_message(tie_out)}

      %{labour_tie_out: %{status: :unavailable}} ->
        {:error,
         "the labour allocation tie-out could not be read for this period; refusing to " <>
           "close rather than certifying payroll unseen"}

      %{status: :unavailable} ->
        {:error,
         "the payroll close check could not be read for this period; refusing to close " <>
           "rather than certifying payroll unseen"}

      %{unresolved: unresolved} ->
        {:error, payroll_message(unresolved)}
    end
  end

  defp payroll_message(unresolved) do
    count = length(unresolved)
    noun = if count == 1, do: "entry is", else: "entries are"

    sample =
      unresolved
      |> Enum.take(5)
      |> Enum.map_join(", ", fn entry ->
        "#{entry.provider}/#{entry.external_id} (#{disposition_label(entry.disposition)})"
      end)

    more = if count > 5, do: " and #{count - 5} more", else: ""

    "the close run cannot be completed while #{count} imported payroll #{noun} " <>
      "unresolved: #{sample}#{more}. Post or void the linked journal entry, or record a " <>
      "named hold exception on the import."
  end

  defp labour_message(tie_out) do
    rows = tie_out.drift
    count = length(rows)
    noun = if count == 1, do: "allocation header is", else: "allocation headers are"

    sample =
      rows
      |> Enum.take(5)
      |> Enum.map_join(", ", fn row ->
        account = row.source_account_code || row.source_account_id

        "#{account} declares #{row.allocated_cents} cents but the posted register " <>
          "debits #{row.register_debit_cents} (variance #{row.variance_cents})"
      end)

    more = if count > 5, do: " and #{count - 5} more", else: ""

    "the close run cannot be completed while #{count} labour #{noun} out of tie " <>
      "with the payroll register: #{sample}#{more}. Correct the register or the " <>
      "allocation before signing the close."
  end

  defp disposition_label(:draft), do: "unposted draft"
  defp disposition_label(:conflict), do: "unresolved conflict"
  defp disposition_label(:missing), do: "missing journal entry"
  defp disposition_label(:unknown), do: "unknown journal state"
  defp disposition_label(other), do: to_string(other)

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

  defp mark_done(phases, key, actor) do
    Enum.map(phases, fn phase ->
      if get(phase, "key") == key and get(phase, "done_at") == nil do
        phase
        |> put("done_at", DateTime.to_iso8601(now()))
        |> put("done_by", actor)
      else
        phase
      end
    end)
  end

  defp mark_reviewed(phases, key, evidence_files, reviewer) do
    Enum.map(phases, fn phase ->
      if get(phase, "key") == key and get(phase, "done_at") == nil do
        phase
        |> put("evidence_files", evidence_files)
        |> put("reviewed_by", reviewer)
        |> put("reviewed_at", DateTime.to_iso8601(now()))
      else
        phase
      end
    end)
  end

  defp phase_for(phases, key), do: Enum.find(phases, &(get(&1, "key") == key))

  defp evidence_present?(files) when is_list(files), do: Enum.any?(files, &is_binary/1)
  defp evidence_present?(_files), do: false

  defp actor_id(%{id: id}) when is_binary(id), do: id
  defp actor_id(_), do: nil

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

  # `org_id` is often `%Ash.NotLoaded{}` on a run read without an explicit
  # select (the E4 lesson). A payroll check without a tenant would be unsafe,
  # so load it and let the caller refuse when it cannot be resolved.
  defp org_id(run) do
    case Map.get(run, :org_id) do
      id when is_binary(id) ->
        id

      _ ->
        case Ash.load(run, [:org_id], authorize?: false) do
          {:ok, %{org_id: id}} when is_binary(id) -> id
          _ -> nil
        end
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
  defp safe_atom("evidence_files"), do: :evidence_files
  defp safe_atom("reviewed_by"), do: :reviewed_by
  defp safe_atom("reviewed_at"), do: :reviewed_at
  defp safe_atom(_), do: :__never__

  defp error(changeset, message) do
    Ash.Changeset.add_error(changeset, field: :base, message: message)
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
