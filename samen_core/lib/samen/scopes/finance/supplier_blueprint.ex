defmodule Samen.Scopes.Finance.SupplierBlueprint do
  @moduledoc """
  Resource definitions for the Finance scope's **supplier governance** (WS-ACCT
  Phase 15; ADR-054 D18).

  Objects: `supplier_scorecard` (one quarterly scorecard per supplier), its
  five weighted `supplier_scorecard_dimension` rows, and `supplier_risk` (one
  row in the 5×5 risk register).

  ## Vendor references only

  Every object names the supplier by `vendor_id`; the supplier's contact data
  stays in `SalesOps.Vendor`'s vault. There is deliberately no contact, email,
  phone or owner-person column here. `owner_role` is a closed role enum, not a
  person id or name.

  ## Derived, never stored

  The scorecard's composite and letter grade are calculated from the weighted
  dimension rows by `Samen.Scopes.Finance.SupplierGovernance`; the risk's
  likelihood × impact rating and band are derived by the same read. Storing
  either would create a second, stale answer.

  ## Lifecycle

  A scorecard is appended as one complete aggregate: the header create accepts
  the five dimension rows and the writer lands them in the same transaction,
  or the whole create rolls back. The dimension rows are internal and have no
  public create, update or destroy route. Risks are editable because a
  mitigation plan and review status change over time, but they have no destroy
  route either.
  """

  @dimensions [
    :quality_yield,
    :delivery_schedule,
    :cost_commercial,
    :technical_support,
    :compliance_sustainability
  ]

  @owner_roles [
    :procurement_lead,
    :quality_lead,
    :finance_lead,
    :operations_lead,
    :engineering_lead,
    :compliance_lead,
    :executive
  ]

  @risk_categories [
    :quality,
    :delivery,
    :cost,
    :compliance,
    :financial,
    :operational,
    :strategic,
    :geopolitical
  ]

  # ---------------------------------------------------------------------------
  # SupplierScorecard — one quarterly, weighted supplier scorecard
  # ---------------------------------------------------------------------------
  defmacro define_supplier_scorecard(module, otp_app, domain, repo, abbrev, dimension_mod) do
    identity_index = "#{abbrev}_supplier_scorecard_unique"

    quote do
      defmodule unquote(module) do
        @moduledoc """
        Finance.SupplierScorecard — one quarterly supplier scorecard (WS-ACCT
        Phase 15; ADR-054 D18).

          * `vendor_id` — the SalesOps.Vendor reference. This resource never
            carries a supplier contact, email, phone or person name.
          * `period_year` / `period_quarter` — the reporting period, unique per
            vendor and org.
          * `dimensions` — the five weighted dimension rows materialized by the
            create action: quality/yield, delivery/schedule, cost/commercial,
            technical support and compliance/sustainability.

        The composite score and letter grade are derived reads over the
        dimension rows, never columns on this table. A scorecard is created as
        one complete aggregate; there is no update or destroy route, so its
        recorded dimensions cannot silently drift after the fact.
        """

        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_supplier_scorecard")
          repo(unquote(repo))
          identity_index_names(unique_supplier_scorecard: unquote(identity_index))
        end

        attributes do
          attribute(:vendor_id, :uuid, public?: true, allow_nil?: false)

          attribute(:period_year, :integer,
            public?: true,
            allow_nil?: false,
            constraints: [min: 2000, max: 2100]
          )

          attribute(:period_quarter, :integer,
            public?: true,
            allow_nil?: false,
            constraints: [min: 1, max: 4]
          )
        end

        relationships do
          has_many :dimensions, unquote(dimension_mod) do
            public?(true)
            destination_attribute(:scorecard_id)
          end
        end

        identities do
          identity(:unique_supplier_scorecard, [
            :org_id,
            :vendor_id,
            :period_year,
            :period_quarter
          ])
        end

        actions do
          read :read do
            primary?(true)
            pagination(keyset?: true, required?: false)
          end

          create :create do
            primary?(true)
            accept([:org_id, :vendor_id, :period_year, :period_quarter])

            argument(:dimensions, {:array, :map}, allow_nil?: false)

            change(
              {Samen.Scopes.Finance.SupplierScorecardWriter, dimension: unquote(dimension_mod)}
            )
          end
        end

        policies do
          policy action_type(:read) do
            authorize_if(Samen.Policy.OrgScope)
          end

          policy action_type(:create) do
            forbid_unless(Samen.Policy.OrgScope)
            forbid_unless({Samen.Policy.RoleAtLeast, role: :admin})
            authorize_if(always())
          end
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # SupplierScorecardDimension — one weighted dimension of a scorecard
  # ---------------------------------------------------------------------------
  defmacro define_supplier_scorecard_dimension(
             module,
             otp_app,
             domain,
             repo,
             abbrev,
             scorecard_mod
           ) do
    dimensions = @dimensions
    identity_index = "#{abbrev}_supplier_scorecard_dimension_unique"

    quote do
      defmodule unquote(module) do
        @moduledoc """
        Finance.SupplierScorecardDimension — one weighted dimension of a
        quarterly supplier scorecard (WS-ACCT Phase 15; ADR-054 D18).

          * `dimension` — the closed five-part model:
            `quality_yield`, `delivery_schedule`, `cost_commercial`,
            `technical_support`, `compliance_sustainability`.
          * `weight_pct` — the dimension's percentage of the composite; the
            five rows must sum to exactly 100.
          * `score` — the 1–5 assessment for the period.
          * `note` — optional bounded evidence/comment; freeform text, not PII.

        Rows are internal: only the scorecard writer creates them, inside the
        header's transaction. There is no public create, update or destroy
        route.
        """

        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_supplier_scorecard_dimension")
          repo(unquote(repo))
          identity_index_names(unique_supplier_scorecard_dimension: unquote(identity_index))
        end

        attributes do
          attribute(:dimension, :atom,
            public?: true,
            allow_nil?: false,
            constraints: [one_of: unquote(dimensions)]
          )

          attribute(:weight_pct, :integer,
            public?: true,
            allow_nil?: false,
            constraints: [min: 1, max: 100]
          )

          attribute(:score, :integer,
            public?: true,
            allow_nil?: false,
            constraints: [min: 1, max: 5]
          )

          attribute(:note, :string, public?: true, constraints: [max_length: 300])
        end

        relationships do
          belongs_to :scorecard, unquote(scorecard_mod) do
            public?(true)
            attribute_type(:uuid)
            allow_nil?(false)
          end
        end

        identities do
          identity(:unique_supplier_scorecard_dimension, [
            :org_id,
            :scorecard_id,
            :dimension
          ])
        end

        actions do
          read :read do
            primary?(true)
            pagination(keyset?: true, required?: false)
          end

          # INTERNAL: the scorecard writer creates these after the header row
          # exists in the same transaction.
          create :system_create do
            accept([:org_id, :scorecard_id, :dimension, :weight_pct, :score, :note])
          end
        end

        policies do
          policy action_type(:read) do
            authorize_if(Samen.Policy.OrgScope)
          end

          policy action(:system_create) do
            forbid_if(always())
          end
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # SupplierRisk — one 5×5 supplier risk register row
  # ---------------------------------------------------------------------------
  defmacro define_supplier_risk(module, otp_app, domain, repo, abbrev) do
    owner_roles = @owner_roles
    risk_categories = @risk_categories
    identity_index = "#{abbrev}_supplier_risk_unique"

    quote do
      defmodule unquote(module) do
        @moduledoc """
        Finance.SupplierRisk — one row in the supplier 5×5 risk register
        (WS-ACCT Phase 15; ADR-054 D18).

          * `vendor_id` — the SalesOps.Vendor reference; no contact or person
            data is copied here.
          * `likelihood` / `impact` — each 1–5. Their product is the rating;
            the derived read maps it to low/medium/high/critical and an
            escalation route.
          * `mitigation` and `escalation_trigger` — the required control text.
          * `owner_role` — a closed role enum, never a person's name or id.
          * `status` and `reviewed_on` — the register's review state.

        The rating and band are derived reads, never stored columns. The
        register is editable (mitigations and statuses change) but has no
        destroy route.
        """

        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_supplier_risk")
          repo(unquote(repo))
          identity_index_names(unique_supplier_risk: unquote(identity_index))
        end

        attributes do
          attribute(:vendor_id, :uuid, public?: true, allow_nil?: false)

          attribute(:code, :string,
            public?: true,
            allow_nil?: false,
            constraints: [max_length: 32]
          )

          attribute(:title, :string,
            public?: true,
            allow_nil?: false,
            constraints: [max_length: 240]
          )

          attribute(:category, :atom,
            public?: true,
            allow_nil?: false,
            constraints: [one_of: unquote(risk_categories)]
          )

          attribute(:likelihood, :integer,
            public?: true,
            allow_nil?: false,
            constraints: [min: 1, max: 5]
          )

          attribute(:impact, :integer,
            public?: true,
            allow_nil?: false,
            constraints: [min: 1, max: 5]
          )

          attribute(:mitigation, :string,
            public?: true,
            allow_nil?: false,
            constraints: [max_length: 1000]
          )

          attribute(:owner_role, :atom,
            public?: true,
            allow_nil?: false,
            constraints: [one_of: unquote(owner_roles)]
          )

          attribute(:escalation_trigger, :string,
            public?: true,
            allow_nil?: false,
            constraints: [max_length: 500]
          )

          attribute(:status, :atom,
            public?: true,
            allow_nil?: false,
            default: :open,
            constraints: [one_of: [:open, :mitigating, :accepted, :closed]]
          )

          attribute(:reviewed_on, :date, public?: true)
        end

        identities do
          identity(:unique_supplier_risk, [:org_id, :vendor_id, :code])
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
              :vendor_id,
              :code,
              :title,
              :category,
              :likelihood,
              :impact,
              :mitigation,
              :owner_role,
              :escalation_trigger,
              :status,
              :reviewed_on
            ])
          end

          update :update do
            accept([
              :code,
              :title,
              :category,
              :likelihood,
              :impact,
              :mitigation,
              :owner_role,
              :escalation_trigger,
              :status,
              :reviewed_on
            ])
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
end
