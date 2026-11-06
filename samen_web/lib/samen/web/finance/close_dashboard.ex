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
  """

  alias Samen.Scopes.Finance.CloseBoard
  alias Samen.Web.Mount
  alias Samen.Web.TenantRole

  @type state :: %{
          period: struct() | nil,
          run: struct() | nil,
          report: map() | nil,
          task_wired?: boolean()
        }

  @doc """
  Load the current close cycle for `mount` + `org_id`.

  Returns `{:ok, %{period:, run:, report:, task_wired?:}}` — `report` is `nil`
  when no run exists — or `{:error, :no_mount | :no_org | :finance_not_mounted}`.
  """
  @spec load(Mount.t() | nil, String.t() | nil) :: {:ok, state()} | {:error, atom()}
  def load(%Mount{} = mount, org_id) when is_binary(org_id) do
    with {:ok, period_mod} <- resource(mount, :FiscalPeriod),
         {:ok, run_mod} <- resource(mount, :CloseRun) do
      scope = Mount.scope(mount, org_id)
      task_mod = task_module(mount)
      {period, run} = current_cycle(run_mod, period_mod, scope)

      report = if run, do: CloseBoard.report(run, task: task_mod, period: period)

      {:ok,
       %{
         period: period,
         run: run,
         report: report,
         task_wired?: task_mod != nil
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
  Sign one phase off through the host's OWN governed `:complete_phase` action.

  The guard refuses an unknown phase, a completed run, or a phase whose Work
  task is still open; the refusal is returned verbatim for the page's banner,
  never swallowed into a fake success.

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
