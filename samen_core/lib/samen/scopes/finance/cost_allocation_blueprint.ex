defmodule Samen.Scopes.Finance.CostAllocationBlueprint do
  @moduledoc """
  Resource-definition macros for the Finance scope's **reusable allocation
  step** (WS-ACCT Phase 10; ADR-054 decision 11).

  Objects: `cost_allocation` (one AP bill's cost on one expense account, split
  across N cost objects by a declared basis) and `cost_allocation_share` (the
  per-target driver and cents that split produced).

  ## One step, not per-document arithmetic

  The manual's MPW policy asks one question — "how is the cost of a single
  shuttle split across the chip designs that shared it?" — and the answer is
  the same arithmetic whether the basis is die area, wafer count or effort.
  This pair is that step: a caller declares the targets and their drivers, and
  the scope derives every cent. It generalises the shipped E14 landed-cost
  allocator's *pattern* (proportional shares, refusal when the split does not
  tie) without reaching into that dormant set, and it is Finance-side: the
  result is a governed journal entry, not an inventory cost layer.

  ## The shares are the fact, the header is the declaration

  A journal entry has accounts and amounts; it cannot say "RISC-V64's 52% of
  the mask set, by die area". The shares carry the driver AND the cents, so a
  reviewer can re-run the arithmetic. They are append-only: once a proposal
  exists, its split is not editable — a wrong basis is a new allocation after
  a reversal, exactly like every other posted fact in this scope.

  ## The posting is ONE entry

  `:post` lands a single entry whose lines are per-target pairs (debit the
  target account, credit the source account, both tagged with the target's
  cost object). That is what makes the allocation dimension-only: each cost
  object nets to zero (R6b), the accounts move the invoice's cost once, and N
  targets never become N posts. `Samen.Scopes.Finance.CostAllocationPosting`
  owns the cascade; `Samen.Scopes.Finance.AllocationMath` owns the cents.
  """

  # ---------------------------------------------------------------------------
  # CostAllocation — the header: one bill, one source account, N targets
  # ---------------------------------------------------------------------------
  defmacro define_cost_allocation(
             module,
             otp_app,
             domain,
             repo,
             abbrev,
             invoice_mod,
             share_mod,
             account_mod,
             entry_mod
           ) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Finance.CostAllocation — one AP bill's cost on one expense account,
        allocated across N cost objects (WS-ACCT Phase 10; ADR-054 decision 11).

          * `ap_invoice_id` — the bill whose cost is being reclassified. It must
            be approved/paid and carry a posting entry; a draft has nothing to
            allocate.
          * `source_account_id` — the bill line's account the credit leg pays.
            Derived by the drafting cascade (the bill's single line account), or
            declared when the bill names several.
          * `target_account_id` — the account the cost lands in (WIP, usually).
          * `basis` — the DECLARED driver unit: `:die_area`, `:wafer` or
            `:effort`. Recorded for the audit; the arithmetic uses the shares'
            drivers, which are basis quantities, never money.
          * `axis` — which dimension key tags the entry (`:project` by default —
            the axis the programmes live under; the frozen vocabulary otherwise).
          * `allocated_on` — the reclass date, and the date the entry posts on.
          * `status` — `:draft` until `:post`; a posted allocation is final.
          * `amount_cents` — DERIVED from the bill, never accepted from a
            caller; `entry_id`/`posted_at` are forced by the posting cascade.

        No PII (INV-1): ids, one closed enum pair, a date, integer cents.
        """

        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_cost_allocation")
          repo(unquote(repo))
        end

        attributes do
          attribute(:allocated_on, :date, public?: true, allow_nil?: false)

          attribute(:basis, :atom,
            public?: true,
            allow_nil?: false,
            constraints: [one_of: [:die_area, :wafer, :effort]]
          )

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
            constraints: [one_of: [:draft, :posted]]
          )

          # Forced by the cascades; never accepted from a caller.
          attribute(:amount_cents, :integer, public?: true)
          attribute(:posted_at, :utc_datetime, public?: true)
        end

        relationships do
          belongs_to :ap_invoice, unquote(invoice_mod) do
            public?(true)
            attribute_type(:uuid)
            allow_nil?(false)
          end

          # Nullable at the ASH layer because `:draft` DERIVES it from the
          # bill's line when the caller does not declare it; the drafting
          # cascade always forces a value, and the table's NOT NULL is the
          # belt. Making it required here would refuse the intended call shape
          # before the cascade ever runs.
          belongs_to :source_account, unquote(account_mod) do
            public?(true)
            attribute_type(:uuid)
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
            destination_attribute(:cost_allocation_id)
          end
        end

        identities do
          identity(:unique_allocation, [:org_id, :ap_invoice_id, :source_account_id])
        end

        changes do
          change(
            {Samen.Policy.SameOrgFk,
             relationships: [:ap_invoice, :source_account, :target_account, :entry]}
          )
        end

        actions do
          read :read do
            primary?(true)
            pagination(keyset?: true, required?: false)
          end

          # The proposal. Accepts NO amounts: the cascade resolves the bill's
          # line, splits it, forces the header total, and materializes the
          # shares in this action's transaction.
          create :draft do
            accept([
              :org_id,
              :ap_invoice_id,
              :basis,
              :allocated_on,
              :axis,
              :target_account_id,
              :source_account_id
            ])

            argument(:shares, {:array, :map},
              allow_nil?: false,
              constraints: [
                items: [
                  fields: [
                    cost_object_id: [type: :uuid, allow_nil?: false],
                    driver: [type: :integer, allow_nil?: false]
                  ]
                ]
              ]
            )

            change(set_attribute(:status, :draft))

            change(
              {Samen.Scopes.Finance.CostAllocationDrafting,
               invoice: unquote(invoice_mod), share: unquote(share_mod)}
            )
          end

          # The posting: ONE entry for the whole split. NO caller inputs — the
          # cascade re-derives every line from the persisted shares.
          update :post do
            accept([])
            require_atomic?(false)

            # The outer arm: the posted-born entry's own PostGuard restores the
            # marker BEFORE EntryLines inserts its rows, so the action that
            # drives the posting must hold the marker armed (the AP/PO approve
            # precedent). The restore is prior-value-safe under nesting.
            change(Samen.Scopes.Finance.PostingMarker)

            change(
              {Samen.Scopes.Finance.CostAllocationPosting,
               invoice: unquote(invoice_mod),
               share: unquote(share_mod),
               account: unquote(account_mod),
               entry: unquote(entry_mod)}
            )
          end

          # NO update / destroy beyond the gated transition: a posted
          # allocation is a reported fact.
        end

        policies do
          policy action_type(:read) do
            authorize_if(Samen.Policy.OrgScope)
          end

          # An accountant drafts and posts (the journal-entry rung). The basis
          # and the targets are declared here; the cents are derived.
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
  # CostAllocationShare — one target's driver and derived cents
  # ---------------------------------------------------------------------------
  defmacro define_cost_allocation_share(
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
        Finance.CostAllocationShare — one cost object's slice of an allocation
        (WS-ACCT Phase 10; ADR-054 decision 11): the declared basis `driver`,
        and the `allocated_cents` the largest-remainder split produced.

        APPEND-ONLY: the migration's trigger refuses UPDATE and DELETE. The
        split is evidence — a reviewer re-runs `amount * driver / total` and
        compares. `{allocation, cost_object}` is unique, so one target cannot
        absorb two slices of the same allocation.

        `cost_object_id` is a same-org CostObject id (the ids-only dimension
        rule); no PII (INV-1).
        """

        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_cost_allocation_share")
          repo(unquote(repo))
        end

        attributes do
          # The basis quantity: die-area units, wafers or effort hours. Only
          # its proportion matters; money never rides this column.
          attribute(:driver, :integer, public?: true, allow_nil?: false)

          # The cents the split gave this target.
          attribute(:allocated_cents, :integer, public?: true, allow_nil?: false)
        end

        relationships do
          belongs_to :cost_allocation, unquote(allocation_mod) do
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
            {Samen.Policy.SameOrgFk, relationships: [:cost_allocation, :cost_object]}
          )
        end

        identities do
          identity(:unique_target, [:org_id, :cost_allocation_id, :cost_object_id])
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
              :cost_allocation_id,
              :cost_object_id,
              :driver,
              :allocated_cents
            ])

            validate(numericality(:driver, greater_than: 0))
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
