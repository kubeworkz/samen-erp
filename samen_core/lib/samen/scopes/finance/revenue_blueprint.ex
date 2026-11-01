defmodule Samen.Scopes.Finance.RevenueBlueprint do
  @moduledoc """
  Resource-definition macros for the Finance scope's **deferred revenue and its
  recognition schedules** (WS-ACCT Phase 6; ADR-054 D5, R9).

  Objects: `revenue_schedule` (the contract's deferred amount, its term and the
  method that releases it) + `revenue_recognition` (the per-period fact that
  released one slice, anchored to the journal entry it posted).

  ## Why the schedule is not a column on the invoice

  A schedule outlives the document it was born from: it spans periods, it is
  read on its own (what is left to recognize? what did March release?), and its
  method is a policy decision (`:straight_line` for a subscription,
  `:cost_incurred` for a grant). Putting `months` and a remaining balance on
  the invoice would make the AR document the accountant, and every revenue
  report a join back onto a billing table the ledger is not supposed to see.

  ## `recognized_to_date` is DERIVED, never a counter

  The design is explicit: `recognized_to_date` is Σ posted recognitions. There
  is no cached balance to drift, no increment to lose to a rolled-back
  transaction, no "recompute job" to forget. `recognized_cents` is an Ash
  aggregate over the recognitions, computed by the database at read time; the
  run computes `remaining` the same way. A double-recognition therefore cannot
  hide behind a stale counter -- and the only way to move the number is to post
  another recognition, which is exactly the event R9 reconciles.

  ## Exactly-once is layered

  * the run's `already_recognized?` read makes a repeated sweep a clean no-op;
  * the table's unique index on `{org, schedule, period}` refuses a duplicate
    row even below Ash.

  The second layer is the belt; the first is what makes the belt unnecessary in
  the normal case. `Samen.Scopes.Finance.RecognitionRun` documents the split.
  """

  # ---------------------------------------------------------------------------
  # RevenueSchedule — the contract's deferred amount and how it releases
  # ---------------------------------------------------------------------------
  defmacro define_revenue_schedule(
             module,
             otp_app,
             domain,
             repo,
             abbrev,
             recognition_mod,
             cost_object_mod
           ) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Finance.RevenueSchedule — one contract's deferred revenue and the rule
        that releases it (WS-ACCT Phase 6; ADR-054 D5).

          * `source_key`/`source_id` — the ADR-041 anchor to the document the
            schedule was born from (`"billing_invoice"`, `"grant"`, ...). It is
            the read path back to the AR document; the ledger never joins to
            it.
          * `total_cents`, `start_on`, `months` — the deferred amount, the
            first recognition month and the term. Only the MONTH of `start_on`
            matters; the run derives each period's key from it.
          * `method` — `:straight_line` (equal slices, the last one absorbing
            the division remainder so the term releases the total EXACTLY) or
            `:cost_incurred` (recognize as allowable cost is incurred, capped
            by what is left — never ahead of cost).
          * `deferred_key` — which `PostingAccount` meaning holds the deferred
            balance for this contract (`deferred_revenue` for customer
            contracts, `grant_deferred` for award revenue). Resolved
            fail-honest at posting time.
          * `cost_object_id` — the dimension whose incurred cost drives
            `:cost_incurred`; required for that method, optional otherwise.

        No status column: a schedule is done when `recognized_cents` reaches
        `total_cents`, which the answers can compute. A schedule is created
        once and never updated -- changing a contract after revenue has been
        recognized is an accounting decision (a credit note, a new schedule),
        not a row edit.

        No PII (INV-1): ids, integers, a date, two closed enums.
        """

        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_revenue_schedule")
          repo(unquote(repo))
        end

        attributes do
          attribute(:source_key, :string, public?: true)
          attribute(:source_id, :uuid, public?: true)
          attribute(:memo, :string, public?: true)

          attribute(:total_cents, :integer, public?: true, allow_nil?: false)
          attribute(:start_on, :date, public?: true, allow_nil?: false)

          attribute(:months, :integer, public?: true, allow_nil?: false)

          attribute(:method, :atom,
            public?: true,
            allow_nil?: false,
            default: :straight_line,
            constraints: [one_of: [:straight_line, :cost_incurred]]
          )

          attribute(:deferred_key, :atom,
            public?: true,
            allow_nil?: false,
            default: :deferred_revenue,
            constraints: [one_of: [:deferred_revenue, :grant_deferred]]
          )

          attribute(:cost_object_id, :uuid, public?: true)
        end

        relationships do
          has_many :recognitions, unquote(recognition_mod) do
            public?(true)
            destination_attribute(:schedule_id)
          end

          belongs_to :cost_object, unquote(cost_object_mod) do
            public?(true)
            attribute_type(:uuid)
            source_attribute(:cost_object_id)
            define_attribute?(false)
          end
        end

        aggregates do
          # The design's `recognized_to_date`, in cents: Σ posted recognitions.
          # A database aggregate, so it is computed at read time and cannot
          # drift from the rows it summarizes.
          sum :recognized_cents, :recognitions, field: :amount_cents
        end

        changes do
          # A nil `cost_object_id` is a no-op for SameOrgFk; a set one must
          # name this org's cost object (the ids-only dimension rule).
          change({Samen.Policy.SameOrgFk, relationships: [:cost_object]})
        end

        actions do
          read :read do
            primary?(true)
            pagination(keyset?: true, required?: false)
          end

          create :create do
            accept([
              :org_id,
              :source_key,
              :source_id,
              :memo,
              :total_cents,
              :start_on,
              :months,
              :method,
              :deferred_key,
              :cost_object_id
            ])

            validate(numericality(:total_cents, greater_than: 0))
            validate(numericality(:months, greater_than: 0))
            change(Samen.Scopes.Finance.ScheduleShape)
          end

          # NO update / destroy: see the moduledoc.
        end

        policies do
          policy action_type(:read) do
            authorize_if(Samen.Policy.OrgScope)
          end

          # A schedule commits revenue recognition for future periods -- the
          # admin rung, like the chart of accounts and the fiscal periods.
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
  # RevenueRecognition — one period's released slice, anchored to its entry
  # ---------------------------------------------------------------------------
  defmacro define_revenue_recognition(
             module,
             otp_app,
             domain,
             repo,
             abbrev,
             schedule_mod,
             entry_mod,
             posting_account_mod
           ) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Finance.RevenueRecognition — one period's recognition of a schedule's
        deferred revenue (WS-ACCT Phase 6; ADR-054 D5). `{schedule_id,
        period_key, amount_cents, recognized_on}` plus the journal entry the
        system cascade posts, anchored `source_key: "revenue_recognition"`,
        `source_id: <this row>`.

        APPEND-ONLY. A recognition is a fact about a period that has been
        reported; it is never edited and never deleted. The migration's trigger
        refuses UPDATE and DELETE outright (no marker escape: there is no
        legitimate rewrite of a recognition). A mistake is corrected the way the
        ledger corrects anything -- with a reversing entry -- not by mutating
        the record of what was recognized.

        The table's unique index on `{org, schedule, period}` is the exactly-once
        belt: one period releases once, even if two runs race. The caller-facing
        no-op is the run's `already_recognized?` read; this row is the fact.

        No PII (INV-1).
        """

        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_revenue_recognition")
          repo(unquote(repo))
        end

        attributes do
          # "YYYY-MM" — the fiscal month this slice belongs to. Text rather
          # than a date so a period is an identity, not a range that two rows
          # could disagree about.
          attribute(:period_key, :string, public?: true, allow_nil?: false)
          attribute(:amount_cents, :integer, public?: true, allow_nil?: false)
          attribute(:recognized_on, :date, public?: true, allow_nil?: false)
        end

        relationships do
          belongs_to :schedule, unquote(schedule_mod) do
            public?(true)
            attribute_type(:uuid)
            allow_nil?(false)
          end
        end

        changes do
          change({Samen.Policy.SameOrgFk, relationships: [:schedule]})
        end

        identities do
          identity(:unique_recognition_period, [:org_id, :schedule_id, :period_key])
        end

        actions do
          read :read do
            primary?(true)
            pagination(keyset?: true, required?: false)
          end

          # The system cascade's factory (RecognitionRun, `authorize?: false`):
          # creates the fact AND posts its deferred→income entry in ONE
          # transaction. Not a member-facing action -- the policy forbids it.
          create :recognize do
            accept([:org_id, :schedule_id, :period_key, :amount_cents, :recognized_on])

            validate(numericality(:amount_cents, greater_than: 0))

            change(
              {Samen.Scopes.Finance.RecognitionPosting,
               schedule: unquote(schedule_mod),
               entry: unquote(entry_mod),
               posting_account: unquote(posting_account_mod)}
            )
          end

          # NO update / destroy: see the moduledoc.
        end

        policies do
          policy action_type(:read) do
            authorize_if(Samen.Policy.OrgScope)
          end

          policy action(:recognize) do
            forbid_if(always())
          end
        end
      end
    end
  end
end
