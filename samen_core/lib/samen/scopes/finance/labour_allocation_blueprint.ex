defmodule Samen.Scopes.Finance.LabourAllocationBlueprint do
  @moduledoc """
  Resource-definition macros for the Finance scope's **labour allocation**
  (WS-ACCT Unit 10.2; ADR-054 D17).

  Objects: `labour_allocation` (a payroll period's total on one expense
  account, split across cost objects by approved timesheet MINUTES) and
  `labour_allocation_share` (one cost object's minutes and cents).

  ## The driver is the timesheet, not a declared ratio

  `Samen.Scopes.Finance.CostAllocation` takes a caller-declared basis driver
  for documents that carry no natural split. Payroll is different: the hours
  are already recorded, with a cost-object dimension, in the Work scope. This
  pair therefore does not accept drivers at all — `:draft` derives them from
  approved timesheets via `Samen.Scopes.Finance.LabourDriver`, and the split
  itself is `Samen.Scopes.Finance.AllocationMath` (largest remainder, exact).

  ## The total is declared; the split is derived

  Actual pay is not minutes × one rate (deductions, salaried staff, overtime),
  so the payroll total is the accountant's declared fact — accepted at `:draft`
  and never invented from hours. What is NOT accepted is the distribution: the
  shares, the minutes and the cents all come from the driver. A caller who
  wants a different split changes the approved timesheets, not the allocation.

  ## Drift is refused, not smoothed

  `:draft` freezes the driver into append-only shares. `:post` re-derives the
  driver from the same period and refuses `labour_drift` unless every cost
  object's minutes still match AND the shares still sum to the header. Hours
  approved after drafting therefore cannot move a posted split: the accountant
  re-drafts, exactly like `allocation_drift` in the cost allocator.

  ## The posting is ONE entry

  Per share: debit the target account, credit the source account, both tagged
  with the cost object on the allocation's axis. The source account (payroll
  expense) is cleared into WIP/COGS by programme; every cost object remains
  R6b-net-zero, and the payroll total moves once.
  """

  # ---------------------------------------------------------------------------
  # LabourAllocation — the header: one payroll period, one source account
  # ---------------------------------------------------------------------------
  defmacro define_labour_allocation(
             module,
             otp_app,
             domain,
             repo,
             abbrev,
             share_mod,
             timesheet_mod,
             timesheet_entry_mod,
             account_mod,
             entry_mod
           ) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Finance.LabourAllocation — one payroll period's cost, allocated across
        cost objects by approved timesheet minutes (WS-ACCT Unit 10.2;
        ADR-054 D17).

          * `period_start` / `period_end` — the payroll period the driver is
            read over. The posting lands on `period_end`.
          * `total_cents` — the DECLARED payroll total for the source account.
            Actual pay is not derivable from minutes; the split is.
          * `source_account_id` — the payroll expense account being cleared.
          * `target_account_id` — where the cost lands (WIP/COGS).
          * `axis` — the dimension key the cost objects ride (`:project` by
            default; the frozen vocabulary otherwise).
          * `status` — `:draft` until `:post` (final) or `:discard` (a withdrawn
            proposal, kept as evidence; its period slot is freed for a re-draft).
          * `entry_id` / `posted_at` — forced by the posting cascade.

        One LIVE allocation per (org, period, source account): the partial
        unique index is the belt, the drafting cascade names the existing row.
        Re-allocating the same payroll would double the reclass; a correction
        is a reversing entry. A discarded draft does not occupy the slot — that
        is what makes `labour_drift` actionable.

        No PII (INV-1): dates, integer cents, ids, one closed enum pair.
        """

        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_labour_allocation")
          repo(unquote(repo))
          identity_index_names(unique_payroll: "#{unquote(abbrev)}_payroll_unique")
        end

        attributes do
          attribute(:period_start, :date, public?: true, allow_nil?: false)
          attribute(:period_end, :date, public?: true, allow_nil?: false)

          attribute(:total_cents, :integer, public?: true, allow_nil?: false)

          attribute(:axis, :atom,
            public?: true,
            allow_nil?: false,
            default: :project,
            constraints: [one_of: [:project, :lot, :fund, :cost_pool]]
          )

          attribute(:status, :atom,
            public?: true,
            allow_nil?: false,
            default: :draft,
            constraints: [one_of: [:draft, :posted, :discarded]]
          )

          # Forced by the posting cascade; never accepted from a caller.
          attribute(:posted_at, :utc_datetime, public?: true)
        end

        relationships do
          belongs_to :source_account, unquote(account_mod) do
            public?(true)
            attribute_type(:uuid)
            allow_nil?(false)
          end

          belongs_to :target_account, unquote(account_mod) do
            public?(true)
            attribute_type(:uuid)
            allow_nil?(false)
          end

          belongs_to :entry, unquote(entry_mod) do
            public?(true)
            attribute_type(:uuid)
          end

          has_many :shares, unquote(share_mod) do
            public?(true)
            destination_attribute(:labour_allocation_id)
          end
        end

        identities do
          identity(:unique_payroll, [:org_id, :period_start, :period_end, :source_account_id])
        end

        changes do
          change(
            {Samen.Policy.SameOrgFk,
             relationships: [:source_account, :target_account, :entry]}
          )
        end

        actions do
          read :read do
            primary?(true)
            pagination(keyset?: true, required?: false)
          end

          # The proposal. Accepts the declared total and the two accounts —
          # NEVER the shares, the minutes or the cents.
          create :draft do
            accept([
              :org_id,
              :period_start,
              :period_end,
              :total_cents,
              :source_account_id,
              :target_account_id,
              :axis
            ])

            change(set_attribute(:status, :draft))
            validate(numericality(:total_cents, greater_than: 0))

            change(
              {Samen.Scopes.Finance.LabourAllocationDrafting,
               share: unquote(share_mod),
               timesheet: unquote(timesheet_mod),
               timesheet_entry: unquote(timesheet_entry_mod)}
            )
          end

          # The posting: ONE entry. NO caller inputs — the cascade re-derives
          # the driver and rebuilds every line from the persisted shares.
          update :post do
            accept([])
            require_atomic?(false)

            change(Samen.Scopes.Finance.PostingMarker)

            change(
              {Samen.Scopes.Finance.LabourAllocationPosting,
               share: unquote(share_mod),
               timesheet: unquote(timesheet_mod),
               timesheet_entry: unquote(timesheet_entry_mod),
               account: unquote(account_mod),
               entry: unquote(entry_mod)}
            )
          end

          # A draft is a proposal and may be withdrawn (the route a
          # `labour_drift` refusal points at). A posted row is final. The
          # shares of a discarded proposal are kept as evidence; the partial
          # unique index frees the period, so a re-draft is allowed.
          update :discard do
            accept([])
            require_atomic?(false)
            change(Samen.Scopes.Finance.LabourAllocationDiscard)
          end

          # NO update beyond the two gated transitions.
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
  # LabourAllocationShare — one cost object's minutes and derived cents
  # ---------------------------------------------------------------------------
  defmacro define_labour_allocation_share(
             module,
             otp_app,
             domain,
             repo,
             abbrev,
             allocation_mod,
             cost_object_mod
           ) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Finance.LabourAllocationShare — one cost object's slice of a labour
        allocation (WS-ACCT Unit 10.2; ADR-054 D17): the approved `minutes`
        the driver attributed to it, and the `allocated_cents` the exact split
        produced.

        APPEND-ONLY: the migration's trigger refuses UPDATE and DELETE. The
        minutes are the evidence behind the cents — a reviewer re-reads the
        approved timesheets and re-runs the split. `{allocation, cost_object}`
        is unique.

        `cost_object_id` is a same-org CostObject id (ids-only dimension rule);
        no PII (INV-1).
        """

        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_labour_allocation_share")
          repo(unquote(repo))
          identity_index_names(unique_target: "#{unquote(abbrev)}_target_unique")
        end

        attributes do
          # Approved timesheet minutes attributed to this cost object. The
          # basis quantity; money never rides this column.
          attribute(:minutes, :integer, public?: true, allow_nil?: false)

          attribute(:allocated_cents, :integer, public?: true, allow_nil?: false)
        end

        relationships do
          belongs_to :labour_allocation, unquote(allocation_mod) do
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
          change(
            {Samen.Policy.SameOrgFk, relationships: [:labour_allocation, :cost_object]}
          )
        end

        identities do
          identity(:unique_target, [:org_id, :labour_allocation_id, :cost_object_id])
        end

        actions do
          read :read do
            primary?(true)
            pagination(keyset?: true, required?: false)
          end

          # System materialization from the drafting cascade (authorize?: false).
          create :materialize do
            accept([
              :org_id,
              :labour_allocation_id,
              :cost_object_id,
              :minutes,
              :allocated_cents
            ])

            validate(numericality(:minutes, greater_than: 0))
            validate(numericality(:allocated_cents, greater_than: 0))
          end

          # NO update / destroy: see the moduledoc.
        end

        policies do
          policy action_type(:read) do
            authorize_if(Samen.Policy.OrgScope)
          end

          policy action(:materialize) do
            forbid_if(always())
          end
        end
      end
    end
  end
end
