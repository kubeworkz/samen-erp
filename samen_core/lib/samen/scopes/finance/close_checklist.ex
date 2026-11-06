defmodule Samen.Scopes.Finance.CloseChecklist do
  @moduledoc """
  The **close checklist as checkable work** (WS-ACCT Phase 12; ADR-054 D7):
  one Work-scope `Task` per phase, anchored to its `CloseRun` through ADR-041's
  object-ref seam — `subject_key: "close_run"`, `subject_id: run.id` — never a
  second task engine.

  ## Why Work tasks

  ADR-054 D7 says the doc's ten phases become Work tasks "with the doc's twelve
  role assignments". The Work scope already ships the canonical task (status,
  owner, priority, the generic subject anchor, `custom` for phase metadata), so
  Phase 12 reuses it whole: this module only knows how to translate a phase into
  a task, which phase a task belongs to, and how to complete one. Ambiguity is
  resolved the same way the scope resolves it everywhere — the `custom` map
  carries `"close_phase"`, and the checklist order (not `inserted_at`) decides
  how the ten are listed.

  ## Seeding is idempotent

  `seed/2` reads the run's anchored tasks first and creates only the missing
  phases, so a re-run (a `CloseRun` created before Phase 12, a partially
  created checklist, a retried start) converges on one task per phase instead of
  duplicating the board. It is called in the `:start` action's AFTER action, in
  the same transaction as the run: a run whose checklist could not be created is
  not a started close.

  ## The task is operational; the phase is the sign-off

  Completing a task does not sign the phase, and (with Work wired)
  `CloseRun.:complete_phase` refuses while the phase's task is still open — the
  two facts must agree before the dashboard calls a phase done. The dashboard
  (`Samen.Scopes.Finance.CloseBoard`) reads BOTH and reports a phase done only
  when they agree, so an open task can never be shown as done even if a caller
  forces a sign-off through another path.

  ## The `custom` bag is catalogued, so the checklist registers its key

  The Work Task's `custom` bag validates at write against the org's `tnt_field`
  catalog (`Samen.CustomFields.Change`) — a key with no definition is refused.
  This module therefore registers the ONE key it writes (`close_phase`) as a
  string field on the host's task table before the first seed, exactly as
  `Samen.CRM.AccountLink` registers `billing_customer_id` (idempotent upsert, no
  migration).

  Nothing else is duplicated onto the task: the lead role, the supporting roster
  and the calendar window are PHASE data on `CloseRun.phases`
  (`ClosePhases.role_of/1`, `roles_for/1`), and a second copy on ten tasks would
  be ten more things to drift. The `custom` bag is also a governed tenant
  surface whose containment guard refuses free label text it reads as
  PII-shaped, so the anchor — a bounded phase key — is the only thing that
  belongs in it.

  ## No PII

  Titles, bodies and `custom` are freeform user content (the Work scope's own
  posture), and every value here comes from the source manual's phase table.
  No role assignment carries a person's identity: a role is a routing label, not
  a user id (ADR-054 Ratification 1).
  """

  require Ash.Query

  alias Samen.Scopes.Finance.ClosePhases

  @subject_key "close_run"

  @doc "The object-ref key every close task carries in `subject_key`."
  @spec subject_key() :: String.t()
  def subject_key, do: @subject_key

  @doc """
  The Work tasks anchored to a run, in the checklist's calendar order.

  `opts` requires `:task` (the host's mounted Work Task module). Returns `[]`
  when the run has no resolvable org rather than reading the whole table.
  """
  @spec tasks(struct(), keyword()) :: [struct()]
  def tasks(run, opts) do
    task_mod = Keyword.fetch!(opts, :task)
    org_id = org_id(run)

    if is_nil(org_id) do
      []
    else
      task_mod
      |> Ash.Query.filter(
        org_id == ^org_id and subject_key == ^@subject_key and subject_id == ^run.id
      )
      |> Ash.read!(authorize?: false)
      |> Enum.sort_by(&phase_index/1)
    end
  end

  @doc "The run's tasks keyed by close-phase key. A task with no phase label is ignored."
  @spec tasks_by_phase(struct(), keyword()) :: %{String.t() => struct()}
  def tasks_by_phase(run, opts) do
    run
    |> tasks(opts)
    |> Enum.reduce(%{}, fn task, acc ->
      case phase_key(task) do
        nil -> acc
        key -> Map.put(acc, key, task)
      end
    end)
  end

  @doc "The task anchored to one phase, or `nil`."
  @spec task_for(struct(), String.t(), keyword()) :: struct() | nil
  def task_for(run, phase_key, opts) do
    run
    |> tasks_by_phase(opts)
    |> Map.get(phase_key)
  end

  @doc """
  Create any missing phase task for the run. Returns `{:ok, %{phase_key => task}}`
  — the whole checklist, existing and new — or `{:error, {phase_key, reason}}`
  naming the phase whose task refused.

  A task that already exists is left EXACTLY as it is: a re-seed must never
  reopen work a human has done or overwrite a note.
  """
  @spec seed(struct(), keyword()) ::
          {:ok, %{String.t() => struct()}} | {:error, {String.t(), term()}}
  def seed(run, opts) do
    task_mod = Keyword.fetch!(opts, :task)

    with :ok <- register_fields(run, task_mod) do
      seed_phases(run, opts, task_mod)
    end
  end

  defp seed_phases(run, opts, task_mod) do
    Enum.reduce_while(ClosePhases.all(), {:ok, tasks_by_phase(run, opts)}, fn phase,
                                                                              {:ok, acc} ->
      if Map.has_key?(acc, phase.key) do
        {:cont, {:ok, acc}}
      else
        case create(run, phase, task_mod) do
          {:ok, task} -> {:cont, {:ok, Map.put(acc, phase.key, task)}}
          {:error, reason} -> {:halt, {:error, {phase.key, reason}}}
        end
      end
    end)
  end

  @doc "`seed/2`, raising on refusal. For seeds and tests, never a governed request."
  @spec seed!(struct(), keyword()) :: %{String.t() => struct()}
  def seed!(run, opts) do
    case seed(run, opts) do
      {:ok, tasks} ->
        tasks

      {:error, reason} ->
        raise "the close checklist could not be created: #{inspect(reason)}"
    end
  end

  @doc """
  Mark one task completed (the operational half of a phase sign-off).

  The task's `status`/`completed_at` are the Work scope's own fields; this
  helper only names the pair so every caller records the same fact.
  """
  @spec complete!(struct()) :: struct()
  def complete!(task) do
    task
    |> Ash.Changeset.for_update(
      :update,
      %{status: :completed, completed_at: DateTime.utc_now() |> DateTime.truncate(:second)},
      authorize?: false
    )
    |> Ash.update!(authorize?: false)
  end

  @doc "The close phase a task belongs to, or `nil` when it is not a close task."
  @spec phase_key(struct() | nil) :: String.t() | nil
  def phase_key(nil), do: nil

  def phase_key(%{custom: custom}) when is_map(custom) do
    Map.get(custom, "close_phase") || Map.get(custom, :close_phase)
  end

  def phase_key(_task), do: nil

  # ── creation ───────────────────────────────────────────────────────────────

  defp create(run, phase, task_mod) do
    attrs = %{
      org_id: org_id(run),
      kind: :task,
      title: title(phase),
      body: body(phase),
      status: :pending,
      priority: :normal,
      subject_key: @subject_key,
      subject_id: run.id,
      custom: %{"close_phase" => phase.key}
    }

    task_mod
    |> Ash.Changeset.for_create(:create, attrs, authorize?: false)
    |> Ash.create(authorize?: false)
  end

  defp title(phase) do
    index = Enum.find_index(ClosePhases.keys(), &(&1 == phase.key)) || 0
    "Phase #{index + 1} · #{phase.label}"
  end

  defp body(phase) do
    supporting = Enum.reject(phase.roles, &(&1 == phase.role))

    "#{phase.focus}. Output: #{phase.output}. Window: #{phase.days}. " <>
      "Lead: #{phase.role}." <>
      if(supporting == [], do: "", else: " Supporting: #{Enum.join(supporting, ", ")}.")
  end

  # ── catalog registration (the CRM AccountLink precedent) ──────────────────

  # Idempotent: `define_field/2` upserts on (org, table, field). The key is a
  # plain bounded string; the phase-key vocabulary is enforced by
  # `ClosePhases.fetch/1` on read, not by a custom-field constraint (a constraint
  # would freeze the checklist's key list into the tenant catalog).
  @custom_fields [
    {"close_phase", :string}
  ]

  defp register_fields(run, task_mod) do
    org_id = org_id(run)
    repo =
      AshPostgres.DataLayer.Info.repo(task_mod, :mutate) ||
        AshPostgres.DataLayer.Info.repo(task_mod)
    table = Samen.Catalog.table_name(task_mod)

    if is_nil(org_id) or is_nil(repo) or is_nil(table) do
      {:error, {:close_checklist_catalog, {:unresolved, org_id, repo, table}}}
    else
      Enum.reduce_while(@custom_fields, :ok, fn {name, type}, :ok ->
        case Samen.CustomFields.define_field(
               %{org_id: org_id, table_name: table, field_name: name, type: type},
               repo
             ) do
          {:ok, _row} -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, {name, reason}}}
        end
      end)
    end
  end

  # ── plumbing ───────────────────────────────────────────────────────────────

  defp phase_index(task) do
    key = phase_key(task)
    Enum.find_index(ClosePhases.keys(), &(&1 == key)) || 99
  end

  # `org_id` is often `%Ash.NotLoaded{}` on a freshly created run (the E4
  # lesson), and a query without the tenant would read another org's tasks.
  defp org_id(run) do
    case Map.get(run, :org_id) do
      id when is_binary(id) -> id
      _ -> loaded_org_id(run)
    end
  end

  defp loaded_org_id(run) do
    case Ash.load(run, [:org_id], authorize?: false) do
      {:ok, %{org_id: id}} when is_binary(id) -> id
      _ -> nil
    end
  end
end
