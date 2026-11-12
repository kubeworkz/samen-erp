defmodule Samen.Web.Finance.CloseDashboard do
  @moduledoc """
  The monthly close dashboard's read (WS-ACCT Phase 12; ADR-054 D7).

  `Samen.Scopes.Finance.CloseBoard` computes the honest board for ONE run.
  This module answers the surface's first question — WHICH run is the current
  one — and hands the page a single state map:

    * the newest `:in_progress` run; else
    * the newest non-closed `FiscalPeriod` with no run — so the month that is
      ready to be closed is the one the page offers to START; else
    * the newest run overall (a completed close stays visible when there is no
      next period yet); else
    * the newest declared period, so a fresh month renders its honest empty
      state naming the month that has no close.

  The period header comes from the SAME state map, so the page never guesses
  which month it is describing. Selection is a plain org-scoped read: the
  period and run resources are resolved from the host's mounted Finance
  namespace (`Samen.Web.Mount.resource/2`), never from caller input.

  The Work Task module is resolved from the `:work_namespace` mount label
  (`<namespace>.Task`), the same sibling-mount seam as `:personnel_namespace`
  in the grants report. Without it the board is the Phase-3 view (`task: nil`
  on every phase) and the page says Work is not wired rather than inventing
  task state.

  Evidence titles are resolved from the optional `:docs_namespace` mount label
  (`<namespace>.Doc`). The picker lists the org's live Docs pages by title, and
  every stored evidence UUID is resolved through that same org-scoped read; an
  archived page keeps its title but is flagged and linked to its Docs trash row
  for restore, and an id that resolves to neither a live nor an archived page
  is shown as unavailable and left unlinked, never as a fabricated name.
  Without the label the page keeps the manual
  Doc-ID input and the count, so a host that has not mounted Docs still has a
  working close gate.
  """

  require Ash.Query

  alias Samen.Scopes.Finance.CloseBoard
  alias Samen.Web.Mount
  alias Samen.Web.TenantRole

  @doc_limit 100

  @type doc :: %{id: term(), title: String.t()}

  @type state :: %{
          period: struct() | nil,
          run: struct() | nil,
          report: map() | nil,
          task_wired?: boolean(),
          docs: [doc()],
          docs_wired?: boolean(),
          evidence_titles: %{term() => String.t()},
          evidence_status: %{term() => :live | :archived | :missing}
        }

  @doc """
  Load the current close cycle for `mount` + `org_id`.

  Returns `{:ok, %{period:, run:, report:, task_wired?:, docs:, docs_wired?:,
  evidence_titles:}}` — `report` is `nil` when no run exists — or
  `{:error, :no_mount | :no_org | :finance_not_mounted}`.
  """
  @spec load(Mount.t() | nil, String.t() | nil) :: {:ok, state()} | {:error, atom()}
  def load(%Mount{} = mount, org_id) when is_binary(org_id) do
    with {:ok, period_mod} <- resource(mount, :FiscalPeriod),
         {:ok, run_mod} <- resource(mount, :CloseRun) do
      scope = Mount.scope(mount, org_id)
      task_mod = task_module(mount)
      {period, run} = current_cycle(run_mod, period_mod, scope)

      report = if run, do: CloseBoard.report(run, task: task_mod, period: period)
      evidence = evidence_context(mount, scope, report)

      {:ok,
       %{
         period: period,
         run: run,
         report: report,
         task_wired?: task_mod != nil,
         docs: evidence.docs,
         docs_wired?: evidence.wired?,
         evidence_titles: evidence.titles,
         evidence_status: evidence.statuses
       }}
    end
  end

  def load(%Mount{}, _org_id), do: {:error, :no_org}
  def load(nil, _org_id), do: {:error, :no_mount}

  # ── selection ─────────────────────────────────────────────────────────────

  defp current_cycle(run_mod, period_mod, scope) do
    runs = read_runs(run_mod, scope)
    periods = read_periods(period_mod, scope)

    in_progress = Enum.find(runs, &(&1.status == :in_progress))

    next_period =
      Enum.find(periods, fn period ->
        period.status != :closed and not run_for_period?(runs, period.id)
      end)

    latest_run = List.first(runs)
    latest_period = List.first(periods)

    cond do
      in_progress -> {in_progress.period, in_progress}
      next_period -> {next_period, nil}
      latest_run -> {latest_run.period, latest_run}
      true -> {latest_period, nil}
    end
  end

  defp read_runs(run_mod, scope) do
    run_mod
    |> Ash.Query.load(:period)
    |> Ash.read!(scope: scope)
    |> Enum.filter(&period_row?/1)
    |> Enum.sort_by(&{&1.period.year, &1.period.month}, :desc)
  end

  defp read_periods(period_mod, scope) do
    period_mod
    |> Ash.Query.sort(year: :desc, month: :desc)
    |> Ash.read!(scope: scope)
  end

  defp run_for_period?(runs, period_id),
    do: Enum.any?(runs, &(&1.period.id == period_id))

  defp period_row?(%{period: period}) when is_map(period),
    do: Map.has_key?(period, :year) and Map.has_key?(period, :month)

  defp period_row?(_run), do: false

  # ── Docs evidence ────────────────────────────────────────────────────────

  defp evidence_context(%Mount{} = mount, scope, report) do
    case docs_module(mount) do
      nil ->
        %{docs: [], titles: %{}, statuses: %{}, wired?: false}

      doc_mod ->
        evidence = read_evidence(doc_mod, scope, evidence_ids(report))

        %{
          docs: read_docs(doc_mod, scope),
          titles: evidence.titles,
          statuses: evidence.statuses,
          wired?: true
        }
    end
  end

  defp docs_module(%Mount{} = mount) do
    case Mount.label(mount, :docs_namespace, nil) do
      namespace when is_atom(namespace) and not is_nil(namespace) ->
        doc = Module.concat(namespace, :Doc)
        if Code.ensure_loaded?(doc), do: doc

      _ ->
        nil
    end
  end

  defp read_docs(doc_mod, scope) do
    doc_mod
    |> Ash.Query.ensure_selected([:id, :title])
    |> Ash.Query.sort(title: :asc)
    |> Ash.Query.limit(@doc_limit)
    |> Ash.read(scope: scope)
    |> case do
      {:ok, docs} -> Enum.map(docs, &%{id: &1.id, title: &1.title})
      _ -> []
    end
  rescue
    _ -> []
  end

  defp read_evidence(_doc_mod, _scope, []), do: %{titles: %{}, statuses: %{}}

  defp read_evidence(doc_mod, scope, ids) do
    live = read_docs_by_id(doc_mod, scope, ids, :read)
    live_ids = Map.keys(live)
    missing_ids = ids -- live_ids
    archived = read_docs_by_id(doc_mod, scope, missing_ids, :archived)

    statuses =
      Map.new(ids, fn id ->
        cond do
          Map.has_key?(live, id) -> {id, :live}
          Map.has_key?(archived, id) -> {id, :archived}
          true -> {id, :missing}
        end
      end)

    %{titles: Map.merge(archived, live), statuses: statuses}
  end

  # The live query and the archived query are separate on purpose: the default
  # read excludes archived rows, and `:archived` includes them. A row found by
  # neither is genuinely unavailable (deleted, purged, or a stale UUID).
  defp read_docs_by_id(_doc_mod, _scope, [], _action), do: %{}

  defp read_docs_by_id(doc_mod, scope, ids, action) do
    doc_mod
    |> Ash.Query.for_read(action)
    |> Ash.Query.ensure_selected([:id, :title])
    |> Ash.Query.filter(id in ^ids)
    |> Ash.Query.limit(length(ids))
    |> Ash.read(scope: scope)
    |> case do
      {:ok, docs} -> Map.new(docs, &{&1.id, &1.title})
      _ -> %{}
    end
  rescue
    _ -> %{}
  end

  defp evidence_ids(%{phases: phases}) do
    phases
    |> Enum.flat_map(& &1.evidence_files)
    |> Enum.uniq()
  end

  defp evidence_ids(_report), do: []

  # ── resources ─────────────────────────────────────────────────────────────

  defp task_module(%Mount{} = mount) do
    case Mount.label(mount, :work_namespace, nil) do
      namespace when is_atom(namespace) and not is_nil(namespace) ->
        task = Module.concat(namespace, :Task)
        if Code.ensure_loaded?(task), do: task

      _ ->
        nil
    end
  end

  defp resource(mount, name) do
    module = Mount.resource(mount, name)

    if Code.ensure_loaded?(module) do
      {:ok, module}
    else
      {:error, :finance_not_mounted}
    end
  end

  # ── governed commands ─────────────────────────────────────────────────────

  @doc """
  Start the close for `period_id` through the host's OWN governed `:start`
  action.

  The scope is `TenantRole.attributed_admin_scope/2`: the same tenant-plane ADMIN
  role as `admin_scope/2`, but with the actor's id replaced by the authenticated
  principal's `Identity.User` id when the host can resolve one. The kernel stamps
  that id as the run's `started_by`, so the period card can name the starter; a
  host with no resolvable principal records the workspace pseudo-principal
  instead (an honest "the workspace did this", never a fabricated person). The
  kernel's `OrgScope` + `RoleAtLeast :admin` decide — this module never writes
  with `authorize?: false`. When the host wired Work, the action seeds the ten
  anchored tasks in the same transaction.
  """
  @spec start_run(Mount.t(), String.t(), String.t()) :: {:ok, struct()} | {:error, term()}
  def start_run(%Mount{} = mount, org_id, period_id) when is_binary(org_id) do
    scope = TenantRole.attributed_admin_scope(mount, org_id)

    with {:ok, run_mod} <- resource(mount, :CloseRun) do
      run_mod
      |> Ash.Changeset.for_create(
        :start,
        %{org_id: org_id, period_id: period_id},
        scope: scope
      )
      |> Ash.create()
    end
  end

  @doc """
  Record evidence and an independent reviewer's sign-off through the host's OWN
  governed `:review_phase` action.

  The reviewer is the authenticated actor — never a caller-supplied name — and
  the evidence is a list of Docs file ids. The guard refuses an unknown,
  already-signed or task-open phase, and refuses an empty evidence list.

  The write scope is `TenantRole.attributed_admin_scope/2`, so a host that can
  resolve the principal stamps that id as `reviewed_by`; the workspace
  pseudo-principal is the honest fallback when it cannot.
  """
  @spec review_phase(Mount.t(), String.t(), String.t(), String.t(), [String.t()]) ::
          {:ok, struct()} | {:error, term()}
  def review_phase(%Mount{} = mount, org_id, run_id, phase_key, evidence_files)
      when is_binary(org_id) and is_binary(phase_key) and is_list(evidence_files) do
    scope = TenantRole.attributed_admin_scope(mount, org_id)

    with {:ok, run_mod} <- resource(mount, :CloseRun),
         {:ok, run} <- fetch_run(run_mod, run_id, scope) do
      run
      |> Ash.Changeset.for_update(
        :review_phase,
        %{phase: phase_key, evidence_files: evidence_files},
        scope: scope
      )
      |> Ash.update()
    end
  end

  @doc """
  Sign one phase off through the host's OWN governed `:complete_phase` action.

  The guard refuses an unknown phase, a completed run, a phase whose Work task
  is still open, a phase with no evidence, a phase with no reviewer, or a
  signer who is also the reviewer. The refusal is returned verbatim for the
  page's banner, never swallowed into a fake success.

  The write scope is `TenantRole.attributed_admin_scope/2`: the same admin role
  as `admin_scope/2`, but with the actor's id replaced by the authenticated
  principal's `Identity.User` id when the host can resolve one. The kernel
  stamps that id as the phase's `done_by`, so the row can name a signer; a host
  with no resolvable principal records the workspace pseudo-principal instead
  (an honest "the workspace did this", never a fabricated person).
  """
  @spec complete_phase(Mount.t(), String.t(), String.t(), String.t()) ::
          {:ok, struct()} | {:error, term()}
  def complete_phase(%Mount{} = mount, org_id, run_id, phase_key)
      when is_binary(org_id) and is_binary(phase_key) do
    scope = TenantRole.attributed_admin_scope(mount, org_id)

    with {:ok, run_mod} <- resource(mount, :CloseRun),
         {:ok, run} <- fetch_run(run_mod, run_id, scope) do
      run
      |> Ash.Changeset.for_update(:complete_phase, %{phase: phase_key}, scope: scope)
      |> Ash.update()
    end
  end

  @doc """
  Complete the close through the host's OWN governed `:finish` action.

  The kernel refuses while any phase is still open and refuses a run that is
  already completed; the page only offers the button once the board reports
  every phase done, but a crafted event still reaches the action and its refusal
  is surfaced.

  The scope is `TenantRole.attributed_admin_scope/2`, so the run's
  `completed_by` names the authenticated principal when the host can resolve
  one.
  """
  @spec finish_run(Mount.t(), String.t(), String.t()) :: {:ok, struct()} | {:error, term()}
  def finish_run(%Mount{} = mount, org_id, run_id) when is_binary(org_id) do
    scope = TenantRole.attributed_admin_scope(mount, org_id)

    with {:ok, run_mod} <- resource(mount, :CloseRun),
         {:ok, run} <- fetch_run(run_mod, run_id, scope) do
      run
      |> Ash.Changeset.for_update(:finish, %{}, scope: scope)
      |> Ash.update()
    end
  end

  defp fetch_run(run_mod, run_id, scope) do
    case Ash.get(run_mod, run_id, scope: scope) do
      {:ok, run} -> {:ok, run}
      {:error, _reason} -> {:error, :not_found}
    end
  end

  @doc "The first leaf message of an Ash error, whitespace-collapsed and bounded."
  @spec error_message(term()) :: String.t()
  def error_message(error) do
    error
    |> leaf_message()
    |> String.replace(~r/\s+/, " ")
    |> String.slice(0, 240)
  rescue
    _ -> "Could not apply that change."
  end

  defp leaf_message(%{errors: [first | _]}), do: leaf_message(first)
  defp leaf_message(%{message: message}) when is_binary(message), do: message
  defp leaf_message(message) when is_binary(message), do: message
  defp leaf_message(:not_found), do: "That close run is not in this workspace."
  defp leaf_message(reason) when is_atom(reason), do: "Could not apply that change (#{reason})."
  defp leaf_message(other), do: Exception.message(other)
end
