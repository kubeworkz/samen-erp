defmodule Samen.Scopes.Hr do
  @moduledoc """
  The **HR / Human Capital Management** universal scope (WS-ERP E7; design §5,
  component C2). Ships as a **library-authored blueprint** (ADR-004), the same
  shape as `Samen.Scopes.Finance`: `use`-ing this module inside a host's Ash
  domain expands into host-owned resources in the host's namespace, each a
  normal `use Samen.Resource` with the host's `otp_app`, `repo`, and `domain`.

  ## Resources — `employee 🔒 · employment_event · leave_request`

  - **`Employee`** — the employment record (the scope's ONLY 🔒 resource):
    `employee_number` (bounded, unique per org), `full_name` (`Samen.Type.FullName`,
    `:pii_name`), `work_emails`/`work_phones` (`:pii_email`/`:pii_phone`), `dob`
    optional (`:pii_dob`), `hired_at`, `terminated_at` (nullable),
    `employment_type ∈ {full_time, part_time, contract, intern}`, `manager_id`
    (self-ref, cycle-refused), `user_id` (nullable — employment ≠ access:
    employment may exist without a login, a login without employment is fine
    too), `archivable`. **Compensation is NOT a column** — it is ledgered on
    `EmploymentEvent` (comp history is exactly the data that must never be
    overwritten).
  - **`EmploymentEvent`** — the append-only employment ledger:
    `kind ∈ {hired, comp_changed, promoted, transferred, on_leave, returned,
    terminated}`, `effective_at`, `payload` (jsonb of BOUNDED fields; comp
    amounts are Money-shaped integer cents, never freeform), `note` (freeform →
    default-deny-CDC-excluded, Work-scope parity). HR "current state" = latest
    event per employee, derived — mirroring `Consent.state/3`
    latest-event-wins. Append-only at the DB (a trigger refuses UPDATE/DELETE).
  - **`LeaveRequest`** — `employee_id`, `kind ∈ {vacation, sick, unpaid, other}`,
    `start_date`/`end_date`, `status ∈ {pending, approved, rejected, cancelled}`.
    `:approve` rides the ADR-040 approvals engine as an ApprovalRequired GATE
    (the distinct approver re-invokes `:approve` as the requester inside the
    decision transaction), and the governed decision schedules an Automation
    reminder for the employee (fail-soft — reminders are observability, not the
    decision). Balance tracking is derived from events; a full accrual engine
    is a documented P2 carry.

  ## Payroll: fail-honest by construction

  WS-ERP ships NO payroll calculation engine — tax/withholding is
  jurisdiction-specific and half-claimed payroll is the worst kind of lie.
  `Samen.Hr.PayrollProvider` is the DECLARED adapter boundary (ADR-014/024/026
  shape): ` {:error, :not_configured}` default (the registry refuses unregistered
  kinds — a host brings a provider or journals comp expense through Finance
  manually). The Journals (GL) record payroll *postings*; they never *compute*
  them. The declared-not-built test pins the default.

  ## PII map — NON-EMPTY (INV-1, the watch-list discipline)

  | Resource | Field       | Vault      | Column type          |
  |----------|-------------|------------|----------------------|
  | employee | full_name   | :pii_name  | composite (no pii_)  |
  | employee | work_emails | :pii_email | composite (no pii_)  |
  | employee | work_phones | :pii_phone | composite (no pii_)  |
  | employee | dob         | :pii_dob   | scalar `pii_<abbr>_dob` |

  Every HR surface renders per-plane masked (`Samen.Api.PiiResolution`); the
  roster + HR CSV export are first-class masking surfaces with MANDATORY
  mask-by-omission red-paths (ADR-028 — the CSV cell equals the pixel on the
  same plane). Erasure: a former employee's vaulted fields crypto-shred through
  the standard subject path; the `EmploymentEvent` ledger survives (bounded,
  non-PII) — employment facts outlive the person's PII, exactly like consent
  events.

  ## Mounting the HR scope (the host side)

      defmodule Demo.HrScope do
        use Ash.Domain, validate_config_inclusion?: false

        use Samen.Scopes.Hr,
          otp_app: :demo,
          repo: Demo.Repo,
          namespace: Demo.HrScope

  This defines, in the host's namespace:

    * `Demo.HrScope.Employee`
    * `Demo.HrScope.EmploymentEvent`
    * `Demo.HrScope.LeaveRequest`

  ## Abbrevs (permanent, registry-checked)

  Each resource carries a permanent 3-letter abbrev, reserved in
  `samen_core/priv/abbrev_registry.json` under the HOST module name via
  `mix samen.abbrev.reserve` (ADR-023 — the macro does NOT invent abbrevs):

    * `Demo.HrScope.Employee`         → `hem` (demo default)
    * `Demo.HrScope.EmploymentEvent`  → `hev` (demo default)
    * `Demo.HrScope.LeaveRequest`     → `hlv` (demo default)

  Other hosts pass `abbrevs:` overrides (mirroring `Samen.Scopes.Finance`'s
  `abbrevs:` plumbing) when the defaults are already claimed.
  """

  # Demo defaults are UNCLAIMED-in-the-registry abbrevs (ADR-025 discipline —
  # the original `fac`-collision lesson: a default that collides with an
  # existing owner is a foot-gun, so defaults must verify free). A host whose
  # namespace already claims one of these passes `abbrevs:` overrides.
  @default_abbrevs %{
    employee: "hem",
    employment_event: "hev",
    leave_request: "hlv"
  }

  @doc false
  def default_abbrevs, do: @default_abbrevs

  defmacro __using__(opts) do
    otp_app = Keyword.fetch!(opts, :otp_app) |> Macro.expand(__CALLER__)
    repo = Keyword.fetch!(opts, :repo) |> Macro.expand(__CALLER__)
    namespace = Keyword.fetch!(opts, :namespace) |> Macro.expand(__CALLER__)
    domain = __CALLER__.module

    # Resolve abbrevs to a plain %{atom => string} AT EXPANSION TIME so each
    # blueprint call receives a LITERAL abbrev string (the Finance discipline —
    # the base macro validates abbrevs caller-side and requires a compile-time
    # literal).
    abbrevs = resolve_abbrevs(Keyword.get(opts, :abbrevs), __CALLER__)

    employee_mod = Module.concat(namespace, Employee)
    event_mod = Module.concat(namespace, EmploymentEvent)
    leave_mod = Module.concat(namespace, LeaveRequest)

    quote do
      require Samen.Scopes.Hr.Blueprint

      resources do
        resource(unquote(employee_mod))
        resource(unquote(event_mod))
        resource(unquote(leave_mod))
      end

      Samen.Scopes.Hr.Blueprint.define_employee(
        unquote(employee_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.employee),
        unquote(event_mod)
      )

      Samen.Scopes.Hr.Blueprint.define_employment_event(
        unquote(event_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.employment_event),
        unquote(employee_mod)
      )

      Samen.Scopes.Hr.Blueprint.define_leave_request(
        unquote(leave_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.leave_request),
        unquote(employee_mod)
      )
    end
  end

  defp resolve_abbrevs(nil, _caller), do: @default_abbrevs

  # A map literal arrives as a {:%{}, _, pairs} AST tuple — expand each
  # key/value at expansion time (the Finance discipline).
  defp resolve_abbrevs({:%{}, _, pairs}, caller) do
    override =
      Map.new(pairs, fn {k, v} ->
        {Macro.expand(k, caller), Macro.expand(v, caller)}
      end)

    Map.merge(@default_abbrevs, override)
  end

  defp resolve_abbrevs(other, _caller) do
    raise ArgumentError,
          "use Samen.Scopes.Hr, abbrevs: must be a compile-time map literal " <>
            "(%{employee: \"hem\", employment_event: \"hev\", leave_request: \"hlv\"}). Got: " <>
            Macro.to_string(other)
  end
end
