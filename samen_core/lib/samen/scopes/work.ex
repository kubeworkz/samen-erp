defmodule Samen.Scopes.Work do
  @moduledoc """
  The **Work** universal scope (F1; ADR-041 §3 — the canonical Work-scope Task,
  BINDING design). Ships as a **library-authored blueprint** (ADR-004), same shape
  as `Samen.Scopes.Support` (the closest structural template): `use`-ing this module
  inside a host's Ash domain expands into two host-owned resources in the host's
  namespace, each a normal `use Samen.Resource` with the host's `otp_app`, `repo`,
  and `domain`.

  ## Resources — `project · task` (self-referential Subtask tree)

  - **`Project`** — a container noun (name, status, owner). No PII.
  - **`Timesheet` / `TimesheetEntry`** — OPT-IN (`timesheets: [cost_object: ...]`):
    one employee's time capture for a period, and one day's minutes against ONE
    Finance cost object. Approved sheets are the labour driver for payroll cost
    allocation (WS-ACCT Unit 10.2; ADR-054 D17). Absent from mounts that do not
    pass `timesheets:`. No PII.
  - **`Task`** — the canonical Work item (ADR-041 §3.2, field-for-field): `kind`,
    `title`, `body`, `status` (plain enum, NOT a state machine — §4.3), `priority`
    (`Samen.Type.Priority`), `due_at`, `completed_at`, the generic `(subject_key,
    subject_id)` object-ref anchor (CRM-agnostic — never a CRM FK, §4.1), `custom`,
    `owner_id`, `parent_id` (self-referential — the Subtask tree, cycle-refused),
    `project_id`. No PII.

  **This scope is CRM-agnostic by construction and touches NO CRM code** — it is the
  destination T97 migrates the CRM `Activity` resource onto in a separate,
  file-partitioned task (ADR-041 §7). Building/testing/mounting the Work scope never
  requires the CRM to exist.

  ## PII map — EMPTY (INV-1)

  Neither resource carries a vault-routed field. See
  `Samen.Scopes.Work.Blueprint` moduledoc for the full posture and
  `docs/adr/ADR-041-canonical-task-activity-migration.md` §10 for the table.

  | Attribute | Classification | Vault? |
  |---|---|---|
  | `kind`, `status`, `subject_key` | non-PII (bounded atom/key) | no |
  | `priority` | non-PII (`Samen.Type.Priority` `:non_pii` + `TypeClearance`) | no |
  | `due_at`, `completed_at`, timestamps, `id`, `org_id`, `subject_id`, `owner_id`, `parent_id`, `project_id` | non-PII (id/timestamp) | no |
  | `title`, `body`, `custom` | freeform user content — default-deny-CDC-excluded, not vaulted (Activity parity) | no |

  ## Soft-delete (ADR-040 §5.9)

  Both `Project` and `Task` are `archivable: true`. Project archival does NOT cascade
  to its Tasks; Task archival DOES cascade to its Subtask subtree
  (`archive_related([:subtasks])`, ADR-041 §3.5).

  ## Subtask tree — cycle refusal (ADR-041 §3.4)

  `Task.parent_id` is self-referential. Every create/update that changes `parent_id`
  is refused if it would make the task its own (transitive) ancestor
  (`Samen.Scopes.Work.CycleGuard`), depth-bounded.

  ## Mounting the Work scope (the host side)

      defmodule Demo.WorkScope do
        use Ash.Domain, validate_config_inclusion?: false

        use Samen.Scopes.Work,
          otp_app: :demo,
          repo: Demo.Repo,
          namespace: Demo.WorkScope
      end

  This defines, in the host's namespace:

    * `Demo.WorkScope.Project`
    * `Demo.WorkScope.Task`

  ## Timesheets (opt-in, WS-ACCT Unit 10.2)

  A host that captures time passes the Finance cost-object module and two fresh
  abbrevs:

      use Samen.Scopes.Work,
        otp_app: :demo,
        repo: Demo.Repo,
        namespace: Demo.WorkScope,
        abbrevs: %{project: "wpj", task: "wtk", timesheet: "tws", timesheet_entry: "aaa"},
        timesheets: [cost_object: Demo.FinanceScope.CostObject]

  That mounts `Demo.WorkScope.Timesheet` and `Demo.WorkScope.TimesheetEntry` in
  addition to the two base resources. `timesheets:` is a compile-time keyword
  list; the cost-object module is what makes every entry same-org against a
  REAL programme. A mount that omits it has no timesheet resources at all (no
  half-wired table), and `Samen.Scopes.Finance`'s labour allocation refuses to
  draft when its `labour:` timesheet modules are not configured.

  ## Abbrevs (permanent, registry-checked)

  Each resource carries a permanent 3-letter abbrev, reserved in
  `samen_core/priv/abbrev_registry.json` under the HOST module name via
  `mix samen.abbrev.reserve` (ADR-023 — the macro does NOT invent abbrevs):

    * `Demo.WorkScope.Project` → `wpj`
    * `Demo.WorkScope.Task`    → `wtk`
    * `Demo.WorkScope.Timesheet` → `tws` (opt-in)
    * `Demo.WorkScope.TimesheetEntry` → `aaa` (opt-in)

  Defaults are provided for the demo mount; other hosts pass `abbrevs:` overrides
  (mirroring `Samen.Scopes.Support`'s `abbrevs:` plumbing) when the defaults are
  already claimed. The two timesheet abbrevs have NO defaults — a host mounting
  timesheets must name them explicitly (every host owns a distinct namespace).
  """

  @default_abbrevs %{
    project: "wpj",
    task: "wtk"
  }

  @doc false
  def default_abbrevs, do: @default_abbrevs

  defmacro __using__(opts) do
    otp_app = Keyword.fetch!(opts, :otp_app) |> Macro.expand(__CALLER__)
    repo = Keyword.fetch!(opts, :repo) |> Macro.expand(__CALLER__)
    namespace = Keyword.fetch!(opts, :namespace) |> Macro.expand(__CALLER__)
    domain = __CALLER__.module

    # Resolve abbrevs to a plain %{atom => string} map AT EXPANSION TIME so each
    # blueprint call receives a LITERAL abbrev string (mirrors Samen.Scopes.Support —
    # the base macro validates abbrevs caller-side and requires a compile-time literal).
    abbrevs = resolve_abbrevs(Keyword.get(opts, :abbrevs), __CALLER__)
    timesheets = resolve_timesheets(Keyword.get(opts, :timesheets), abbrevs, __CALLER__)
    # Read once: these are nil on mounts that do not opt into timesheets, and
    # the blueprint calls live behind the `if` below.
    timesheet_abbrev = abbrevs[:timesheet]
    timesheet_entry_abbrev = abbrevs[:timesheet_entry]

    project_mod = Module.concat(namespace, Project)
    task_mod = Module.concat(namespace, Task)
    timesheet_mod = Module.concat(namespace, Timesheet)
    entry_mod = Module.concat(namespace, TimesheetEntry)

    quote do
      require Samen.Scopes.Work.Blueprint
      require Samen.Scopes.Work.TimesheetBlueprint

      resources do
        resource(unquote(project_mod))
        resource(unquote(task_mod))
      end

      if unquote(not is_nil(timesheets)) do
        resources do
          resource(unquote(timesheet_mod))
          resource(unquote(entry_mod))
        end
      end

      Samen.Scopes.Work.Blueprint.define_project(
        unquote(project_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.project)
      )

      Samen.Scopes.Work.Blueprint.define_task(
        unquote(task_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.task),
        unquote(project_mod)
      )

      if unquote(not is_nil(timesheets)) do
        Samen.Scopes.Work.TimesheetBlueprint.define_timesheet(
          unquote(timesheet_mod),
          unquote(otp_app),
          unquote(domain),
          unquote(repo),
          unquote(timesheet_abbrev),
          unquote(entry_mod)
        )

        Samen.Scopes.Work.TimesheetBlueprint.define_timesheet_entry(
          unquote(entry_mod),
          unquote(otp_app),
          unquote(domain),
          unquote(repo),
          unquote(timesheet_entry_abbrev),
          unquote(timesheet_mod),
          unquote(timesheets)
        )
      end
    end
  end

  defp resolve_abbrevs(nil, _caller), do: @default_abbrevs

  defp resolve_abbrevs({:%{}, _, pairs}, caller) do
    override =
      Map.new(pairs, fn {k, v} ->
        {Macro.expand(k, caller), Macro.expand(v, caller)}
      end)

    Map.merge(@default_abbrevs, override)
  end

  defp resolve_abbrevs(other, _caller) do
    raise ArgumentError,
          "use Samen.Scopes.Work, abbrevs: must be a compile-time map literal " <>
            "(%{project: \"wpj\", task: \"wtk\"}). Got: #{Macro.to_string(other)}"
  end

  # `timesheets:` is either absent (no timesheet resources — the default for
  # every pre-10.2 mount) or a compile-time keyword list whose `:cost_object`
  # module is the host's Finance cost object. Resolve it to the expanded module
  # atom at expansion time so the blueprint receives a literal.
  defp resolve_timesheets(nil, _abbrevs, _caller), do: nil

  defp resolve_timesheets(opts, abbrevs, caller) when is_list(opts) do
    unless is_binary(abbrevs[:timesheet]) and is_binary(abbrevs[:timesheet_entry]) do
      raise ArgumentError,
            "use Samen.Scopes.Work, timesheets: requires explicit abbrevs: " <>
              "%{timesheet: ..., timesheet_entry: ...} (every host owns a distinct namespace)"
    end

    case Keyword.fetch(opts, :cost_object) do
      {:ok, cost_object} -> Macro.expand(cost_object, caller)
      :error -> raise ArgumentError, "use Samen.Scopes.Work, timesheets: requires cost_object: <Finance.CostObject module>"
    end
  end

  defp resolve_timesheets(other, _abbrevs, _caller) do
    raise ArgumentError,
          "use Samen.Scopes.Work, timesheets: must be a compile-time keyword list " <>
            "([cost_object: Some.Finance.CostObject]). Got: #{Macro.to_string(other)}"
  end
end
