defmodule Samen.Scopes.Finance.CloseBoard do
  @moduledoc """
  The **close dashboard read** (WS-ACCT Phase 12; ADR-054 D7): the source
  manual's *Monthly Close Dashboard*, computed from the facts rather than
  transcribed.

  ## Honesty is the feature

  The manual's dashboard has a Status column and a Blockers column. A status
  that is typed by a human is a claim; this read DERIVES it from four
  independent facts:

    * the phase's anchored Work task is `:completed` — the operational fact
      (`Samen.Scopes.Finance.CloseChecklist`),
    * at least one evidence file id is recorded on the phase,
    * the phase carries a reviewer sign-off by a principal other than its
      signer (`CloseRun.:review_phase`), and
    * the phase has `done_at` — the governed sign-off
      (`CloseRun.:complete_phase`).

  A phase is `:done` **only when all four agree**. An open (or reopened) task
  keeps the phase `:open` even if the phase was signed; a signed phase with no
  evidence or reviewer is surfaced as a discrepancy rather than rounded away —
  a dashboard that reported a phase done because one of its facts was missing
  would be the exact "certificate that certifies nothing" ADR-054 D7 refuses.

  ## Legacy signed phases

  A phase signed before this gate existed has no `evidence_files` /
  `reviewed_by` keys. It remains `:done` when its task agrees: a historical
  close is a signed fact, and inventing evidence or a reviewer for it would be
  dishonest. New phase maps always carry the keys, so the legacy path cannot be
  used to sign a new phase without evidence and independent review.

  ## What the report carries

    * `:period` — the fiscal month (id/year/month/status) when the caller passes
      it, `nil` otherwise (honest absence, not a guessed month);
    * `:started_by` — the principal that started the run, `nil` for a run started
      before its host recorded attribution (honest absence, never a guessed name);
    * `:completed_by` — the principal that finished the run, `nil` while it is in
      progress and for a run completed before its host recorded attribution;
    * `:phases` — the checklist in calendar order, each with its role
      assignment, evidence file ids, reviewer stamp, sign-off stamp and signer,
      task projection and derived status;
    * `:completeness` — total/done/open, the percentage and the boolean
      `complete?` (the run is `:completed` AND every phase is done);
    * `:next_phase` — the first open phase, the manual's "what is blocking";
    * `:tasks` — total/completed/open plus `missing` (phases with no anchored
      task — the honest measure of an unanchored checklist);
    * `:discrepancies` — signed phases that disagree with their task, evidence,
      reviewer or signer.

  ## No task module, no invented task state

  A caller that reads a run without the Work scope (`task:` absent) gets
  `task: nil` on every phase. That is deliberate — the read must not claim a
  task exists — but the evidence, reviewer and sign-off facts still decide the
  status, and a mount that never wired Work still has a valid dashboard.
  Historical signed phases without the new keys remain the legacy exception.
  """

  alias Samen.Scopes.Finance.{CloseChecklist, ClosePhases}

  @type phase_status :: :done | :open

  @doc """
  The period's close dashboard.

  `opts`:

    * `:task` — the host's mounted Work Task module. When absent, tasks are not
      read (`task: nil`, `tasks.total: 0`).
    * `:period` — the `FiscalPeriod` row, for the month/status header.
  """
  @spec report(struct(), keyword()) :: map()
  def report(run, opts \\ []) do
    task_mod = Keyword.get(opts, :task)
    period = Keyword.get(opts, :period)

    tasks =
      if is_nil(task_mod) do
        %{}
      else
        CloseChecklist.tasks_by_phase(run, task: task_mod)
      end

    phases = run |> phase_list() |> Enum.map(&phase_view(&1, tasks))
    total = length(phases)
    done = Enum.count(phases, &(&1.status == :done))

    %{
      run_id: run.id,
      run_status: run.status,
      started_at: run.started_at,
      started_by: Map.get(run, :started_by),
      completed_at: run.completed_at,
      completed_by: Map.get(run, :completed_by),
      period: period_view(period),
      phases: phases,
      completeness: %{
        total: total,
        done: done,
        open: total - done,
        percent: percent(done, total),
        complete?: run.status == :completed and done == total and total > 0
      },
      next_phase: Enum.find(phases, &(&1.status == :open)),
      tasks: task_totals(tasks, task_mod),
      discrepancies: discrepancies(phases)
    }
  end

  # ── phases ─────────────────────────────────────────────────────────────────

  defp phase_list(run) do
    case Map.get(run, :phases) do
      list when is_list(list) -> Enum.filter(list, &is_map/1)
      _ -> []
    end
  end

  defp phase_view(phase, tasks) do
    key = get(phase, "key")
    task = Map.get(tasks, key)
    signed? = get(phase, "done_at") != nil
    task_done? = is_nil(task) or task.status == :completed
    evidence_files = get(phase, "evidence_files")
    evidence_files = if is_list(evidence_files), do: evidence_files, else: []
    reviewed_by = get(phase, "reviewed_by")
    reviewed_at = get(phase, "reviewed_at")
    evidence_present? = evidence_files != []
    reviewed? = is_binary(reviewed_by) and reviewed_at != nil
    independent_review? = reviewed? and reviewed_by != get(phase, "done_by")

    legacy? =
      signed? and not Map.has_key?(phase, "evidence_files") and
        not Map.has_key?(phase, "reviewed_by")

    gate_satisfied? =
      signed? and task_done? and
        (legacy? or (evidence_present? and reviewed? and independent_review?))

    %{
      key: key,
      label: get(phase, "label"),
      days: get(phase, "days"),
      focus: get(phase, "focus"),
      output: get(phase, "output"),
      role: get(phase, "role") || ClosePhases.role_of(key),
      roles: get(phase, "roles") || ClosePhases.roles_for(key),
      signed?: signed?,
      done_at: get(phase, "done_at"),
      done_by: get(phase, "done_by"),
      evidence_files: evidence_files,
      evidence_present?: evidence_present?,
      reviewed_by: reviewed_by,
      reviewed_at: reviewed_at,
      reviewed?: reviewed?,
      independent_review?: independent_review?,
      legacy?: legacy?,
      task: task_view(task),
      task_done?: task_done?,
      status: if(gate_satisfied?, do: :done, else: :open)
    }
  end

  defp task_view(nil), do: nil

  defp task_view(task) do
    %{
      id: task.id,
      title: task.title,
      status: task.status,
      completed_at: task.completed_at
    }
  end

  # ── aggregates ─────────────────────────────────────────────────────────────

  defp task_totals(_tasks, nil), do: %{total: 0, completed: 0, open: 0, missing: 0}

  defp task_totals(tasks, _task_mod) do
    values = Map.values(tasks)
    total = length(values)
    completed = Enum.count(values, &(&1.status == :completed))

    %{
      total: total,
      completed: completed,
      open: total - completed,
      missing: max(length(ClosePhases.keys()) - total, 0)
    }
  end

  defp discrepancies(phases) do
    Enum.flat_map(phases, fn phase ->
      cond do
        phase.signed? and not phase.task_done? ->
          [
            %{
              phase: phase.key,
              reason: "the phase is signed off but its Work task is still open"
            }
          ]

        phase.signed? and not phase.legacy? and not phase.evidence_present? ->
          [
            %{
              phase: phase.key,
              reason: "the phase is signed off but has no evidence files"
            }
          ]

        phase.signed? and not phase.legacy? and not phase.reviewed? ->
          [
            %{
              phase: phase.key,
              reason: "the phase is signed off without an independent reviewer"
            }
          ]

        phase.signed? and phase.reviewed? and not phase.independent_review? ->
          [
            %{
              phase: phase.key,
              reason: "the phase reviewer is also its signer"
            }
          ]

        true ->
          []
      end
    end)
  end

  defp percent(_done, 0), do: 0
  defp percent(done, total), do: round(done * 100 / total)

  defp period_view(nil), do: nil

  defp period_view(period) do
    %{
      id: Map.get(period, :id),
      year: Map.get(period, :year),
      month: Map.get(period, :month),
      status: Map.get(period, :status)
    }
  end

  # jsonb phases come back string-keyed; a caller-built map may be atom-keyed.
  defp get(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, safe_atom(key))
  end

  defp get(_map, _key), do: nil

  defp safe_atom("key"), do: :key
  defp safe_atom("label"), do: :label
  defp safe_atom("days"), do: :days
  defp safe_atom("focus"), do: :focus
  defp safe_atom("output"), do: :output
  defp safe_atom("role"), do: :role
  defp safe_atom("roles"), do: :roles
  defp safe_atom("done_at"), do: :done_at
  defp safe_atom("done_by"), do: :done_by
  defp safe_atom("evidence_files"), do: :evidence_files
  defp safe_atom("reviewed_by"), do: :reviewed_by
  defp safe_atom("reviewed_at"), do: :reviewed_at
  defp safe_atom(_), do: :__never__
end
