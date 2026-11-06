defmodule Samen.Scopes.Finance.SupplierOnboarding do
  @moduledoc """
  The **supplier onboarding checklist as checkable work** (WS-ACCT Phase 15;
  ADR-054 D18): one Work-scope `Task` per onboarding phase, anchored to a
  supplier through ADR-041's object-ref seam — `subject_key:
  "supplier_onboarding"`, `subject_id: vendor.id` — never a second task engine.

  The six phases are the source manual's onboarding stages: pre-onboarding/
  NDA, legal & compliance, technical/PDK, commercial & operational,
  operational integration, and first-shuttle/post-onboarding review. Each task
  carries the phase's accountable role as a routing label in its body, never a
  user id or a second copy of the supplier's contact data.

  ## Seeding is idempotent

  `seed/2` reads the supplier's anchored tasks first and creates only the
  missing phases. A re-run therefore converges on one task per phase instead of
  duplicating the board, and a task a human has already completed is left
  exactly as it is. The Work Task's `custom` bag is validated at write against
  the org's `tnt_field` catalog, so this module registers the one key it writes
  (`onboarding_phase`) before the first seed, exactly like the monthly close
  checklist.

  ## No PII

  The supplier is referenced by `vendor_id` only. Titles and bodies come from
  this module's phase table; no supplier contact, person name, email, or phone
  is copied onto a task, and an owner role is a routing label rather than an
  identity.
  """

  require Ash.Query

  @subject_key "supplier_onboarding"
  @phase_field "onboarding_phase"
  @phase_field_atom :onboarding_phase

  @phases [
    %{
      key: "pre_onboarding_nda",
      label: "Pre-Onboarding & NDA",
      focus: "Mutual NDA, export-control classification, onboarding owner and communication plan",
      output: "Executed NDA and onboarding plan",
      role: "Procurement Lead"
    },
    %{
      key: "legal_compliance",
      label: "Legal & Compliance",
      focus: "Supplier code of conduct, quality agreement, insurance and compliance documents",
      output: "Compliance pack accepted and contract routed",
      role: "Legal"
    },
    %{
      key: "technical_pdk",
      label: "Technical & PDK",
      focus: "PDK/DRC access, test-chip plan, technical qualification and IP handling",
      output: "Technical qualification plan approved",
      role: "Foundry Ops"
    },
    %{
      key: "commercial_operational",
      label: "Commercial & Operational",
      focus: "Pricing, capacity and slots, payment terms, Incoterms and forecast commitments",
      output: "Commercial terms and slot plan agreed",
      role: "Supply Chain"
    },
    %{
      key: "operational_integration",
      label: "Operational Integration",
      focus:
        "ERP supplier record, PO/AP setup, logistics, change notification and support routing",
      output: "Supplier active in ERP with a support model",
      role: "AP Clerk"
    },
    %{
      key: "first_shuttle_review",
      label: "First Shuttle & Review",
      focus:
        "First shuttle/first silicon, yield and quality review, post-onboarding scorecard baseline",
      output: "Post-onboarding review and first scorecard baseline",
      role: "Foundry Ops"
    }
  ]

  @doc "The object-ref key every onboarding task carries in `subject_key`."
  @spec subject_key() :: String.t()
  def subject_key, do: @subject_key

  @doc "The six onboarding phases, in checklist order."
  @spec phases() :: [map()]
  def phases, do: @phases

  @doc "The phase keys, in checklist order."
  @spec keys() :: [String.t()]
  def keys, do: Enum.map(@phases, & &1.key)

  @doc """
  The Work tasks anchored to a supplier, in the checklist's phase order.

  `opts` requires `:task` (the host's mounted Work Task module). Returns `[]`
  when the supplier has no resolvable org rather than reading the whole table.
  """
  @spec tasks(struct(), keyword()) :: [struct()]
  def tasks(vendor, opts) do
    task_mod = Keyword.fetch!(opts, :task)
    org_id = org_id(vendor)

    if is_nil(org_id) do
      []
    else
      task_mod
      |> Ash.Query.filter(
        org_id == ^org_id and subject_key == ^@subject_key and subject_id == ^vendor.id
      )
      |> Ash.read!(authorize?: false)
      |> Enum.sort_by(&phase_index/1)
    end
  end

  @doc "The supplier's tasks keyed by onboarding-phase key. A task with no phase label is ignored."
  @spec tasks_by_phase(struct(), keyword()) :: %{String.t() => struct()}
  def tasks_by_phase(vendor, opts) do
    vendor
    |> tasks(opts)
    |> Enum.reduce(%{}, fn task, acc ->
      case phase_key(task) do
        nil -> acc
        key -> Map.put(acc, key, task)
      end
    end)
  end

  @doc """
  Create any missing phase task for the supplier. Returns
  `{:ok, %{phase_key => task}}` — the whole checklist, existing and new — or
  `{:error, {phase_key, reason}}` naming the phase whose task refused.

  A task that already exists is left EXACTLY as it is: a re-seed must never
  reopen work a human has done or overwrite a note.
  """
  @spec seed(struct(), keyword()) ::
          {:ok, %{String.t() => struct()}} | {:error, {String.t(), term()}}
  def seed(vendor, opts) do
    task_mod = Keyword.fetch!(opts, :task)

    with :ok <- register_field(vendor, task_mod) do
      seed_phases(vendor, opts, task_mod)
    end
  end

  @doc "`seed/2`, raising on refusal. For seeds and tests, never a governed request."
  @spec seed!(struct(), keyword()) :: %{String.t() => struct()}
  def seed!(vendor, opts) do
    case seed(vendor, opts) do
      {:ok, tasks} ->
        tasks

      {:error, reason} ->
        raise "the supplier onboarding checklist could not be created: #{inspect(reason)}"
    end
  end

  @doc "The onboarding phase a task belongs to, or `nil` when it is not an onboarding task."
  @spec phase_key(struct() | nil) :: String.t() | nil
  def phase_key(nil), do: nil

  def phase_key(%{custom: custom}) when is_map(custom) do
    Map.get(custom, @phase_field) || Map.get(custom, @phase_field_atom)
  end

  def phase_key(_task), do: nil

  # ── creation ───────────────────────────────────────────────────────────────

  defp seed_phases(vendor, opts, task_mod) do
    Enum.reduce_while(@phases, {:ok, tasks_by_phase(vendor, opts)}, fn phase, {:ok, acc} ->
      if Map.has_key?(acc, phase.key) do
        {:cont, {:ok, acc}}
      else
        case create(vendor, phase, task_mod) do
          {:ok, task} -> {:cont, {:ok, Map.put(acc, phase.key, task)}}
          {:error, reason} -> {:halt, {:error, {phase.key, reason}}}
        end
      end
    end)
  end

  defp create(vendor, phase, task_mod) do
    attrs = %{
      org_id: org_id(vendor),
      kind: :task,
      title: title(phase),
      body: body(phase),
      status: :pending,
      priority: :normal,
      subject_key: @subject_key,
      subject_id: vendor.id,
      custom: %{@phase_field => phase.key}
    }

    task_mod
    |> Ash.Changeset.for_create(:create, attrs, authorize?: false)
    |> Ash.create(authorize?: false)
  end

  defp title(phase) do
    index = Enum.find_index(keys(), &(&1 == phase.key)) || 0
    "Phase #{index + 1} · #{phase.label}"
  end

  defp body(phase) do
    "#{phase.focus}. Output: #{phase.output}. Lead: #{phase.role}."
  end

  # ── catalog registration (the close-checklist precedent) ──────────────────

  defp register_field(vendor, task_mod) do
    org_id = org_id(vendor)

    repo =
      AshPostgres.DataLayer.Info.repo(task_mod, :mutate) ||
        AshPostgres.DataLayer.Info.repo(task_mod)

    table = Samen.Catalog.table_name(task_mod)

    if is_nil(org_id) or is_nil(repo) or is_nil(table) do
      {:error, {:supplier_onboarding_catalog, {:unresolved, org_id, repo, table}}}
    else
      case Samen.CustomFields.define_field(
             %{
               org_id: org_id,
               table_name: table,
               field_name: @phase_field,
               type: :string,
               constraints: %{max_length: 120}
             },
             repo
           ) do
        {:ok, _row} -> :ok
        {:error, reason} -> {:error, {@phase_field, reason}}
      end
    end
  end

  # ── plumbing ───────────────────────────────────────────────────────────────

  defp phase_index(task) do
    case phase_key(task) do
      nil -> 99
      key -> Enum.find_index(keys(), &(&1 == key)) || 99
    end
  end

  # `org_id` is often `%Ash.NotLoaded{}` on a freshly created vendor (the E4
  # lesson), and a query without the tenant would read another org's tasks.
  defp org_id(vendor) do
    case Map.get(vendor, :org_id) do
      id when is_binary(id) -> id
      _ -> loaded_org_id(vendor)
    end
  end

  defp loaded_org_id(vendor) do
    case Ash.load(vendor, [:org_id], authorize?: false) do
      {:ok, %{org_id: id}} when is_binary(id) -> id
      _ -> nil
    end
  end
end
