defmodule Samen.Automation.Health do
  @moduledoc """
  The E8 operator-facing API (ADR-039 §8.3/§8.4; T42) — the SaaS operator's
  cross-tenant view over Automation health + the operator half of the
  two-switch kill. Mirrors `Samen.OperatorPlane`'s exact idiom: an
  application-code RBAC gate (`may_view?/1` / `may_manage?/1`) checked BEFORE
  every read/write, then `authorize?: false` — because the real actor here is
  CROSS-ORG (the operator reaching ANY tenant's workflow by id), which a plain
  `Samen.Policy.OrgScope` policy cannot express. `Automation.Run`'s own
  policies bypass writes entirely (`Samen.Scopes.Automation.Blueprint`) — THIS
  module is the enforcement point, exactly like `Samen.OperatorPlane` is for
  the operator CRM.

  ## Token-blind by construction (INV-1/INV-2)

  Every read here comes from `Automation.Workflow` (bounded ids/enums/jsonb
  condition+action CONFIGS, never subject values) and `Automation.Run`
  (bounded ids/enums/timestamps/bounded outcome jsonb) — there is no `%Masked{}`
  branch and no reveal path because there is no PII column to reach in the
  first place (the same posture `Samen.Web.Operator.WebhookDlqLive` documents
  for the webhook DLQ).

  ## Host wiring

  Resolves `workflow_module`/`run_module`/`repo` from
  `config :samen_core, Samen.Automation, ...` (opts override) — the same
  seam `Samen.Automation.RunWorker`/`DispatchWorker` already use, so the
  operator surface and the engine always agree on which host resources they
  mean.

  ## Three silences, never one (fail-honest, ADR-014/024/026)

  An operator page over this API must be able to tell apart the facts it prints as
  "nothing":

    * **the host wired no engine** — `availability/0 == :unavailable`; `summary/3` and
      `runs/3` refuse `{:error, :unavailable}` (the pawchart/demo posture);
    * **the host wired the engine but not its run side** (driftwood/samenerp today: no
      `run_module`) — the workflow rows are readable and carry `runs_readable: false` with
      `nil` run aggregates; `runs/3` refuses `{:error, :unavailable}`, because the RUN LOG
      genuinely cannot be read here;
    * **a wired read RAISED** — `{:error, :read_failed}`, never `{:ok, []}`.

  Only a read that ANSWERED produces `{:ok, rows}` — including `{:ok, []}`, which is the
  one and only "this tenant has none".
  """

  require Ash.Query
  import Ash.Query

  alias Samen.Automation
  alias Samen.OperatorPlane.Actor

  # ---------------------------------------------------------------------------
  # RBAC gates
  # ---------------------------------------------------------------------------

  @doc "May this operator VIEW automation health (read-only)?"
  @spec may_view?(Actor.t() | term()) :: boolean()
  def may_view?(%Actor{operator_role: role}),
    do: role in [:operator_admin, :operator_support, :operator_readonly]

  def may_view?(_), do: false

  @doc "May this operator KILL / re-arm a workflow (a write)? Readonly may NOT."
  @spec may_manage?(Actor.t() | term()) :: boolean()
  def may_manage?(%Actor{operator_role: role}),
    do: role in [:operator_admin, :operator_support]

  def may_manage?(_), do: false

  # ---------------------------------------------------------------------------
  # Availability — honest-empty vs cannot-read (the A6 / R-A5-4 posture)
  # ---------------------------------------------------------------------------

  @doc """
  Is the automation engine READABLE on this host — `:available` or `:unavailable`?

  `config :samen_core, Samen.Automation, workflow_module: ...` is the seam every entry
  below resolves through; a host that wired no workflow module has no automation to
  read at all (`Samen.Automation` documents the unwired engine as INERT, which is a
  fact about the HOST, not about any tenant's workflows). Decided at the seam, without
  touching the database — a wired-but-unreadable host reports `:read_failed` from the
  read itself, so the two are never conflated.

  Deliberately NOT org-scoped: the engine is wired per HOST, and asking per org would
  invite the very confusion this closes (org with no workflows vs host with no engine).
  """
  @spec availability() :: :available | :unavailable
  def availability do
    if Automation.workflow_module(), do: :available, else: :unavailable
  end

  @doc "`availability/0` as a boolean, for callers that only branch."
  @spec available?() :: boolean()
  def available?, do: availability() == :available

  @doc """
  Can this host's RUN side be read at all — `:available` or `:unavailable`?

  `run_module` is the observability half of the same seam (`Samen.Automation`: the
  `RunRecord`/`Health`/`Breaker` family degrades to no-ops when it is unset) and is
  wired INDEPENDENTLY of the engine: driftwood and samenerp wire workflows and no run
  module today. The run log is then unreadable HERE, which is not the fact "this org has
  no runs" — `runs/3` refuses rather than answering `[]`.
  """
  @spec run_log_availability() :: :available | :unavailable
  def run_log_availability do
    if Automation.run_module(), do: :available, else: :unavailable
  end

  # ---------------------------------------------------------------------------
  # Reads
  # ---------------------------------------------------------------------------

  @doc """
  Per-workflow health aggregates for ONE tenant org (ADR-039 §8.3): run counts
  by state, error-kind distribution, last failure, trip status. Refuses
  `{:error, :not_authorized}` for a non-viewing actor and `{:error, :unavailable}` on a
  host that wired no engine — the refusal ORDER is itself a boundary (an unauthorized
  caller learns nothing about the host's wiring).
  """
  @spec summary(Actor.t() | term(), String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def summary(operator, org_id, opts \\ []) do
    cond do
      not may_view?(operator) -> {:error, :not_authorized}
      availability() == :unavailable -> {:error, :unavailable}
      true -> build_summary(org_id, opts)
    end
  end

  @doc """
  Recent Run rows for ONE tenant org, optionally scoped to one workflow
  (`opts[:workflow_id]`), newest first, bounded by `opts[:limit]` (default 100).
  Refuses `{:error, :not_authorized}` for a non-viewing actor and
  `{:error, :unavailable}` on a host whose run side is unwired.
  """
  @spec runs(Actor.t() | term(), String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def runs(operator, org_id, opts \\ []) do
    cond do
      not may_view?(operator) -> {:error, :not_authorized}
      run_log_availability() == :unavailable -> {:error, :unavailable}
      true -> list_runs(org_id, opts)
    end
  end

  # ---------------------------------------------------------------------------
  # Writes — the operator kill-switch (ADR-039 §8.4)
  # ---------------------------------------------------------------------------

  @doc """
  Kill a workflow (`disabled_reason: :operator`) — idempotent, audited
  (`Samen.AuditEvent`, org-partitioned, actor-attributed). Refuses
  `{:error, :not_authorized}` for an actor that may not manage.
  """
  @spec kill(Actor.t() | term(), String.t(), keyword()) :: {:ok, struct()} | {:error, term()}
  def kill(operator, workflow_id, opts \\ []) do
    if may_manage?(operator) do
      switch(:operator_kill, %{reason: :operator}, operator, workflow_id, opts)
    else
      {:error, :not_authorized}
    end
  end

  @doc """
  Re-arm a workflow (clears both kill columns) — idempotent, audited. Refuses
  `{:error, :not_authorized}` for an actor that may not manage.
  """
  @spec rearm(Actor.t() | term(), String.t(), keyword()) :: {:ok, struct()} | {:error, term()}
  def rearm(operator, workflow_id, opts \\ []) do
    if may_manage?(operator) do
      switch(:operator_rearm, %{}, operator, workflow_id, opts)
    else
      {:error, :not_authorized}
    end
  end

  # ---------------------------------------------------------------------------
  # Internal
  # ---------------------------------------------------------------------------

  defp switch(action, args, operator, workflow_id, opts) do
    case Automation.workflow_module(opts) do
      nil ->
        {:error, :no_automation_module}

      wf_mod ->
        with {:ok, wf} <- fetch_workflow(wf_mod, workflow_id),
             {:ok, updated} <-
               wf
               |> Ash.Changeset.for_update(action, args, authorize?: false)
               |> Ash.update(authorize?: false) do
          # Ash's update result does not carry forward an attribute that was
          # merely SELECTED (not written) on the pre-update struct — capture
          # org_id from `wf` (explicitly ensure_selected in `fetch_workflow/2`)
          # rather than trusting `updated.org_id`.
          audit_switch(action, updated, wf.org_id, operator, opts)
          {:ok, updated}
        end
    end
  end

  # `Ash.get/3` does not accept a pre-built query, and `org_id` (like every
  # cross-org operator-plane lookup here) is not guaranteed selected by the
  # resource's default read — ensure_selected it explicitly (the
  # `RunWorker.load_workflow/2` precedent) so the audit's `correlation_id`
  # (and the caller's `{:ok, updated}` return) always carry it.
  defp fetch_workflow(wf_mod, workflow_id) do
    wf_mod
    |> filter(id == ^workflow_id)
    |> Ash.Query.ensure_selected([:org_id])
    |> Ash.read!(authorize?: false)
    |> case do
      [wf | _] -> {:ok, wf}
      [] -> {:error, :not_found}
    end
  rescue
    e -> {:error, e}
  end

  defp audit_switch(action, wf, org_id, operator, opts) do
    repo = Automation.repo(opts)

    if repo do
      Samen.AuditEvent.insert(repo, %{
        event_type: "system",
        subject_id: to_string(wf.id),
        actor_id: operator_id(operator),
        correlation_id: org_id,
        detail: "automation.workflow.#{action} killed=#{not is_nil(wf.disabled_by_operator_at)}"
      })
    end

    :ok
  rescue
    _ -> :ok
  end

  defp operator_id(%Actor{id: id}), do: id
  defp operator_id(%{id: id}), do: id
  defp operator_id(_), do: nil

  # FAIL-HONEST — see the moduledoc's "three silences". The old `else _ -> []` collapsed
  # "this host wired nothing" and "this host wired no run side" into the same empty SUCCESS
  # as "this org has no workflows", a claim about a tenant's data no read here observed.
  defp build_summary(org_id, opts) do
    with {:ok, workflows} <- safe_read_by_org(Automation.workflow_module(opts), org_id) do
      case Automation.run_module(opts) do
        # Engine wired, run side not: the workflow rows ARE readable, their run aggregates
        # are not — each row says so (`runs_readable: false`) instead of a measured 0.
        nil ->
          {:ok,
           Enum.map(workflows, fn wf ->
             {:ok, row} = workflow_row(wf, nil, org_id)
             row
           end)}
        run_mod -> workflow_rows(workflows, run_mod, org_id)
      end
    end
  end

  defp workflow_rows(workflows, run_mod, org_id) do
    workflows
    |> Enum.reduce_while({:ok, []}, fn wf, {:ok, acc} ->
      case workflow_row(wf, run_mod, org_id) do
        {:ok, row} -> {:cont, {:ok, [row | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, rows} -> {:ok, Enum.reverse(rows)}
      {:error, _} = err -> err
    end
  end

  defp workflow_row(wf, nil, _org_id) do
    {:ok, health_row(wf, nil, nil, nil, nil, false)}
  end

  defp workflow_row(wf, run_mod, org_id) do
    with {:ok, runs} <- runs_for_workflow(run_mod, org_id, wf.id, 500) do
      by_state =
        runs
        |> Enum.map(& &1.state)
        |> Enum.frequencies()

      by_error_kind =
        runs
        |> Enum.map(& &1.error_kind)
        |> Enum.reject(&is_nil/1)
        |> Enum.frequencies()

      last_failure =
        runs
        |> Enum.filter(&(&1.state == :failed))
        |> Enum.max_by(& &1.finished_at, fn a, b -> compare_dt(a, b) end, fn -> nil end)

      {:ok,
       health_row(
         wf,
         length(runs),
         by_state,
         by_error_kind,
         last_failure && last_failure.finished_at,
         true
       )}
    end
  end

  defp health_row(wf, total_runs, run_counts, error_kind_counts, last_failure_at, runs_readable) do
    %{
      workflow_id: wf.id,
      name: wf.name,
      status: wf.status,
      trigger_kind: wf.trigger_kind,
      killed: not is_nil(wf.disabled_by_operator_at),
      disabled_reason: wf.disabled_reason,
      disabled_by_operator_at: wf.disabled_by_operator_at,
      total_runs: total_runs,
      run_counts: run_counts,
      error_kind_counts: error_kind_counts,
      last_failure_at: last_failure_at,
      # FALSE = "this host cannot read runs at all": the row states the silence rather
      # than reporting 0 over a run side that was never read (moduledoc, second silence).
      runs_readable: runs_readable
    }
  end

  defp compare_dt(%DateTime{} = a, %DateTime{} = b), do: DateTime.compare(a, b) != :lt
  defp compare_dt(nil, _), do: false
  defp compare_dt(_a, nil), do: true

  # `{:ok, rows}` ONLY for a read that answered — a raise is `{:error, :read_failed}`, never
  # `{:ok, []}`. The unwired-run-module case is refused one level up (`runs/3`, so an
  # unauthorized caller never reaches it).
  defp list_runs(org_id, opts) do
    limit = Keyword.get(opts, :limit, 100)
    workflow_id = Keyword.get(opts, :workflow_id)

    Automation.run_module(opts)
    |> filter(org_id == ^org_id)
    |> maybe_filter_workflow(workflow_id)
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.Query.limit(limit)
    |> Ash.read!(authorize?: false)
    |> then(&{:ok, &1})
  rescue
    _ -> {:error, :read_failed}
  end

  defp maybe_filter_workflow(query, nil), do: query
  defp maybe_filter_workflow(query, workflow_id), do: filter(query, workflow_id == ^workflow_id)

  # A per-workflow run read that RAISES must not become `total_runs: 0` for that workflow
  # (a measured-looking 0 the read never measured) — it fails the whole summary instead.
  defp runs_for_workflow(run_mod, org_id, workflow_id, limit) do
    run_mod
    |> filter(org_id == ^org_id)
    |> filter(workflow_id == ^workflow_id)
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.Query.limit(limit)
    |> Ash.read!(authorize?: false)
    |> then(&{:ok, &1})
  rescue
    _ -> {:error, :read_failed}
  end

  # `{:ok, rows} | {:error, :read_failed}` — a workflow read that raised observed nothing,
  # so it says so instead of answering the empty list that means "this org has none".
  defp safe_read_by_org(resource, org_id) do
    resource
    |> filter(org_id == ^org_id)
    |> Ash.read!(authorize?: false)
    |> then(&{:ok, &1})
  rescue
    _ -> {:error, :read_failed}
  end
end
