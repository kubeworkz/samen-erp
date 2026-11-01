defmodule Samen.Scopes.Finance.VarianceBlueprint do
  @moduledoc """
  Resource definitions for the Finance scope's **standard costing and variance
  layer** (WS-ACCT Phase 7; ADR-054 D4, R8).

  Objects: `cost_standard` (the effective-dated card for one output item and
  cost object) + `cost_standard_line` (one element's standard qty, price and
  expected yield) + `cost_variance` (one posted variance fact, anchored to the
  journal entry it landed).

  ## Standards never revalue stock

  This is a variance layer, not a second valuation (ADR-054 D4). A standard
  prices the DIFFERENCE between actual and expected cost; the stock ledger's
  moving average stays the one stock valuation and `Item.unit_cost_cents` is
  never touched by a variance run. Revaluing inventory off a standard would be
  the two-truths failure the reconciliation spine exists to prevent.

  ## Cards are append-only; a revision is a new card

  `effective_on` versions the standard rather than an edit history. A card and
  its lines are created once and never updated or deleted: repricing a period
  that used the old card would rewrite a variance that has already been
  reported. The one update action on a card is `:post_variances`, which posts
  the period's variances and changes nothing on the card itself.

  ## A variance row NAMES its accounts

  `variance_account_id`, `disposition` and `disposition_account_id` are
  resolved by the posting cascade and forced onto the row, so R8 can compare
  the posting to "the account its row names" without re-deriving the policy.
  The row also records the exact `inputs` (output units and per-line qty/price)
  it was computed from, so the tie back to the card is recomputable — which is
  what makes `standard_id` more than a dangling reference.
  """

  # ---------------------------------------------------------------------------
  # CostStandard — the effective-dated card
  # ---------------------------------------------------------------------------
  defmacro define_cost_standard(
             module,
             otp_app,
             domain,
             repo,
             abbrev,
             line_mod,
             variance_mod,
             cost_object_mod
           ) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Finance.CostStandard — one output item's standard cost card for a cost
        object, effective from a date (WS-ACCT Phase 7; ADR-054 D4).

          * `code` — the card's label; the identity is
            `{cost_object, effective_on}`, so two cards cannot govern one
            period.
          * `effective_on` — the first day this card governs. The card in force
            for a period is the latest one on/before the period's last day
            (`Samen.Scopes.Finance.StandardCard`).
          * `output_item_id` — the item the standards produce (an opaque uuid;
            Finance does not couple to Inventory). Optional for a programme
            whose output is not a stock item.
          * `dimension_key` — which dimension axis the variance entries use to
            name this card's cost object (`project`, `lot`, `fund` or
            `cost_pool`). The card declares it because only the host knows
            which axis its cost objects live on; both entry legs carry it, so
            R6 (per-cost-object balance) holds and per-chip variance reporting
            is a GROUP BY.

        APPEND-ONLY. There is no `:update` / `:destroy`; a revision is a new
        card. The ONLY update action is `:post_variances`, the period run, which
        leaves the card untouched.

        No PII (INV-1): text, dates, uuids, a closed enum.
        """

        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_cost_standard")
          repo(unquote(repo))
        end

        attributes do
          attribute(:code, :string, public?: true, allow_nil?: false)
          attribute(:output_item_id, :uuid, public?: true)
          attribute(:effective_on, :date, public?: true, allow_nil?: false)
          attribute(:memo, :string, public?: true)

          attribute(:dimension_key, :atom,
            public?: true,
            allow_nil?: false,
            default: :project,
            constraints: [one_of: [:project, :lot, :fund, :cost_pool]]
          )
        end

        relationships do
          belongs_to :cost_object, unquote(cost_object_mod) do
            public?(true)
            attribute_type(:uuid)
            allow_nil?(false)
          end

          has_many :lines, unquote(line_mod) do
            public?(true)
            destination_attribute(:standard_id)
          end

          has_many :variances, unquote(variance_mod) do
            public?(true)
            destination_attribute(:standard_id)
          end
        end

        identities do
          identity(:unique_card_period, [:org_id, :cost_object_id, :effective_on])
        end

        changes do
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
              :cost_object_id,
              :output_item_id,
              :effective_on,
              :memo,
              :dimension_key
            ])
          end

          # The period run: compute all seven classes from this card and the
          # declared actuals, then post each non-zero one. The change runs
          # inside this action's transaction, so a failure on any class leaves
          # no variance row and no entry behind.
          update :post_variances do
            require_atomic?(false)

            argument(:period_key, :string, allow_nil?: false)
            argument(:actuals, :map, allow_nil?: false)

            change(
              {Samen.Scopes.Finance.VarianceEngine,
               standard_line: unquote(line_mod), variance: unquote(variance_mod)}
            )
          end
        end

        policies do
          policy action_type(:read) do
            authorize_if(Samen.Policy.OrgScope)
          end

          policy action_type([:create, :update]) do
            forbid_unless(Samen.Policy.OrgScope)
            forbid_unless({Samen.Policy.RoleAtLeast, role: :admin})
            authorize_if(always())
          end
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # CostStandardLine — one element's standard
  # ---------------------------------------------------------------------------
  defmacro define_cost_standard_line(module, otp_app, domain, repo, abbrev, standard_mod) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Finance.CostStandardLine — one element's standard on a card (WS-ACCT
        Phase 7; ADR-054 D4): material, labour or overhead.

          * `standard_qty` — per GOOD output unit: base-UOM quantity for a
            material line, labour MINUTES for labour and overhead. At 100 %
            yield for material; `expected_yield_bp` scales the allowance.
          * `standard_unit_price_cents` — cents per qty unit: per base-UOM
            unit, or per labour minute.
          * `expected_yield_bp` — basis points of good output per input unit
            (8_500 = 85.00 %). A BOM line is structural, so its yield must be
            100 %.
          * `usage_basis` — which usage variance the line feeds: `:yield`
            (yield-scaled allowance), `:bom` (structural allowance) or `:none`
            (price variance only). Labour and overhead lines must be `:none`
            and feed their rate/efficiency and spending/volume classes instead.

        APPEND-ONLY, like the card it belongs to.

        No PII (INV-1).
        """

        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_cost_standard_line")
          repo(unquote(repo))
        end

        attributes do
          attribute(:element, :atom,
            public?: true,
            allow_nil?: false,
            constraints: [one_of: [:material, :labor, :overhead]]
          )

          attribute(:item_id, :uuid, public?: true)
          attribute(:standard_qty, :integer, public?: true, allow_nil?: false)
          attribute(:standard_unit_price_cents, :integer, public?: true, allow_nil?: false)

          attribute(:expected_yield_bp, :integer,
            public?: true,
            allow_nil?: false,
            default: 10_000
          )

          attribute(:usage_basis, :atom,
            public?: true,
            allow_nil?: false,
            default: :yield,
            constraints: [one_of: [:yield, :bom, :none]]
          )
        end

        relationships do
          belongs_to :standard, unquote(standard_mod) do
            public?(true)
            attribute_type(:uuid)
            allow_nil?(false)
          end
        end

        identities do
          identity(:unique_line, [:org_id, :standard_id, :element, :item_id])
        end

        changes do
          change({Samen.Policy.SameOrgFk, relationships: [:standard]})
        end

        actions do
          read :read do
            primary?(true)
            pagination(keyset?: true, required?: false)
          end

          create :create do
            accept([
              :org_id,
              :standard_id,
              :element,
              :item_id,
              :standard_qty,
              :standard_unit_price_cents,
              :expected_yield_bp,
              :usage_basis
            ])

            validate(numericality(:standard_qty, greater_than: 0))
            validate(numericality(:standard_unit_price_cents, greater_than_or_equal_to: 0))

            validate(
              numericality(:expected_yield_bp,
                greater_than: 0,
                less_than_or_equal_to: 10_000
              )
            )

            change(Samen.Scopes.Finance.StandardShape)
          end
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
  # CostVariance — one posted variance fact
  # ---------------------------------------------------------------------------
  defmacro define_cost_variance(
             module,
             otp_app,
             domain,
             repo,
             abbrev,
             standard_mod,
             cost_object_mod,
             entry_mod,
             posting_account_mod
           ) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Finance.CostVariance — one posted standard-cost variance (WS-ACCT Phase
        7; ADR-054 D4, R8).

          * `period_key` — `"YYYY-MM"`, the fiscal month the variance belongs
            to; the entry is dated the period's last day.
          * `type` — one of the seven classes
            (`Samen.Scopes.Finance.VarianceMath.types/0`).
          * `amount_cents` — signed, positive = UNFAVOURABLE (actual >
            standard); `actual_amount_cents` and `standard_amount_cents` are
            the two legs the difference came from.
          * `variance_account_id` / `disposition` / `disposition_account_id` —
            the accounts the row names, resolved from
            `Samen.Scopes.Finance.VarianceDisposition` at posting time.
          * `standard_id` — the card the variance was priced from; R8 checks it
            is the card IN FORCE for the period, not merely a card.
          * `inputs` — the exact normalized actuals (`output_units` + per-line
            qty/price) the variance was computed from, so the tie to the card
            is recomputable.
          * `entry_id` — the anchored journal entry (`source_key:
            "cost_variance"`).

        Exactly-once per `{cost object, period, type}`: the table's unique index
        is the belt, and the run's existing-row read makes a retry a clean
        no-op. APPEND-ONLY: the trigger refuses UPDATE and DELETE; a wrong
        variance is corrected with a reversing entry, never by rewriting the
        fact.

        No PII (INV-1).
        """

        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_cost_variance")
          repo(unquote(repo))
        end

        attributes do
          attribute(:period_key, :string, public?: true, allow_nil?: false)

          attribute(:type, :atom,
            public?: true,
            allow_nil?: false,
            constraints: [
              one_of: [
                :ppv,
                :yield,
                :bom,
                :labor_rate,
                :labor_efficiency,
                :overhead_spending,
                :overhead_volume
              ]
            ]
          )

          attribute(:amount_cents, :integer, public?: true, allow_nil?: false)
          attribute(:actual_amount_cents, :integer, public?: true, allow_nil?: false)
          attribute(:standard_amount_cents, :integer, public?: true, allow_nil?: false)

          attribute(:variance_account_id, :uuid, public?: true)
          attribute(:disposition_account_id, :uuid, public?: true)

          attribute(:disposition, :atom,
            public?: true,
            constraints: [one_of: [:absorb_inventory, :write_off_cogs, :write_off_rd]]
          )

          attribute(:inputs, :map, public?: true, allow_nil?: false)
          attribute(:entry_id, :uuid, public?: true)
          attribute(:posted_at, :utc_datetime, public?: true)
        end

        relationships do
          belongs_to :standard, unquote(standard_mod) do
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

        identities do
          identity(:unique_variance, [:org_id, :cost_object_id, :period_key, :type])
        end

        changes do
          change({Samen.Policy.SameOrgFk, relationships: [:standard, :cost_object]})
        end

        actions do
          read :read do
            primary?(true)
            pagination(keyset?: true, required?: false)
          end

          # The system cascade's factory (VarianceEngine, `authorize?: false`):
          # records the fact AND posts its entry in ONE transaction. Not a
          # member-facing action.
          create :post do
            accept([
              :org_id,
              :standard_id,
              :cost_object_id,
              :period_key,
              :type,
              :amount_cents,
              :actual_amount_cents,
              :standard_amount_cents,
              :inputs
            ])

            change(
              {Samen.Scopes.Finance.VariancePosting,
               entry: unquote(entry_mod), posting_account: unquote(posting_account_mod)}
            )
          end

          # NO update / destroy: see the moduledoc.
        end

        policies do
          policy action_type(:read) do
            authorize_if(Samen.Policy.OrgScope)
          end

          policy action(:post) do
            forbid_if(always())
          end
        end
      end
    end
  end
end
