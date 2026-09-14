defmodule Samen.Scopes.Hr.Blueprint do
  @moduledoc """
  Resource-definition macros for the **HR** scope (WS-ERP E7; design §5,
  component C2).

  Objects: `employee 🔒 · employment_event · leave_request`. Employment ≠
  access: `Employee` carries the employment record (with a nullable
  `user_id` — a login without employment is fine, employment without a login
  is fine); `EmploymentEvent` is the append-only ledger whose latest event per
  employee IS the derived current state (the `Consent.state/3` mirror);
  `LeaveRequest` rides the ADR-040 approvals engine for `:approve`.

  ## PII map — NON-EMPTY (INV-1, the watch-list discipline)

  | Resource | Field       | Vault      | Column type          |
  |----------|-------------|------------|----------------------|
  | employee | full_name   | :pii_name  | composite (no pii_)  |
  | employee | work_emails | :pii_email | composite (no pii_)  |
  | employee | work_phones | :pii_phone | composite (no pii_)  |
  | employee | dob         | :pii_dob   | scalar `pii_<abbr>_dob` |

  `Employee` is the scope's ONLY 🔒 resource. Every column is vault-routed at
  rest (`vt_*` tokens, plaintext nowhere), per-plane masked on read through
  `Samen.Api.PiiResolution` (the tenant's own org clear, the
  operator-without-grant plane `%Samen.Masked{}` → `••••`), and producible as
  plaintext ONLY through the declared reveal action under a grant. The
  EmploymentEvent ledger is bounded, non-PII — employment facts outlive the
  person's PII (the erasure story: the vault shreds, the ledger survives).

  ## Compensation is a ledger fact, not a column

  No `salary`/`comp` column exists anywhere in the scope. Comp history lives
  on `EmploymentEvent :comp_changed` rows (`payload["annual_cents"]` /
  `payload["currency"]` — Money-shaped, bounded), because comp history is
  exactly the kind of data that must be ledgered, never overwritten. The GL
  journals payroll *postings*; it never *computes* them
  (`Samen.Hr.PayrollProvider` — `{:error, :not_configured}` default).

  ## Storage-name discipline

  Every column is `<abbrev>_<name>` (self-qualifying storage, injected by the
  Samen base macro and the abbrev transformer). Composite PII keeps the bare
  resource-abbrev form (`<abbrev>_full_name` — the token column); scalar PII
  carries the `pii_` prefix (`pii_<abbrev>_dob`) per the scope-authoring guide
  §5 and the `initial_core` precedent.
  """

  # ---------------------------------------------------------------------------
  # Employee — the 🔒 employment record (design §5)
  # ---------------------------------------------------------------------------
  defmacro define_employee(module, otp_app, domain, repo, abbrev, event_mod) do
    # (event_mod is consumed by the :create cascade below)
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Hr.Employee — the employment record (WS-ERP E7; design §5). The scope's
        ONLY 🔒 resource: `full_name`/`work_emails`/`work_phones`/`dob` are
        vault-routed (INV-1); everything else is bounded, non-PII.

        Employment ≠ access: `user_id` is a nullable FK to the host's Identity
        User — employment may exist without a login, a login without employment
        is fine too. `manager_id` is the self-referential reporting tree
        (cycle-refused by `Samen.Scopes.Hr.ManagerCycle`). Compensation is NOT
        a column — it is ledgered on `EmploymentEvent :comp_changed` (comp
        history must be ledgered, never overwritten).

        Erasure: the vaulted fields crypto-shred through the standard subject
        path; the row's bounded columns (employee_number, dates, type) survive
        as non-personal employment facts.
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev),
          archivable: true

        postgres do
          table("#{unquote(abbrev)}_employee")
          repo(unquote(repo))
        end

        attributes do
          attribute(:employee_number, :string,
            public?: true,
            allow_nil?: false,
            constraints: [max_length: 40]
          )

          attribute(:hired_at, :date, public?: true, allow_nil?: false)
          attribute(:terminated_at, :date, public?: true)

          attribute(:employment_type, :atom,
            public?: true,
            allow_nil?: false,
            default: :full_time,
            constraints: [one_of: [:full_time, :part_time, :contract, :intern]]
          )

          attribute(:manager_id, :uuid, public?: true)
          attribute(:user_id, :uuid, public?: true)
        end

        pii do
          vault(:pii_name)
          vault(:pii_email)
          vault(:pii_phone)
          vault(:pii_dob)

          # Composite types route by vault name — the token columns keep the
          # bare resource-abbrev form (`<abbrev>_full_name`, no pii_ prefix).
          pii_attribute(:full_name, Samen.Type.FullName, vault: :pii_name)
          pii_attribute(:work_emails, Samen.Type.Emails, vault: :pii_email)
          pii_attribute(:work_phones, Samen.Type.Phones, vault: :pii_phone)

          # Scalar PII: the pii_ prefixed column (pii_<abbrev>_dob).
          pii_attribute(:dob, :date, vault: :pii_dob)

          # The declared reveal action: plaintext under a grant ONLY.
          reveal(:reveal_employee)
        end

        identities do
          identity(:unique_employee_number, [:org_id, :employee_number])
        end

        relationships do
          belongs_to(:manager, unquote(module)) do
            source_attribute(:manager_id)
            public?(true)
          end
        end

        actions do
          # (the explicit `update :update` below owns updates — a default
          # `update: :*` here would collide with it)
          defaults([:read, :destroy])

          create :create do
            # org_id is an explicit accept (the Automation-scope idiom): the
            # tenant-plane write names its own org; OrgScope + SameOrgFk govern it.
            accept([
              :org_id,
              :employee_number,
              :hired_at,
              :terminated_at,
              :employment_type,
              :manager_id,
              :user_id,
              :full_name,
              :work_emails,
              :work_phones,
              :dob
            ])

            # The :hired ledger row lands in-transaction (the ledger is the
            # SoT for employment state — an employee is born with its hired
            # event carrying the same effective facts).
            primary?(true)

            change({Samen.Scopes.Hr.HiredEvent, event: unquote(event_mod)})
          end

          update :update do
            # Bounded employment facts + the reporting tree. The vaulted
            # composites are accepted through the vault WriteGuard exactly as
            # any create/update does; comp is NOT accepted (no column).
            accept([
              :employee_number,
              :hired_at,
              :terminated_at,
              :employment_type,
              :manager_id,
              :user_id,
              :full_name,
              :work_emails,
              :work_phones,
              :dob
            ])

            require_atomic?(false)
            change(Samen.Scopes.Hr.ManagerCycle)
          end

          # The declared reveal action (plaintext under a grant only). The
          # Billing reveal shape: the action is a first-class marker whose
          # run/2 consults the grant checker and denies by default.
          action :reveal_employee, :map do
            argument(:actor_id, :string, allow_nil?: false)
            argument(:subject_id, :string, allow_nil?: false)

            run(fn input, _ctx ->
              ctx = %Samen.Reveal.Context{
                actor: input.arguments.actor_id,
                subject_id: input.arguments.subject_id,
                resource: __MODULE__,
                action: :reveal_employee,
                label: :work_emails
              }

              if Samen.Reveal.grant_checker().granted?(ctx) do
                {:ok, %{status: "granted", subject_id: input.arguments.subject_id}}
              else
                {:error, :denied}
              end
            end)
          end
        end

        policies do
          policy action_type(:read) do
            authorize_if(Samen.Policy.OrgScope)
          end

          policy action_type([:create, :update, :destroy]) do
            forbid_unless(Samen.Policy.OrgScope)
            forbid_unless({Samen.Policy.RoleAtLeast, role: :member})
            authorize_if(always())
          end

          # The reveal action's grant gate (inside run/2) is the real control;
          # allow the action to run for any actor — the grant denies by default.
          policy action(:reveal_employee) do
            authorize_if(always())
          end
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # EmploymentEvent — the append-only employment ledger (design §5)
  # ---------------------------------------------------------------------------
  defmacro define_employment_event(module, otp_app, domain, repo, abbrev, _employee_mod) do
    # (_employee_mod is positional for mount symmetry; the ledger anchors by
    # employee_id — no Ash relationship is declared)
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Hr.EmploymentEvent — the append-only employment ledger (WS-ERP E7;
        design §5). HR "current state" = latest event per employee, DERIVED —
        mirroring `Samen.Marketing.Consent.state/3` latest-event-wins.

        `payload` is a jsonb of BOUNDED keys; comp amounts are Money-shaped
        integer cents (`annual_cents` + `currency`), never freeform. `note` is
        freeform user content → default-deny-CDC-excluded, not vaulted (the
        Work-scope parity). Append-only at the DB: a trigger refuses
        UPDATE/DELETE (the StockLedger discipline).
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_employment_event")
          repo(unquote(repo))
        end

        attributes do
          attribute(:employee_id, :uuid, public?: true, allow_nil?: false)

          attribute(:kind, :atom,
            public?: true,
            allow_nil?: false,
            constraints: [one_of: [:hired, :comp_changed, :promoted, :transferred, :on_leave, :returned, :terminated]]
          )

          attribute(:effective_at, :utc_datetime, public?: true, allow_nil?: false)

          # Bounded facts (comp amounts are Money-shaped cents, never freeform).
          attribute(:payload, :map, public?: true)

          # Freeform user content → default-deny-CDC-excluded (Work parity).
          attribute(:note, :string, public?: true, constraints: [max_length: 2_000])
        end

        actions do
          defaults([:read])

          create :create do
            accept([:org_id, :employee_id, :kind, :effective_at, :payload, :note])
            primary?(true)
          end
        end

        policies do
          policy action_type(:read) do
            authorize_if(Samen.Policy.OrgScope)
          end

          policy action_type(:create) do
            forbid_unless(Samen.Policy.OrgScope)
            forbid_unless({Samen.Policy.RoleAtLeast, role: :member})
            authorize_if(always())
          end
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # LeaveRequest — the ADR-040 gated time-off document (design §5)
  # ---------------------------------------------------------------------------
  defmacro define_leave_request(module, otp_app, domain, repo, abbrev, employee_mod) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Hr.LeaveRequest — a time-off request (WS-ERP E7; design §5).
        `status ∈ {pending, approved, rejected, cancelled}`.

        ## The approve discipline (ADR-040)

        `:approve` carries `Samen.Approvals.Gate`: an ungated call is REFUSED
        with `Samen.Approvals.ApprovalRequired` and opens (or returns) the
        pending approval `kind: "<this module>:approve"`, `subject_ref` = this
        request's object-ref. The DISTINCT approver's `Samen.Approvals.approve/3`
        re-invokes `:approve` AS THE REQUESTER inside the decision transaction
        (approval adds second-party consent, never privilege — ADR-040 §4.4).
        The governed decision schedules an Automation reminder for the employee
        (fail-soft — `Samen.Scopes.Hr.Reminders`; a skipped reminder never
        blocks the decision).

        ## No persisted inputs (ADR-040 §4.4, INV-1)

        `:approve` accepts NOTHING — a bounded transition on an existing
        record; freeform inputs are exactly what must not be deferred.

        ## Balance tracking

        Derived from events (the ledger is the SoT); a full accrual engine is
        the documented P2 carry (design §5).
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_leave_request")
          repo(unquote(repo))
        end

        attributes do
          attribute(:employee_id, :uuid, public?: true, allow_nil?: false)

          attribute(:kind, :atom,
            public?: true,
            allow_nil?: false,
            constraints: [one_of: [:vacation, :sick, :unpaid, :other]]
          )

          attribute(:start_date, :date, public?: true, allow_nil?: false)
          attribute(:end_date, :date, public?: true, allow_nil?: false)

          attribute(:status, :atom,
            public?: true,
            allow_nil?: false,
            default: :pending,
            constraints: [one_of: [:pending, :approved, :rejected, :cancelled]]
          )

          attribute(:decided_at, :utc_datetime, public?: true)
        end

        identities do
          identity(:unique_employee_leave, [:org_id, :employee_id, :start_date])
        end

        actions do
          defaults([:read, :destroy])

          create :create do
            accept([:org_id, :employee_id, :kind, :start_date, :end_date])
            primary?(true)
          end

          # Pre-decision cancel: the requester withdraws their own pending
          # request (the ADR-040 lifecycle: terminal states refuse).
          update :cancel do
            accept([])
            require_atomic?(false)
            change(Samen.Scopes.Hr.LeaveState)
          end

          update :reject do
            accept([])
            require_atomic?(false)
            change(Samen.Scopes.Hr.LeaveState)
          end

          # The gated transition: accept([]) — NO caller inputs (the Gate's
          # contract). The decision schedules the employee reminder fail-soft.
          update :approve do
            accept([])
            require_atomic?(false)

            change({Samen.Approvals.Gate,
             kind: unquote(Atom.to_string(module)) <> ":approve"})

            change(Samen.Scopes.Hr.LeaveState)
            change({Samen.Scopes.Hr.LeaveReminder, employee: unquote(employee_mod)})
          end
        end

        policies do
          policy action_type(:read) do
            authorize_if(Samen.Policy.OrgScope)
          end

          policy action_type([:create, :update, :destroy]) do
            forbid_unless(Samen.Policy.OrgScope)
            forbid_unless({Samen.Policy.RoleAtLeast, role: :member})
            authorize_if(always())
          end
        end
      end
    end
  end
end
