defmodule Samen.Scopes.Finance.ReserveBlueprint do
  @moduledoc """
  Resource-definition macros for the Finance scope's **inventory reserve**
  (WS-ACCT Phase 9; ADR-054 D10).

  Objects: `inventory_reserve` (a POLICY — which stock is estimated obsolete,
  and by how much), `reserve_write_down` (one gated write-down proposal and,
  once approved, its posting) and `reserve_write_down_line` (the per-item
  assessment the proposal was built from).

  ## The policy is a rule, not a balance

  The manual's own entries (JE-034, JE-062) book obsolescence **straight off
  the inventory account** — `Dr 8000 · Inventory Write-Down` / `Cr 1400·1410` —
  and carry no reserve contra account. So `InventoryReserve` here is the
  *policy* in the accounting sense (an estimate rule), never a GL balance:
  nothing posts when a policy is created, and the `:inventory_reserve` posting
  meaning stays deliberately unmapped. Binding it would let a caller park money
  in an account the chart never opens.

  ## Nothing posts without a human

  NRV is an ESTIMATE. `Samen.Scopes.Finance.ReserveAssessment` derives the
  candidates and the cents, but a read cannot post. Drafting persists the
  assessment (`:draft`); posting is a SEPARATE action carrying the ADR-040
  Gate, so an unwrapped call is refused with `ApprovalRequired` and a distinct
  approver's decision re-invokes it as the requester. The posting cascade
  re-derives the assessment and refuses any draft whose numbers no longer
  match, so an approval consents to the stock that is there, not to a stale
  snapshot.

  ## Why the draft carries its own lines

  A journal entry has accounts and amounts; it cannot say "250 dies of SKU
  SoC-250, aged 18 months, at the moving-average cost". The lines ARE that
  fact, and the posting aggregates them into one two-legged entry per
  inventory account (the manual's JE-062 shape: one debit to 8000, one credit
  per finished-goods account). The lines also make the drift check exact:
  quantity, cost and account are compared, not just the total.

  ## Exactly once, and net of what already landed

  A posted write-down is final; `:post` only matches a `:draft`, and the
  header's posting columns are frozen by a trigger once posted. More
  importantly, the ASSESSMENT nets every posted write-down for an item out of
  its remaining carrying value, so a second quarterly review proposes only the
  value that has not already been written down. Re-assessing the same stock
  cannot propose the same cents twice.
  """

  # ---------------------------------------------------------------------------
  # InventoryReserve — the policy row
  # ---------------------------------------------------------------------------
  defmacro define_inventory_reserve(module, otp_app, domain, repo, abbrev) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Finance.InventoryReserve — the obsolescence policy (WS-ACCT Phase 9;
        ADR-054 D10). A rule, not a GL balance.

          * `basis` — `:age` (stock older than `age_months` is estimated
            obsolete) or `:item` (the listed items are estimated obsolete
            regardless of age — JE-034's "failed final validation, no
            alternative use" case).
          * `age_months` — the eligibility threshold for `:age`; nil for
            `:item`.
          * `pct` — the write-down percentage of the item's REMAINING carrying
            value (1–100). 100 is the manual's "no expected future use, NRV 0"
            case; a partial percentage is an NRV haircut.
          * `applies_to` — the item ids the policy covers (Inventory item ids,
            opaque uuids — Finance never re-declares the item). `[]` means
            every stocked item for `:age`, and is refused for `:item`, where a
            named target is the whole point.

        No PII (INV-1): a name, two closed enums, an integer, an id list.
        """

        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_inventory_reserve")
          repo(unquote(repo))
        end

        attributes do
          attribute(:name, :string, public?: true, allow_nil?: false)

          attribute(:basis, :atom,
            public?: true,
            allow_nil?: false,
            constraints: [one_of: [:age, :item]]
          )

          attribute(:age_months, :integer, public?: true)

          attribute(:pct, :integer, public?: true, allow_nil?: false)

          attribute(:applies_to, {:array, :uuid},
            public?: true,
            allow_nil?: false,
            default: []
          )
        end

        identities do
          identity(:unique_name, [:org_id, :name])
        end

        actions do
          read :read do
            primary?(true)
            pagination(keyset?: true, required?: false)
          end

          create :create do
            accept([:org_id, :name, :basis, :age_months, :pct, :applies_to])

            validate(numericality(:pct, greater_than: 0, less_than_or_equal_to: 100))
            validate(numericality(:age_months, greater_than: 0))

            change(Samen.Scopes.Finance.ReservePolicyShape)
          end

          # Policy terms may change (a haircut is re-estimated); the assessment
          # always re-derives, and a draft built under the old terms refuses to
          # post because its numbers no longer match. `name` is the identity and
          # is not editable.
          update :update do
            accept([:basis, :age_months, :pct, :applies_to])
            require_atomic?(false)

            validate(numericality(:pct, greater_than: 0, less_than_or_equal_to: 100))
            validate(numericality(:age_months, greater_than: 0))

            change(Samen.Scopes.Finance.ReservePolicyShape)
          end
        end

        policies do
          policy action_type(:read) do
            authorize_if(Samen.Policy.OrgScope)
          end

          # A policy decides how much of the balance sheet is written down — the
          # admin rung, like the chart of accounts and an asset's life.
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
  # ReserveWriteDown — the gated proposal / posting header
  # ---------------------------------------------------------------------------
  defmacro define_reserve_write_down(
             module,
             otp_app,
             domain,
             repo,
             abbrev,
             policy_mod,
             line_mod,
             entry_mod,
             posting_account_mod,
             account_mod,
             item_mod,
             level_mod,
             ledger_mod
           ) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Finance.ReserveWriteDown — one obsolescence write-down (WS-ACCT Phase 9;
        ADR-054 D10).

        `:draft` runs the assessment and persists its lines; it posts NOTHING.
        `:post` carries the ADR-040 Gate: the ungated call is refused with
        `ApprovalRequired`, and a distinct approver's decision re-invokes it as
        the requester. The posting cascade then re-derives the assessment and
        lands ONE entry — debit `write_down_expense`, credit each line's
        inventory account — anchored `source_key: "reserve_write_down"`,
        `source_id: <this row>`.

        A posted write-down is final: `:post` only matches a `:draft` (a
        validation refuses a posted row before the Gate can even open a new
        approval), and the migration's trigger freezes the posting columns once
        `status = 'posted'`. A correction is a new proposal/entry, never a
        rewrite.

        No PII (INV-1): dates, ids, one closed enum, integer cents.
        """

        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_reserve_write_down")
          repo(unquote(repo))
        end

        attributes do
          attribute(:assessed_on, :date, public?: true, allow_nil?: false)

          attribute(:status, :atom,
            public?: true,
            allow_nil?: false,
            default: :draft,
            constraints: [one_of: [:draft, :posted]]
          )

          # Forced by the cascade; never accepted from a caller.
          attribute(:amount_cents, :integer, public?: true)
          attribute(:entry_id, :uuid, public?: true)
          attribute(:posted_at, :utc_datetime, public?: true)
        end

        relationships do
          belongs_to :policy, unquote(policy_mod) do
            public?(true)
            attribute_type(:uuid)
            allow_nil?(false)
          end

          belongs_to :entry, unquote(entry_mod) do
            public?(true)
            attribute_type(:uuid)
            source_attribute(:entry_id)
            define_attribute?(false)
          end

          has_many :lines, unquote(line_mod) do
            public?(true)
            destination_attribute(:write_down_id)
          end
        end

        changes do
          change({Samen.Policy.SameOrgFk, relationships: [:policy, :entry]})
        end

        actions do
          read :read do
            primary?(true)
            pagination(keyset?: true, required?: false)
          end

          # The assessment, persisted. Accepts no amounts: the cascade derives
          # every cent and refuses an assessment that finds nothing.
          create :draft do
            accept([:org_id, :policy_id, :assessed_on])

            change(
              {Samen.Scopes.Finance.ReserveDrafting,
               policy: unquote(policy_mod),
               line: unquote(line_mod),
               assessment: [
                 items: unquote(item_mod),
                 levels: unquote(level_mod),
                 ledger: unquote(ledger_mod)
               ]}
            )
          end

          # The gated posting. NO caller inputs: everything the entry needs is
          # re-derived from governed state inside the decision transaction.
          update :post do
            accept([])
            require_atomic?(false)

            validate(Samen.Scopes.Finance.ReserveDraftStatus)

            change({Samen.Approvals.Gate, kind: unquote(Atom.to_string(module)) <> ":post"})

            # The outer arm: the posted-born entry's own PostGuard restores the
            # marker BEFORE EntryLines inserts its rows, so the action that
            # drives the posting must hold the marker armed (the AP/PO approve
            # precedent). The restore is prior-value-safe under nesting.
            change(Samen.Scopes.Finance.PostingMarker)

            change(
              {Samen.Scopes.Finance.ReservePosting,
               policy: unquote(policy_mod),
               line: unquote(line_mod),
               entry: unquote(entry_mod),
               posting_account: unquote(posting_account_mod),
               account: unquote(account_mod),
               assessment: [
                 items: unquote(item_mod),
                 levels: unquote(level_mod),
                 ledger: unquote(ledger_mod)
               ]}
            )
          end

          # NO update / destroy beyond the gated transition: see the moduledoc.
        end

        policies do
          policy action_type(:read) do
            authorize_if(Samen.Policy.OrgScope)
          end

          # Drafting is an accountant's proposal (member rung); posting re-runs
          # under the Gate as the requester, so it must stay reachable for the
          # same rung. Second-party consent comes from the Gate, never from a
          # role check here.
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
  # ReserveWriteDownLine — the per-item assessment fact
  # ---------------------------------------------------------------------------
  defmacro define_reserve_write_down_line(
             module,
             otp_app,
             domain,
             repo,
             abbrev,
             write_down_mod,
             account_mod
           ) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Finance.ReserveWriteDownLine — one item's slice of a write-down proposal
        (WS-ACCT Phase 9; ADR-054 D10): the quantity the assessment found, its
        carrying cost, the proposed write-down and the inventory account the
        credit leg pays.

        APPEND-ONLY: the migration's trigger refuses UPDATE and DELETE. The
        line names its accounts so the posting does not re-resolve a policy that
        may have moved, and `{write_down, item}` is unique so one proposal
        cannot carry the same item twice.

        `item_id` is an opaque Inventory id — Finance references the item, it
        never re-declares it (design §0.4's ids-only posture). No PII (INV-1).
        """

        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_reserve_write_down_line")
          repo(unquote(repo))
        end

        attributes do
          attribute(:item_id, :uuid, public?: true, allow_nil?: false)
          attribute(:quantity, :integer, public?: true, allow_nil?: false)
          attribute(:cost_cents, :integer, public?: true, allow_nil?: false)
          attribute(:write_down_cents, :integer, public?: true, allow_nil?: false)
          attribute(:inventory_account_id, :uuid, public?: true, allow_nil?: false)
        end

        relationships do
          belongs_to :write_down, unquote(write_down_mod) do
            public?(true)
            attribute_type(:uuid)
            allow_nil?(false)
          end

          belongs_to :inventory_account, unquote(account_mod) do
            public?(true)
            attribute_type(:uuid)
            source_attribute(:inventory_account_id)
            define_attribute?(false)
          end
        end

        changes do
          change({Samen.Policy.SameOrgFk, relationships: [:write_down, :inventory_account]})
        end

        identities do
          identity(:unique_item, [:org_id, :write_down_id, :item_id])
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
              :write_down_id,
              :item_id,
              :quantity,
              :cost_cents,
              :write_down_cents,
              :inventory_account_id
            ])

            validate(numericality(:quantity, greater_than: 0))
            validate(numericality(:cost_cents, greater_than: 0))
            validate(numericality(:write_down_cents, greater_than: 0))
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
