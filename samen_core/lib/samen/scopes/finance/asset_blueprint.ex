defmodule Samen.Scopes.Finance.AssetBlueprint do
  @moduledoc """
  Resource-definition macros for the Finance scope's **asset register and its
  depreciation postings** (WS-ACCT Phase 8; ADR-054 D9).

  Objects: `asset` (an intangible or a piece of equipment, its cost and the
  contract that amortizes it) + `asset_posting` (the per-period fact that one
  slice of that contract landed, anchored to the journal entry it posted).

  ## There is NO schedule table

  The schedule is DERIVED from `{cost_cents, salvage_cents, life_months,
  acquired_on}` — see `Samen.Scopes.Finance.AssetSchedule`. Storing 36 rows (or
  a "remaining balance" counter) would create a second truth that can disagree
  with the asset it belongs to: a re-seeded life would leave stale rows, a
  rolled-back posting would leave a decremented counter, and no read could say
  which one was right. Every schedule question — what is period 19's slice? how
  many months remain? is it fully amortized? — is answered from the contract
  plus Σ postings, which is exactly the state a reviewer can re-derive.

  The ONLY persisted per-period fact is `AssetPosting`: the slice that actually
  posted, with the entry that carries it. It is append-only, and the table's
  unique index on `{org, asset, period}` is the exactly-once anchor.

  ## The PDK arithmetic

  The source manual capitalizes the photonics PDK licence at 36 months, and
  JE-004 books its monthly amortization. Integer cents cannot divide
  600 000.00 by 36 evenly, so the schedule gives the LAST month the division
  remainder (see `AssetSchedule`): 35 months at 16 666.66 and a final 16 666.90,
  which sums to 600 000.00 exactly rather than stranding cents on the balance
  sheet forever.

  ## The run is exactly-once in two layers

  * `Samen.Scopes.Finance.DepreciationRun` reads the period's posting before
    creating one, so a retried cron is a clean no-op;
  * the table's unique index refuses a duplicate row even below Ash.

  The second layer is the belt; the first is what makes the belt unnecessary in
  the normal case.
  """

  # ---------------------------------------------------------------------------
  # Asset — the register row and the contract that amortizes it
  # ---------------------------------------------------------------------------
  defmacro define_asset(
             module,
             otp_app,
             domain,
             repo,
             abbrev,
             posting_mod,
             entry_mod,
             posting_account_mod,
             cost_object_mod
           ) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Finance.Asset — one capitalized intangible or piece of equipment and the
        rule that amortizes it (WS-ACCT Phase 8; ADR-054 D9).

          * `code`/`name` — the register's human identity; `code` is unique per
            org, like a CoA code.
          * `kind` — `:intangible` (the PDK licence) or `:equipment` (lab gear).
            It selects the posting pair: intangibles book amortization expense
            against `accumulated_amortization`, equipment books depreciation
            expense against `accumulated_depreciation`.
          * `cost_cents`, `acquired_on`, `salvage_cents`, `life_months` — the
            contract. The monthly slice is DERIVED from these; there is no
            schedule row and no stored balance.
          * `method` — `:straight_line` only, for now. A method the ledger cannot
            compute is refused rather than silently treated as straight line.
          * `status` — `:active`, `:under_construction`, or `:disposed`. An active
            asset depreciates from `in_service_on`. A CIP asset has no schedule
            and no postings until `:place_in_service`. `:dispose` is one-way and
            stops the schedule from its month onward; the months already posted
            stay posted (a disposal is prospective).
          * `in_service_on` — the month the derived schedule starts. Ordinary
            assets default it to `acquired_on`; CIP assets acquire it on
            `:place_in_service`.
          * `disposal_proceeds_cents` / `disposal_gain_loss_cents` /
            `disposal_entry_id` — the disposal fact and the entry that carries
            it. `disposal_gain_loss_cents` is signed: positive is a gain,
            negative a loss.
          * `in_service_entry_id` — the CIP reclassification entry, when the
            asset was placed in service through that action.
          * `transfer_history` — bounded, dated from/to cost-object records for
            `:transfer`. Future depreciation follows the current dimension;
            past entries keep theirs.
          * `cost_object_id` / `dimension_key` — the optional programme dimension
            both entry legs carry (R6). Nil means the asset is undimensioned and
            the entry passes R6 vacuously, exactly like a base-system posting.

        Updates are lifecycle actions only: `:dispose` posts the disposal
        entry, `:place_in_service` transfers a CIP into service, and `:transfer`
        moves the future cost-object dimension and keeps a history. Changing a
        cost, life or salvage after postings exist would rewrite the schedule
        retroactively, which is an accounting decision (a new asset, or a
        correcting entry), not a row edit.

        No PII (INV-1): ids, integers, dates, two closed enums, a freeform memo
        (default-deny-CDC-excluded, not vaulted).
        """

        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_asset")
          repo(unquote(repo))
        end

        attributes do
          attribute(:code, :string, public?: true, allow_nil?: false)
          attribute(:name, :string, public?: true, allow_nil?: false)
          attribute(:memo, :string, public?: true)

          attribute(:kind, :atom,
            public?: true,
            allow_nil?: false,
            constraints: [one_of: [:intangible, :equipment]]
          )

          attribute(:cost_cents, :integer, public?: true, allow_nil?: false)
          attribute(:acquired_on, :date, public?: true, allow_nil?: false)

          attribute(:method, :atom,
            public?: true,
            allow_nil?: false,
            default: :straight_line,
            constraints: [one_of: [:straight_line]]
          )

          attribute(:life_months, :integer, public?: true, allow_nil?: false)
          attribute(:salvage_cents, :integer, public?: true, allow_nil?: false, default: 0)

          attribute(:status, :atom,
            public?: true,
            allow_nil?: false,
            default: :active,
            constraints: [one_of: [:active, :under_construction, :disposed]]
          )

          attribute(:in_service_on, :date, public?: true)
          attribute(:disposed_on, :date, public?: true)
          attribute(:disposal_proceeds_cents, :integer, public?: true)
          attribute(:disposal_gain_loss_cents, :integer, public?: true)
          attribute(:disposal_entry_id, :uuid, public?: true)
          attribute(:in_service_entry_id, :uuid, public?: true)

          attribute(:transfer_history, {:array, :map},
            public?: true,
            allow_nil?: false,
            default: []
          )

          attribute(:dimension_key, :atom,
            public?: true,
            allow_nil?: false,
            default: :project,
            constraints: [one_of: [:project, :lot, :fund, :cost_pool]]
          )

          attribute(:cost_object_id, :uuid, public?: true)
        end

        relationships do
          has_many :postings, unquote(posting_mod) do
            public?(true)
            destination_attribute(:asset_id)
          end

          belongs_to :cost_object, unquote(cost_object_mod) do
            public?(true)
            attribute_type(:uuid)
            source_attribute(:cost_object_id)
            define_attribute?(false)
          end
        end

        aggregates do
          # The design's "accumulated" is DERIVED: Σ the postings. A database
          # aggregate, so it is computed at read time and cannot drift.
          sum :posted_cents, :postings, field: :amount_cents
        end

        identities do
          identity(:unique_code, [:org_id, :code])
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
              :code,
              :name,
              :memo,
              :kind,
              :cost_cents,
              :acquired_on,
              :method,
              :life_months,
              :salvage_cents,
              :dimension_key,
              :cost_object_id
            ])

            # `status` and `disposed_on` are NOT accepted: the lifecycle action
            # decides the status, and only `:dispose` can retire an asset.
            argument(:under_construction, :boolean, default: false)
            argument(:in_service_on, :date)

            validate(numericality(:cost_cents, greater_than: 0))
            validate(numericality(:life_months, greater_than: 0))
            validate(numericality(:salvage_cents, greater_than_or_equal_to: 0))

            change(Samen.Scopes.Finance.AssetCreate)
            change(Samen.Scopes.Finance.AssetShape)
          end

          # The one-way disposal. It records the date, posts the standard
          # proceeds/accumulated/cost/gain-loss entry, and stops the schedule
          # from that month. The months already posted are history that a
          # disposal cannot rewrite.
          update :dispose do
            accept([])
            argument(:disposed_on, :date, allow_nil?: false)
            argument(:proceeds_cents, :integer, allow_nil?: false, default: 0)
            require_atomic?(false)

            change(
              {Samen.Scopes.Finance.AssetDisposal,
               asset: unquote(module),
               posting: unquote(posting_mod),
               entry: unquote(entry_mod),
               posting_account: unquote(posting_account_mod)}
            )
          end

          # CIP -> in service. Posts the reclassification from
          # construction-in-progress to the asset-kind cost account, then the
          # derived schedule starts at this date.
          update :place_in_service do
            accept([])
            argument(:in_service_on, :date, allow_nil?: false)
            require_atomic?(false)

            change(
              {Samen.Scopes.Finance.AssetInService,
               asset: unquote(module),
               entry: unquote(entry_mod),
               posting_account: unquote(posting_account_mod)}
            )
          end

          # Move the FUTURE cost-object dimension. Past entries keep theirs;
          # the action appends a dated from/to record to the register. No entry
          # is posted (the balance is unchanged, and R6 requires a
          # dimension-balanced entry rather than a one-sided reclass).
          update :transfer do
            accept([])
            argument(:transferred_on, :date, allow_nil?: false)
            argument(:cost_object_id, :uuid, allow_nil?: false)
            argument(:dimension_key, :atom, allow_nil?: false)
            require_atomic?(false)
            change({Samen.Scopes.Finance.AssetTransfer, asset: unquote(module)})
          end

          # NO generic update / destroy: see the moduledoc.
        end

        policies do
          policy action_type(:read) do
            authorize_if(Samen.Policy.OrgScope)
          end

          # Capitalizing an asset is a policy decision with a multi-period
          # effect — the admin rung, like the chart of accounts and the terms
          # of a revenue schedule.
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
  # AssetPosting — one period's slice, anchored to its entry
  # ---------------------------------------------------------------------------
  defmacro define_asset_posting(
             module,
             otp_app,
             domain,
             repo,
             abbrev,
             asset_mod,
             entry_mod,
             posting_account_mod,
             account_mod
           ) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Finance.AssetPosting — one period's depreciation/amortization slice
        (WS-ACCT Phase 8; ADR-054 D9). `{asset_id, period_key, amount_cents,
        depreciated_on}` plus the two accounts the system cascade paid, and the
        journal entry it posted, anchored `source_key: "asset_posting"`,
        `source_id: <this row>`.

        APPEND-ONLY. A posting is a fact about a period that has been reported;
        it is never edited and never deleted. The migration's trigger refuses
        UPDATE and DELETE outright. A mistake is corrected the way the ledger
        corrects anything — with a reversing entry — not by mutating the record
        of what posted.

        The two account columns NAME the legs. The audit read
        (`Samen.Scopes.Finance.ReconcileAssets`) compares the entry to them
        rather than re-resolving the posting map, so a later re-point of the
        map cannot silently rewrite history.

        The table's unique index on `{org, asset, period}` is the exactly-once
        belt: one period amortizes once, even if two runs race. The
        caller-facing no-op is the run's `already_posted?` read; this row is
        the fact.

        No PII (INV-1).
        """

        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_asset_posting")
          repo(unquote(repo))
        end

        attributes do
          # "YYYY-MM" — the fiscal month this slice belongs to. Text rather
          # than a date so a period is an identity, not a range two rows could
          # disagree about.
          attribute(:period_key, :string, public?: true, allow_nil?: false)
          attribute(:amount_cents, :integer, public?: true, allow_nil?: false)
          attribute(:depreciated_on, :date, public?: true, allow_nil?: false)

          # Forced by the cascade; read-only to every caller.
          attribute(:expense_account_id, :uuid, public?: true)
          attribute(:contra_account_id, :uuid, public?: true)
        end

        relationships do
          belongs_to :asset, unquote(asset_mod) do
            public?(true)
            attribute_type(:uuid)
            allow_nil?(false)
          end

          belongs_to :expense_account, unquote(account_mod) do
            public?(true)
            attribute_type(:uuid)
            source_attribute(:expense_account_id)
            define_attribute?(false)
          end

          belongs_to :contra_account, unquote(account_mod) do
            public?(true)
            attribute_type(:uuid)
            source_attribute(:contra_account_id)
            define_attribute?(false)
          end
        end

        changes do
          change(
            {Samen.Policy.SameOrgFk, relationships: [:asset, :expense_account, :contra_account]}
          )
        end

        identities do
          identity(:unique_posting_period, [:org_id, :asset_id, :period_key])
        end

        actions do
          read :read do
            primary?(true)
            pagination(keyset?: true, required?: false)
          end

          # The system cascade's factory (DepreciationRun, `authorize?: false`):
          # creates the fact AND posts its expense/contra entry in ONE
          # transaction. Not a member-facing action — the policy forbids it.
          create :depreciate do
            accept([:org_id, :asset_id, :period_key, :amount_cents, :depreciated_on])

            validate(numericality(:amount_cents, greater_than: 0))

            change(
              {Samen.Scopes.Finance.DepreciationPosting,
               asset: unquote(asset_mod),
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

          policy action(:depreciate) do
            forbid_if(always())
          end
        end
      end
    end
  end
end
