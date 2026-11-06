defmodule Samen.Web.Finance.CloseDashboard do
  @moduledoc """
  The monthly close dashboard's read (WS-ACCT Phase 12; ADR-054 D7).

  `Samen.Scopes.Finance.CloseBoard` computes the honest board for ONE run.
  This module answers the surface's first question — WHICH run is the current
  one — and hands the page a single state map:

    * the newest `:in_progress` run, else the newest run overall (a completed
      close stays visible until the next period's close starts), else
    * the newest `FiscalPeriod` with no run, so a fresh month renders its
      honest empty state naming the month that has no close.

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
    runs =
      run_mod
      |> Ash.Query.load(:period)
      |> Ash.read!(scope: scope)
      |> Enum.filter(&period_row?/1)
      |> Enum.sort_by(&{&1.period.year, &1.period.month}, :desc)

    case Enum.find(runs, &(&1.status == :in_progress)) || List.first(runs) do
      nil -> {latest_period(period_mod, scope), nil}
      run -> {run.period, run}
    end
  end

  defp period_row?(%{period: period}) when is_map(period),
    do: Map.has_key?(period, :year) and Map.has_key?(period, :month)

  defp period_row?(_run), do: false

  defp latest_period(period_mod, scope) do
    period_mod
    |> Ash.Query.sort(year: :desc, month: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read!(scope: scope)
    |> List.first()
  end

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
end
