defmodule Samen.Scopes.Work.TimesheetBlueprint do
  @moduledoc """
  Resource-definition macros for **timesheet capture** in the Work scope
  (WS-ACCT Unit 10.2; ADR-054 D17).

  Objects: `timesheet` (one employee's weekly/monthly capture, with the
  draft → submitted → approved lifecycle) and `timesheet_entry` (one day's
  minutes against ONE `CostObject`).

  ## Why this is authored here, fresh

  The manual dimensions design-engineering labour by chip, and the only
  truthful source for that split is actual hours. ADR-055 §6 deleted the
  dormant E15 `timesheet_*` stubs (unmigrated, unreferenced, untested), so
  there is no head start to wire; these resources are authored against the
  shipped Work scope instead.

  ## Only APPROVED timesheets are a labour fact

  `:submit` requires at least one entry; `:approve` only matches a submitted
  sheet; an approved sheet is final (the DB trigger refuses any further
  update). Entries are writable ONLY while their sheet is a draft — enforced
  in Ash (`Samen.Scopes.Work.TimesheetEntryGuard`) and at the database (the
  trigger). The labour driver
  (`Samen.Scopes.Finance.LabourDriver`) reads **approved** sheets only, so
  unapproved hours can never move payroll cost.

  ## The cost-object dimension

  `timesheet_entry.cost_object_id` is required and same-org: the mount passes
  the host's Finance `CostObject` module (`timesheets: [cost_object: ...]`), so
  an entry can never name a foreign or invented programme. Ids only, never
  names — the same de-anonymisation posture as `JournalLine.dimension_refs`.

  ## No PII

  `employee_id` is an opaque HR id (plain uuid, exactly like Work's `owner_id`
  — HR is not mounted here and the scope never re-declares a person).
  `note`/`minutes`/dates are non-PII; no field is vault-routed.
  """

  # ---------------------------------------------------------------------------
  # Timesheet — the capture header and its one-way lifecycle
  # ---------------------------------------------------------------------------
  defmacro define_timesheet(module, otp_app, domain, repo, abbrev, entry_mod) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Work.Timesheet — one employee's time capture for a period (WS-ACCT
        Unit 10.2; ADR-054 D17).

          * `employee_id` — an opaque HR id (plain uuid; HR is not mounted in
            this scope and the person is never re-declared).
          * `period_start` / `period_end` — the capture window. Every entry's
            `worked_on` must fall inside it.
          * `status` — `:draft` (editable), `:submitted` (waiting for
            approval), `:approved` (a labour fact; final). One-way: there is no
            reopen and no destroy.
          * `submitted_at` / `approved_at` — forced by the transitions.

        Only approved sheets feed the labour driver. A sheet with no entries
        cannot be submitted, and an approved sheet can never be edited again
        (the DB trigger is the belt).

        No PII (INV-1): an opaque employee id, dates and two closed enums.
        """

        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_timesheet")
          repo(unquote(repo))
          identity_index_names(unique_period: "#{unquote(abbrev)}_period_unique")
        end

        attributes do
          attribute(:employee_id, :uuid, public?: true, allow_nil?: false)
          attribute(:period_start, :date, public?: true, allow_nil?: false)
          attribute(:period_end, :date, public?: true, allow_nil?: false)

          attribute(:status, :atom,
            public?: true,
            allow_nil?: false,
            default: :draft,
            constraints: [one_of: [:draft, :submitted, :approved]]
          )

          attribute(:submitted_at, :utc_datetime, public?: true)
          attribute(:approved_at, :utc_datetime, public?: true)
        end

        relationships do
          has_many :entries, unquote(entry_mod) do
            public?(true)
            destination_attribute(:timesheet_id)
          end
        end

        identities do
          identity(:unique_period, [:org_id, :employee_id, :period_start])
        end

        changes do
          change(Samen.Scopes.Work.TimesheetShape)
        end

        actions do
          read :read do
            primary?(true)
            pagination(keyset?: true, required?: false)
          end

          # The capture. A sheet is born a draft; `status` is not an accepted
          # input — the only route to submitted/approved is the transitions.
          create :create do
            accept([:org_id, :employee_id, :period_start, :period_end])
            change(set_attribute(:status, :draft))
          end

          # Draft → submitted. Requires at least one entry (a blank sheet is
          # not a submission).
          update :submit do
            accept([])
            require_atomic?(false)
            change({Samen.Scopes.Work.TimesheetTransition, to: :submitted, entry: unquote(entry_mod)})
          end

          # Submitted → approved. The approval is what makes the hours a
          # labour fact; only this status feeds the payroll driver.
          update :approve do
            accept([])
            require_atomic?(false)
            change({Samen.Scopes.Work.TimesheetTransition, to: :approved})
          end

          # NO update / destroy: a timesheet is a governed capture, and an
          # approved one is a reported fact.
        end

        policies do
          policy action_type(:read) do
            authorize_if(Samen.Policy.OrgScope)
          end

          # An employee captures and submits; a manager approves.
          policy action([:create, :submit]) do
            forbid_unless(Samen.Policy.OrgScope)
            forbid_unless({Samen.Policy.RoleAtLeast, role: :member})
            authorize_if(always())
          end

          policy action(:approve) do
            forbid_unless(Samen.Policy.OrgScope)
            forbid_unless({Samen.Policy.RoleAtLeast, role: :admin})
            authorize_if(always())
          end
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # TimesheetEntry — one day's minutes against one cost object
  # ---------------------------------------------------------------------------
  defmacro define_timesheet_entry(
             module,
             otp_app,
             domain,
             repo,
             abbrev,
             timesheet_mod,
             cost_object_mod
           ) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Work.TimesheetEntry — one day's minutes against ONE cost object
        (WS-ACCT Unit 10.2; ADR-054 D17).

          * `timesheet_id` — the owning capture (same org).
          * `worked_on` — the day; must fall inside the sheet's period.
          * `minutes` — actual time, integer minutes (never a rounded hour and
            never a decimal — the driver's arithmetic is exact).
          * `cost_object_id` — the programme/pool the time belongs to. REQUIRED
            and same-org: a time entry with no cost object cannot drive payroll
            cost anywhere.
          * `note` — freeform, default-deny-CDC-excluded, not vaulted.

        Writable ONLY while the parent sheet is a draft (Ash guard + DB trigger);
        a submitted/approved sheet's entries are frozen so the approved hours
        the payroll was allocated on cannot move afterwards.

        No PII (INV-1).
        """

        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_timesheet_entry")
          repo(unquote(repo))
        end

        attributes do
          attribute(:worked_on, :date, public?: true, allow_nil?: false)
          attribute(:minutes, :integer, public?: true, allow_nil?: false)
          attribute(:note, :string, public?: true)
        end

        relationships do
          belongs_to :timesheet, unquote(timesheet_mod) do
            public?(true)
            attribute_type(:uuid)
            allow_nil?(false)
          end

          belongs_to :cost_object, unquote(cost_object_mod) do
            public?(true)
            attribute_type(:uuid)
            allow_nil?(false)
          end
        end

        changes do
          change({Samen.Policy.SameOrgFk, relationships: [:timesheet, :cost_object]})

          change(
            {Samen.Scopes.Work.TimesheetEntryGuard, timesheet: unquote(timesheet_mod)}
          )
        end

        actions do
          read :read do
            primary?(true)
            pagination(keyset?: true, required?: false)
          end

          create :create do
            accept([:org_id, :timesheet_id, :worked_on, :minutes, :cost_object_id, :note])
            validate(numericality(:minutes, greater_than: 0))
          end

          update :update do
            accept([:worked_on, :minutes, :cost_object_id, :note])
            require_atomic?(false)
            validate(numericality(:minutes, greater_than: 0))
          end

          destroy :destroy do
            require_atomic?(false)

            # Resource-level changes are not run for destroy; the freeze must
            # cover deletes too, or a submitted sheet's evidence could vanish.
            change(
              {Samen.Scopes.Work.TimesheetEntryGuard, timesheet: unquote(timesheet_mod)}
            )
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
