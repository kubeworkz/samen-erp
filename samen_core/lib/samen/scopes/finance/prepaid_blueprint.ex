defmodule Samen.Scopes.Finance.PrepaidBlueprint do
  @moduledoc """
  Resource-definition macros for the Finance scope's **prepaid expense
  schedules and their releases** (WS-ACCT prepaid expense slice).

  Objects: `prepaid_schedule` — a prepaid contract's total, term and the two
  accounts every release uses — plus `prepaid_release` — the per-period fact
  that one slice was released, anchored to the journal entry it posted.

  ## No schedule table

  The schedule is derived from `{total_cents, months, start_on}` by
  `Samen.Scopes.Finance.PrepaidSchedule`. The only persisted per-period fact is
  `PrepaidRelease`; the register and the audit can rebuild every number from
  the contract plus Σ releases.

  ## Accounts are named, not invented

  Unlike deferred revenue (which resolves a posting meaning), a prepaid
  schedule names the actual same-org prepaid asset account and the release
  target (an expense or WIP asset account). That is the AP-line precedent:
  the host's chart is data, and the release row keeps the account ids it
  actually paid. `PrepaidShape` refuses the wrong side/kind at create time.
  """

  # ---------------------------------------------------------------------------
  # PrepaidSchedule — the contract and how it releases
  # ---------------------------------------------------------------------------
  defmacro define_prepaid_schedule(
             module,
             otp_app,
             domain,
             repo,
             abbrev,
             release_mod,
             account_mod,
             cost_object_mod
           ) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Finance.PrepaidSchedule — one prepaid expense and the straight-line
        contract that releases it (WS-ACCT prepaid expense slice).

          * `code`/`name`/`memo` — the register's human identity; `code` is
            unique per org.
          * `total_cents`, `start_on`, `months` — the contract. The monthly
            slice is derived; the last month absorbs the division remainder.
          * `prepaid_account_id` — the debit-normal asset account being
            released (1200/1210 in the Kubeworkz books).
          * `expense_account_id` — the debit-normal expense or asset (WIP)
            target of the release.
          * `cost_object_id` / `dimension_key` — the optional programme
            dimension both release legs carry (R6).
          * `source_key`/`source_id` — the optional ADR-041 anchor to the
            document that created the prepayment.

        No status column: a schedule is complete when `released_cents` reaches
        `total_cents`, which the register derives. A schedule is created once
        and never updated; changing a contract after money has been released is
        an accounting decision (a new schedule or a correcting entry), not a
        row edit.

        No PII (INV-1): ids, integers, dates, one closed method/dimension enum.
        """

        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_prepaid_schedule")
          repo(unquote(repo))
        end

        attributes do
          attribute(:code, :string, public?: true, allow_nil?: false)
          attribute(:name, :string, public?: true, allow_nil?: false)
          attribute(:memo, :string, public?: true)
          attribute(:source_key, :string, public?: true)
          attribute(:source_id, :uuid, public?: true)

          attribute(:total_cents, :integer, public?: true, allow_nil?: false)
          attribute(:start_on, :date, public?: true, allow_nil?: false)
          attribute(:months, :integer, public?: true, allow_nil?: false)

          attribute(:method, :atom,
            public?: true,
            allow_nil?: false,
            default: :straight_line,
            constraints: [one_of: [:straight_line]]
          )

          attribute(:prepaid_account_id, :uuid, public?: true, allow_nil?: false)
          attribute(:expense_account_id, :uuid, public?: true, allow_nil?: false)

          attribute(:dimension_key, :atom,
            public?: true,
            allow_nil?: false,
            default: :project,
            constraints: [one_of: [:project, :lot, :fund, :cost_pool]]
          )

          attribute(:cost_object_id, :uuid, public?: true)
        end

        relationships do
          has_many :releases, unquote(release_mod) do
            public?(true)
            destination_attribute(:schedule_id)
          end

          belongs_to :prepaid_account, unquote(account_mod) do
            public?(true)
            attribute_type(:uuid)
            source_attribute(:prepaid_account_id)
            define_attribute?(false)
          end

          belongs_to :expense_account, unquote(account_mod) do
            public?(true)
            attribute_type(:uuid)
            source_attribute(:expense_account_id)
            define_attribute?(false)
          end

          belongs_to :cost_object, unquote(cost_object_mod) do
            public?(true)
            attribute_type(:uuid)
            source_attribute(:cost_object_id)
            define_attribute?(false)
          end
        end

        aggregates do
          # The register's released-to-date is Σ the release facts, computed at
          # read time; there is no stored counter to drift.
          sum :released_cents, :releases, field: :amount_cents
        end

        identities do
          identity(:unique_code, [:org_id, :code])
        end

        changes do
          change(
            {Samen.Policy.SameOrgFk,
             relationships: [:prepaid_account, :expense_account, :cost_object]}
          )

          change({Samen.Scopes.Finance.PrepaidShape, account: unquote(account_mod)})
        end

        actions do
          read :read do
            primary?(true)
            pagination(keyset?: true, required?: false)
          end

          create :create do
            accept([
              :org_id,
              :code,
              :name,
              :memo,
              :source_key,
              :source_id,
              :total_cents,
              :start_on,
              :months,
              :method,
              :prepaid_account_id,
              :expense_account_id,
              :dimension_key,
              :cost_object_id
            ])

            validate(numericality(:total_cents, greater_than: 0))
            validate(numericality(:months, greater_than: 0))
          end

          # NO update / destroy: see the moduledoc.
        end

        policies do
          policy action_type(:read) do
            authorize_if(Samen.Policy.OrgScope)
          end

          # Committing a prepayment release for future periods is the admin
          # rung, like the chart of accounts and fiscal periods.
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
  # PrepaidRelease — one period's released slice, anchored to its entry
  # ---------------------------------------------------------------------------
  defmacro define_prepaid_release(
             module,
             otp_app,
             domain,
             repo,
             abbrev,
             schedule_mod,
             entry_mod,
             account_mod
           ) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Finance.PrepaidRelease — one period's release of a prepaid schedule
        (WS-ACCT prepaid expense slice). `{schedule_id, period_key,
        amount_cents, released_on}` plus the accounts it paid and the journal
        entry the system cascade posts, anchored
        `source_key: "prepaid_release"`, `source_id: <this row>`.

        APPEND-ONLY. A release is a fact about a period that has been reported;
        the table trigger refuses UPDATE and DELETE. A mistake is corrected by
        a reversing entry, never by mutating the record of what released.

        The unique index on `{org, schedule, period}` is the exactly-once belt;
        the run's `already_released?` read is the caller-facing no-op.

        No PII (INV-1).
        """

        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_prepaid_release")
          repo(unquote(repo))
        end

        attributes do
          attribute(:period_key, :string, public?: true, allow_nil?: false)
          attribute(:amount_cents, :integer, public?: true, allow_nil?: false)
          attribute(:released_on, :date, public?: true, allow_nil?: false)
          attribute(:prepaid_account_id, :uuid, public?: true, allow_nil?: false)
          attribute(:expense_account_id, :uuid, public?: true, allow_nil?: false)
        end

        relationships do
          belongs_to :schedule, unquote(schedule_mod) do
            public?(true)
            attribute_type(:uuid)
            allow_nil?(false)
          end

          belongs_to :prepaid_account, unquote(account_mod) do
            public?(true)
            attribute_type(:uuid)
            source_attribute(:prepaid_account_id)
            define_attribute?(false)
          end

          belongs_to :expense_account, unquote(account_mod) do
            public?(true)
            attribute_type(:uuid)
            source_attribute(:expense_account_id)
            define_attribute?(false)
          end
        end

        identities do
          identity(:unique_release_period, [:org_id, :schedule_id, :period_key])
        end

        changes do
          change(
            {Samen.Policy.SameOrgFk,
             relationships: [:schedule, :prepaid_account, :expense_account]}
          )
        end

        actions do
          read :read do
            primary?(true)
            pagination(keyset?: true, required?: false)
          end

          # The system cascade's factory (PrepaidReleaseRun, authorize?: false):
          # creates the fact AND posts its entry in ONE transaction. The account
          # ids are forced by the cascade from the schedule; callers cannot
          # choose them.
          create :release do
            accept([:org_id, :schedule_id, :period_key, :amount_cents, :released_on])

            validate(numericality(:amount_cents, greater_than: 0))

            change(
              {Samen.Scopes.Finance.PrepaidReleasePosting,
               schedule: unquote(schedule_mod),
               entry: unquote(entry_mod),
               account: unquote(account_mod)}
            )
          end

          # NO update / destroy: see the moduledoc.
        end

        policies do
          policy action_type(:read) do
            authorize_if(Samen.Policy.OrgScope)
          end

          policy action(:release) do
            forbid_if(always())
          end
        end
      end
    end
  end
end
