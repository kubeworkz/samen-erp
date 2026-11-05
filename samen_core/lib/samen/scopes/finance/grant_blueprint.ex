defmodule Samen.Scopes.Finance.GrantBlueprint do
  @moduledoc """
  Resource-definition macros for the Finance scope's **grants and restricted
  funds** (WS-ACCT Phase 11; ADR-054 D8, R11).

  Objects: `grant` (the award document), `grant_milestone` (a due date and the
  amount expected against it), `grant_claim` (a claim for allowable cost, with
  its evidence), `grant_opportunity` (the application tracker) and
  `grant_personnel` (the effort allocation the compliance report resolves).

  ## A grant is a document plus a fund dimension

  There is no fund-accounting subsystem. `grant.fund_cost_object_id` names the
  `CostObject(kind: :fund)` every posting for the award is dimensioned with;
  the award receipt posts Dr cash / Cr `grant_deferred`, and the existing
  `RevenueSchedule` machinery (`method: :cost_incurred`, `deferred_key:
  :grant_deferred`) releases that liability to income as allowable cost is
  incurred. `:open_recognition` creates that schedule; the monthly
  `RecognitionRun` owns the posting. The grant budget reuses
  `Budget`/`BudgetLine` through `budget_id` — the grant never re-declares a
  plan.

  ## Claimed cost is evidenced, not invented

  `GrantClaim` carries the claimed amount and the evidence file ids. Only an
  APPROVED claim counts toward R11; a submitted claim is a proposal. Approval
  is admin-gated, and a claim is decided once (submitted → approved/rejected).

  ## Personnel is an id, never a name

  `GrantPersonnel` stores the opaque HR employee id and an effort percentage.
  The compliance read resolves the person through
  `Samen.Api.PiiResolution` on the caller's plane — the same seam every PII
  surface uses — so a tenant sees the name and an operator without a grant
  sees `••••`. Finance never re-declares the person (design §4).

  No resource here carries a vault-routed column; the only PII is the HR
  record the report is allowed to resolve.
  """

  # ---------------------------------------------------------------------------
  # Grant — the award document
  # ---------------------------------------------------------------------------
  defmacro define_grant(
             module,
             otp_app,
             domain,
             repo,
             abbrev,
             milestone_mod,
             claim_mod,
             personnel_mod,
             budget_mod,
             cost_object_mod,
             schedule_mod,
             entry_mod,
             posting_account_mod
           ) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Finance.Grant — one award (WS-ACCT Phase 11; ADR-054 D8).

          * `award_cents` and `period_start`/`period_end` are the award's fact;
            `:open_recognition` derives the term in months from the period and
            creates the `:cost_incurred` revenue schedule.
          * `fund_cost_object_id` names the `CostObject(kind: :fund)` every
            grant posting is dimensioned with. It is required: a grant without
            a fund cannot reconcile (R11).
          * `budget_id` reuses the host's `Budget`; nil means the grant has no
            budget yet (the compliance read reports zero planned).
          * `status` is `:awarded` → `:active` (on receipt) → `:closed`
            (one-way). `received_on`/`closed_on` are set by their actions, never
            accepted from a caller.

        `:receive_award` posts Dr cash / Cr `grant_deferred` for the award,
        dimensioned to the fund, anchored `source_key: "grant_award"`. It is
        idempotent by refusal: a second receipt is an error, never a second
        posting. `:open_recognition` creates the schedule once; a second call
        refuses.

        No PII (INV-1): names, dates, integers, ids.
        """

        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_grant")
          repo(unquote(repo))
        end

        attributes do
          attribute(:funder, :string,
            public?: true,
            allow_nil?: false,
            constraints: [max_length: 160]
          )

          attribute(:program, :string,
            public?: true,
            allow_nil?: false,
            constraints: [max_length: 160]
          )

          attribute(:award_ref, :string,
            public?: true,
            allow_nil?: false,
            constraints: [max_length: 80]
          )

          attribute(:award_cents, :integer, public?: true, allow_nil?: false)
          attribute(:period_start, :date, public?: true, allow_nil?: false)
          attribute(:period_end, :date, public?: true, allow_nil?: false)
          attribute(:restricted, :boolean, public?: true, allow_nil?: false, default: true)

          attribute(:status, :atom,
            public?: true,
            allow_nil?: false,
            default: :awarded,
            constraints: [one_of: [:awarded, :active, :closed]]
          )

          attribute(:received_on, :date, public?: true)
          attribute(:closed_on, :date, public?: true)

          attribute(:budget_id, :uuid, public?: true)
          attribute(:fund_cost_object_id, :uuid, public?: true, allow_nil?: false)
          attribute(:schedule_id, :uuid, public?: true)
        end

        relationships do
          belongs_to :budget, unquote(budget_mod) do
            public?(true)
            attribute_type(:uuid)
            source_attribute(:budget_id)
            define_attribute?(false)
          end

          belongs_to :fund_cost_object, unquote(cost_object_mod) do
            public?(true)
            attribute_type(:uuid)
            source_attribute(:fund_cost_object_id)
            define_attribute?(false)
          end

          belongs_to :schedule, unquote(schedule_mod) do
            public?(true)
            attribute_type(:uuid)
            source_attribute(:schedule_id)
            define_attribute?(false)
          end

          has_many :milestones, unquote(milestone_mod) do
            public?(true)
            destination_attribute(:grant_id)
          end

          has_many :claims, unquote(claim_mod) do
            public?(true)
            destination_attribute(:grant_id)
          end

          has_many :personnel, unquote(personnel_mod) do
            public?(true)
            destination_attribute(:grant_id)
          end
        end

        changes do
          # Nil budget/schedule are no-ops; a set one must name this org's row.
          change({Samen.Policy.SameOrgFk, relationships: [:budget, :fund_cost_object, :schedule]})

          change({Samen.Scopes.Finance.GrantShape, cost_object: unquote(cost_object_mod)})
        end

        actions do
          read :read do
            primary?(true)
            pagination(keyset?: true, required?: false)
          end

          create :create do
            primary?(true)

            accept([
              :org_id,
              :funder,
              :program,
              :award_ref,
              :award_cents,
              :period_start,
              :period_end,
              :restricted,
              :budget_id,
              :fund_cost_object_id
            ])
          end

          # The restricted receipt (JE-070): Dr cash / Cr grant_deferred, both
          # lines dimensioned to the grant's fund. Second receipt refused.
          update :receive_award do
            accept([])
            require_atomic?(false)

            change(
              {Samen.Scopes.Finance.GrantAwardPosting,
               entry: unquote(entry_mod), posting_account: unquote(posting_account_mod)}
            )
          end

          # Open the :cost_incurred recognition schedule — once. The monthly
          # RecognitionRun owns every later posting.
          update :open_recognition do
            accept([])
            require_atomic?(false)

            change(
              {Samen.Scopes.Finance.GrantRecognitionOpening, schedule: unquote(schedule_mod)}
            )
          end

          update :close do
            accept([])
            require_atomic?(false)
            change(Samen.Scopes.Finance.GrantClose)
          end
        end

        policies do
          policy action_type(:read) do
            authorize_if(Samen.Policy.OrgScope)
          end

          # An award commits restricted money and changes the ledger — admin.
          policy action_type([:create, :update, :destroy]) do
            forbid_unless(Samen.Policy.OrgScope)
            forbid_unless({Samen.Policy.RoleAtLeast, role: :admin})
            authorize_if(always())
          end
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # GrantMilestone — a due date and the amount expected against it
  # ---------------------------------------------------------------------------
  defmacro define_grant_milestone(module, otp_app, domain, repo, abbrev, grant_mod) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Finance.GrantMilestone — a grant's due date and the amount expected
        against it (WS-ACCT Phase 11; ADR-054 D8). `status` is `:planned` →
        `:met`/`:waived`; a claim may name the milestone it satisfies.

        No PII (INV-1).
        """

        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_grant_milestone")
          repo(unquote(repo))
        end

        attributes do
          attribute(:name, :string,
            public?: true,
            allow_nil?: false,
            constraints: [max_length: 160]
          )

          attribute(:due_on, :date, public?: true, allow_nil?: false)
          attribute(:amount_cents, :integer, public?: true, allow_nil?: false)

          attribute(:status, :atom,
            public?: true,
            allow_nil?: false,
            default: :planned,
            constraints: [one_of: [:planned, :met, :waived]]
          )

          attribute(:completed_on, :date, public?: true)
        end

        relationships do
          belongs_to :grant, unquote(grant_mod) do
            public?(true)
            attribute_type(:uuid)
            allow_nil?(false)
          end
        end

        changes do
          change({Samen.Policy.SameOrgFk, relationships: [:grant]})
        end

        identities do
          identity(:unique_milestone_name, [:org_id, :grant_id, :name])
        end

        actions do
          read :read do
            primary?(true)
            pagination(keyset?: true, required?: false)
          end

          create :create do
            primary?(true)
            accept([:org_id, :grant_id, :name, :due_on, :amount_cents, :status, :completed_on])
            validate(numericality(:amount_cents, greater_than: 0))
          end

          update :update do
            accept([:name, :due_on, :amount_cents, :status, :completed_on])
            require_atomic?(false)
            validate(numericality(:amount_cents, greater_than: 0))
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

  # ---------------------------------------------------------------------------
  # GrantClaim — a claim for allowable cost, with evidence
  # ---------------------------------------------------------------------------
  defmacro define_grant_claim(module, otp_app, domain, repo, abbrev, grant_mod, milestone_mod) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Finance.GrantClaim — one claim against a grant (WS-ACCT Phase 11;
        ADR-054 D8): `claimed_on`, `amount_cents`, the evidence file ids and the
        milestone it satisfies (optional).

        Only an APPROVED claim counts toward R11. `:submit` is a member's
        proposal; `:approve`/`:reject` are admin decisions, and a claim is
        decided once. The evidence ids are opaque file ids — Finance never
        re-declares a document.

        No PII (INV-1).
        """

        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_grant_claim")
          repo(unquote(repo))
        end

        attributes do
          attribute(:claimed_on, :date, public?: true, allow_nil?: false)
          attribute(:amount_cents, :integer, public?: true, allow_nil?: false)

          attribute(:evidence_files, {:array, :uuid},
            public?: true,
            allow_nil?: false,
            default: []
          )

          attribute(:status, :atom,
            public?: true,
            allow_nil?: false,
            default: :submitted,
            constraints: [one_of: [:submitted, :approved, :rejected]]
          )

          attribute(:approved_on, :date, public?: true)
        end

        relationships do
          belongs_to :grant, unquote(grant_mod) do
            public?(true)
            attribute_type(:uuid)
            allow_nil?(false)
          end

          belongs_to :milestone, unquote(milestone_mod) do
            public?(true)
            attribute_type(:uuid)
          end
        end

        changes do
          change({Samen.Policy.SameOrgFk, relationships: [:grant, :milestone]})
        end

        actions do
          read :read do
            primary?(true)
            pagination(keyset?: true, required?: false)
          end

          create :submit do
            primary?(true)

            accept([
              :org_id,
              :grant_id,
              :milestone_id,
              :claimed_on,
              :amount_cents,
              :evidence_files
            ])

            validate(numericality(:amount_cents, greater_than: 0))
          end

          update :approve do
            accept([])
            require_atomic?(false)
            change({Samen.Scopes.Finance.GrantClaimDecision, decision: :approved})
          end

          update :reject do
            accept([])
            require_atomic?(false)
            change({Samen.Scopes.Finance.GrantClaimDecision, decision: :rejected})
          end
        end

        policies do
          policy action_type(:read) do
            authorize_if(Samen.Policy.OrgScope)
          end

          policy action(:submit) do
            forbid_unless(Samen.Policy.OrgScope)
            forbid_unless({Samen.Policy.RoleAtLeast, role: :member})
            authorize_if(always())
          end

          policy action([:approve, :reject]) do
            forbid_unless(Samen.Policy.OrgScope)
            forbid_unless({Samen.Policy.RoleAtLeast, role: :admin})
            authorize_if(always())
          end
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # GrantOpportunity — the application tracker
  # ---------------------------------------------------------------------------
  defmacro define_grant_opportunity(module, otp_app, domain, repo, abbrev) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Finance.GrantOpportunity — the grant application tracker (WS-ACCT Phase
        11; ADR-054 D8): a deadline-driven pipeline row with its own stages.
        CRM `Opportunity` remains the sales pipeline's source of truth; this is
        deliberately a separate, small record.

        No PII (INV-1): names, a closed stage, dates, integers.
        """

        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_grant_opportunity")
          repo(unquote(repo))
        end

        attributes do
          attribute(:funder, :string,
            public?: true,
            allow_nil?: false,
            constraints: [max_length: 160]
          )

          attribute(:program, :string,
            public?: true,
            allow_nil?: false,
            constraints: [max_length: 160]
          )

          attribute(:stage, :atom,
            public?: true,
            allow_nil?: false,
            default: :identified,
            constraints: [one_of: [:identified, :applied, :awarded, :declined]]
          )

          attribute(:deadline, :date, public?: true)
          attribute(:amount_cents, :integer, public?: true, allow_nil?: false, default: 0)
          attribute(:probability, :integer, public?: true, allow_nil?: false, default: 0)
        end

        actions do
          read :read do
            primary?(true)
            pagination(keyset?: true, required?: false)
          end

          create :create do
            primary?(true)

            accept([
              :org_id,
              :funder,
              :program,
              :stage,
              :deadline,
              :amount_cents,
              :probability
            ])

            validate(numericality(:amount_cents, greater_than_or_equal_to: 0))

            validate(
              numericality(:probability, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
            )
          end

          update :update do
            accept([:funder, :program, :stage, :deadline, :amount_cents, :probability])
            require_atomic?(false)
            validate(numericality(:amount_cents, greater_than_or_equal_to: 0))

            validate(
              numericality(:probability, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
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

  # ---------------------------------------------------------------------------
  # GrantPersonnel — effort by an opaque HR employee id
  # ---------------------------------------------------------------------------
  defmacro define_grant_personnel(module, otp_app, domain, repo, abbrev, grant_mod) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Finance.GrantPersonnel — one employee's effort on a grant (WS-ACCT
        Phase 11; ADR-054 D8/§4). `employee_id` is an opaque HR id; Finance
        never re-declares the person. The compliance report resolves the name
        through `Samen.Api.PiiResolution` on the caller's plane.

        No PII column here (INV-1): an id, an integer percentage, a date.
        """

        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_grant_personnel")
          repo(unquote(repo))
        end

        attributes do
          attribute(:employee_id, :uuid, public?: true, allow_nil?: false)
          attribute(:effort_pct, :integer, public?: true, allow_nil?: false)
          attribute(:effective_on, :date, public?: true, allow_nil?: false)
        end

        relationships do
          belongs_to :grant, unquote(grant_mod) do
            public?(true)
            attribute_type(:uuid)
            allow_nil?(false)
          end
        end

        changes do
          change({Samen.Policy.SameOrgFk, relationships: [:grant]})
        end

        identities do
          identity(:unique_effort, [:org_id, :grant_id, :employee_id, :effective_on])
        end

        actions do
          read :read do
            primary?(true)
            pagination(keyset?: true, required?: false)
          end

          create :create do
            primary?(true)
            accept([:org_id, :grant_id, :employee_id, :effort_pct, :effective_on])
            validate(numericality(:effort_pct, greater_than: 0, less_than_or_equal_to: 100))
          end

          update :update do
            accept([:effort_pct, :effective_on])
            require_atomic?(false)
            validate(numericality(:effort_pct, greater_than: 0, less_than_or_equal_to: 100))
          end

          destroy :destroy do
            primary?(true)
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
