defmodule Samen.Scopes.Finance.LeaseBlueprint do
  @moduledoc """
  Resource-definition macros for the Finance scope's **lease accounting**
  slice.

  Objects: `lease` — the office/lab contract and the six accounts it names —
  plus `lease_payment` — the per-period fact that one month's interest,
  principal and ROU amortization posted.

  ## No schedule table

  The liability/ROU schedule is derived from
  `{payment_cents, months, start_on, annual_rate_bps}` by
  `Samen.Scopes.Finance.LeaseSchedule`. The only persisted per-period fact is
  `LeasePayment`; the register and every statement can be rebuilt from the
  contract plus the payments.

  ## Accounts are named, not invented

  A lease names its ROU asset, accumulated amortization, lease liability,
  interest expense, amortization expense and cash accounts directly. That is
  the prepaid/AP-line precedent: the host's chart is data, and the payment
  row keeps the accounts it actually paid. `LeaseShape` refuses the wrong
  side/kind at create time.

  ## Initial recognition

  Creating a lease posts the commencement entry in the same transaction:
  `Dr ROU asset / Cr lease liability` at the derived present value. The lease
  row's `initial_entry_id` names that entry, anchored `source_key:
  "lease_initial"`, `source_id: <lease id>`.
  """

  # ---------------------------------------------------------------------------
  # Lease — the contract
  # ---------------------------------------------------------------------------
  defmacro define_lease(
             module,
             otp_app,
             domain,
             repo,
             abbrev,
             payment_mod,
             entry_mod,
             account_mod,
             cost_object_mod
           ) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Finance.Lease — one office or lab lease capitalised under the IFRS 16
        right-of-use model.

          * `code`/`name`/`memo` — the register's human identity; `code` is
            unique per org.
          * `kind` — `:office` or `:lab`; the reportable lease class.
          * `start_on`, `months`, `payment_cents`, `annual_rate_bps` — the
            contract. Payments are fixed and modeled at month end. The
            liability and ROU schedule is DERIVED from these values; there is
            no schedule table.
          * `rou_asset_account_id`, `accumulated_amortization_account_id`,
            `lease_liability_account_id`, `interest_expense_account_id`,
            `amortization_expense_account_id`, `cash_account_id` — the six
            same-org accounts every posting uses.
          * `dimension_key`/`cost_object_id` — the optional programme
            dimension every entry leg carries (R6).
          * `source_key`/`source_id` — the optional ADR-041 anchor to the
            document that created the lease.
          * `initial_entry_id` — the commencement entry posted by `:create`.

        The contract is immutable. Changing a payment, term or rate after
        postings exist is a remeasurement or a new lease, not a row edit. A
        lease with no payments yet may be corrected by voiding/recreating it
        through the ordinary governed paths.

        No PII (INV-1): ids, integers, dates, two closed enums, a freeform
        memo (default-deny-CDC-excluded, not vaulted).
        """

        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_lease")
          repo(unquote(repo))
        end

        attributes do
          attribute(:code, :string, public?: true, allow_nil?: false)
          attribute(:name, :string, public?: true, allow_nil?: false)
          attribute(:memo, :string, public?: true)
          attribute(:source_key, :string, public?: true)
          attribute(:source_id, :uuid, public?: true)

          attribute(:kind, :atom,
            public?: true,
            allow_nil?: false,
            constraints: [one_of: [:office, :lab]]
          )

          attribute(:start_on, :date, public?: true, allow_nil?: false)
          attribute(:months, :integer, public?: true, allow_nil?: false)
          attribute(:payment_cents, :integer, public?: true, allow_nil?: false)
          attribute(:annual_rate_bps, :integer, public?: true, allow_nil?: false, default: 0)

          attribute(:rou_asset_account_id, :uuid, public?: true, allow_nil?: false)
          attribute(:accumulated_amortization_account_id, :uuid, public?: true, allow_nil?: false)
          attribute(:lease_liability_account_id, :uuid, public?: true, allow_nil?: false)
          attribute(:interest_expense_account_id, :uuid, public?: true, allow_nil?: false)
          attribute(:amortization_expense_account_id, :uuid, public?: true, allow_nil?: false)
          attribute(:cash_account_id, :uuid, public?: true, allow_nil?: false)

          attribute(:dimension_key, :atom,
            public?: true,
            allow_nil?: false,
            default: :project,
            constraints: [one_of: [:project, :lot, :fund, :cost_pool]]
          )

          attribute(:cost_object_id, :uuid, public?: true)
          attribute(:initial_entry_id, :uuid, public?: true)
        end

        relationships do
          has_many :payments, unquote(payment_mod) do
            public?(true)
            destination_attribute(:lease_id)
          end

          belongs_to :rou_asset_account, unquote(account_mod) do
            public?(true)
            attribute_type(:uuid)
            source_attribute(:rou_asset_account_id)
            define_attribute?(false)
          end

          belongs_to :accumulated_amortization_account, unquote(account_mod) do
            public?(true)
            attribute_type(:uuid)
            source_attribute(:accumulated_amortization_account_id)
            define_attribute?(false)
          end

          belongs_to :lease_liability_account, unquote(account_mod) do
            public?(true)
            attribute_type(:uuid)
            source_attribute(:lease_liability_account_id)
            define_attribute?(false)
          end

          belongs_to :interest_expense_account, unquote(account_mod) do
            public?(true)
            attribute_type(:uuid)
            source_attribute(:interest_expense_account_id)
            define_attribute?(false)
          end

          belongs_to :amortization_expense_account, unquote(account_mod) do
            public?(true)
            attribute_type(:uuid)
            source_attribute(:amortization_expense_account_id)
            define_attribute?(false)
          end

          belongs_to :cash_account, unquote(account_mod) do
            public?(true)
            attribute_type(:uuid)
            source_attribute(:cash_account_id)
            define_attribute?(false)
          end

          belongs_to :cost_object, unquote(cost_object_mod) do
            public?(true)
            attribute_type(:uuid)
            source_attribute(:cost_object_id)
            define_attribute?(false)
          end
        end

        identities do
          identity(:unique_code, [:org_id, :code])
        end

        changes do
          change(
            {Samen.Policy.SameOrgFk,
             relationships: [
               :rou_asset_account,
               :accumulated_amortization_account,
               :lease_liability_account,
               :interest_expense_account,
               :amortization_expense_account,
               :cash_account,
               :cost_object
             ]}
          )

          change({Samen.Scopes.Finance.LeaseShape, account: unquote(account_mod)})

          change({Samen.Scopes.Finance.LeaseInitialPosting, entry: unquote(entry_mod)})
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
              :kind,
              :start_on,
              :months,
              :payment_cents,
              :annual_rate_bps,
              :rou_asset_account_id,
              :accumulated_amortization_account_id,
              :lease_liability_account_id,
              :interest_expense_account_id,
              :amortization_expense_account_id,
              :cash_account_id,
              :dimension_key,
              :cost_object_id
            ])

            validate(numericality(:payment_cents, greater_than: 0))
            validate(numericality(:months, greater_than: 0))
            validate(numericality(:annual_rate_bps, greater_than_or_equal_to: 0))
          end

          # NO update / destroy: see the moduledoc.
        end

        policies do
          policy action_type(:read) do
            authorize_if(Samen.Policy.OrgScope)
          end

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
  # LeasePayment — one period's interest, principal and ROU amortization
  # ---------------------------------------------------------------------------
  defmacro define_lease_payment(
             module,
             otp_app,
             domain,
             repo,
             abbrev,
             lease_mod,
             entry_mod,
             account_mod
           ) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Finance.LeasePayment — one period's lease posting: the payment, the
        interest component, the principal repaid, the ROU amortization, and
        the accounts the system cascade used.

        APPEND-ONLY. The table trigger refuses UPDATE and DELETE; a correction
        is a reversing entry, never a rewrite. The unique index on
        `{org, lease, period}` is the exactly-once anchor, and the run's
        `already_paid?/3` read is the caller-facing no-op.
        """

        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_lease_payment")
          repo(unquote(repo))
        end

        attributes do
          attribute(:period_key, :string, public?: true, allow_nil?: false)
          attribute(:payment_cents, :integer, public?: true, allow_nil?: false)
          attribute(:interest_cents, :integer, public?: true, allow_nil?: false)
          attribute(:principal_cents, :integer, public?: true, allow_nil?: false)
          attribute(:amortization_cents, :integer, public?: true, allow_nil?: false)
          attribute(:paid_on, :date, public?: true, allow_nil?: false)

          # Forced by the cascade; read-only to callers.
          attribute(:lease_liability_account_id, :uuid, public?: true)
          attribute(:interest_expense_account_id, :uuid, public?: true)
          attribute(:amortization_expense_account_id, :uuid, public?: true)
          attribute(:accumulated_amortization_account_id, :uuid, public?: true)
          attribute(:cash_account_id, :uuid, public?: true)
        end

        relationships do
          belongs_to :lease, unquote(lease_mod) do
            public?(true)
            attribute_type(:uuid)
            allow_nil?(false)
          end

          belongs_to :lease_liability_account, unquote(account_mod) do
            public?(true)
            attribute_type(:uuid)
            source_attribute(:lease_liability_account_id)
            define_attribute?(false)
          end

          belongs_to :interest_expense_account, unquote(account_mod) do
            public?(true)
            attribute_type(:uuid)
            source_attribute(:interest_expense_account_id)
            define_attribute?(false)
          end

          belongs_to :amortization_expense_account, unquote(account_mod) do
            public?(true)
            attribute_type(:uuid)
            source_attribute(:amortization_expense_account_id)
            define_attribute?(false)
          end

          belongs_to :accumulated_amortization_account, unquote(account_mod) do
            public?(true)
            attribute_type(:uuid)
            source_attribute(:accumulated_amortization_account_id)
            define_attribute?(false)
          end

          belongs_to :cash_account, unquote(account_mod) do
            public?(true)
            attribute_type(:uuid)
            source_attribute(:cash_account_id)
            define_attribute?(false)
          end
        end

        identities do
          identity(:unique_payment_period, [:org_id, :lease_id, :period_key])
        end

        changes do
          change(
            {Samen.Policy.SameOrgFk,
             relationships: [
               :lease,
               :lease_liability_account,
               :interest_expense_account,
               :amortization_expense_account,
               :accumulated_amortization_account,
               :cash_account
             ]}
          )
        end

        actions do
          read :read do
            primary?(true)
            pagination(keyset?: true, required?: false)
          end

          # The system cascade's factory (LeasePaymentRun, authorize?: false):
          # creates the fact AND posts its entry in ONE transaction. The
          # amounts and accounts are forced from the lease's derived schedule;
          # callers cannot choose them.
          create :pay do
            accept([:org_id, :lease_id, :period_key, :paid_on])

            change(
              {Samen.Scopes.Finance.LeasePaymentPosting,
               lease: unquote(lease_mod), entry: unquote(entry_mod)}
            )
          end

          # NO update / destroy: see the moduledoc.
        end

        policies do
          policy action_type(:read) do
            authorize_if(Samen.Policy.OrgScope)
          end

          policy action(:pay) do
            forbid_if(always())
          end
        end
      end
    end
  end
end
