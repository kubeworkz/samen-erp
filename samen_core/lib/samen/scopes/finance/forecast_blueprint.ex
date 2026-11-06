defmodule Samen.Scopes.Finance.ForecastBlueprint do
  @moduledoc """
  Resource definitions for the Finance scope's **rolling forecast** (WS-ACCT
  Phase 14; ADR-054 D11).

  Objects: `forecast_version` (the named, numbered, weighted scenario set) and
  `forecast_driver` (one bounded monthly driver fact inside a version).

  ## The version is a fact, not a worksheet

  A version carries a name, a monotonically increasing `version`, the date
  range it covers, its lifecycle status and exactly three scenario weights.
  Its drivers are rows, not a jsonb blob, so each month's input can be read,
  copied and audited without a spreadsheet evaluator. Rolling is a CREATE
  action that appends `version + 1` and copies the rows; a published version
  has no update, archive or delete route, and its drivers cannot be added to
  either.

  ## The driver tree is closed

  The doc's drivers are `slot_price`, `die_yield`, `eda_spend`, `headcount`,
  `burn` and `grant_pipeline`. The row's category is derived from that enum
  (`ForecastDriverGuard`) rather than accepted from the caller. The monetary
  amount is the driver's impact for its month; the reads roll the categories
  up. That is deliberately not a formula engine: the model says WHICH
  arithmetic applies, not how to evaluate an arbitrary expression.

  ## Reads are elsewhere

  `Samen.Scopes.Finance.ForecastRead` materializes P&L, cash flow, runway,
  scenario comparison, the actual-to-forecast bridge and accuracy. None of
  those numbers is stored here.
  """

  # ---------------------------------------------------------------------------
  # ForecastVersion — the append-only, weighted scenario set
  # ---------------------------------------------------------------------------
  defmacro define_forecast_version(module, otp_app, domain, repo, abbrev, driver_mod) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Finance.ForecastVersion — one named, numbered forecast (WS-ACCT Phase
        14; ADR-054 D11).

          * `name` + `version` — the append-only lineage. Rolling a published
            version creates the next number; it never edits the old row.
          * `starts_on`/`ends_on` — the months the forecast covers.
          * `scenario_weights` — exactly `base`, `upside`, `downside`, each
            between 0 and 1 and summing to 1.0.
          * `status` — `:draft` while drivers are being authored, `:published`
            when the version is signed for readers, `:archived` only for an
            abandoned draft.
          * `source_version_id` — the version a roll copied, when it is a roll.

        PUBLISHED IS IMMUTABLE. There is no update action at all; `:publish`
        and `:archive` are the only lifecycle transitions, and both refuse
        once the row is published. A changed forecast is a new version.

        No PII (INV-1): a bounded name, integers, dates, a closed enum, a
        numeric map and ids.
        """

        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_forecast_version")
          repo(unquote(repo))
        end

        attributes do
          attribute(:name, :string,
            public?: true,
            allow_nil?: false,
            constraints: [max_length: 120]
          )

          attribute(:version, :integer,
            public?: true,
            allow_nil?: false,
            constraints: [min: 1]
          )

          attribute(:starts_on, :date, public?: true, allow_nil?: false)
          attribute(:ends_on, :date, public?: true, allow_nil?: false)

          attribute(:status, :atom,
            public?: true,
            allow_nil?: false,
            default: :draft,
            constraints: [one_of: [:draft, :published, :archived]]
          )

          attribute(:scenario_weights, :map, public?: true, allow_nil?: false)
          attribute(:source_version_id, :uuid, public?: true)
          attribute(:published_at, :utc_datetime, public?: true)
        end

        relationships do
          has_many :drivers, unquote(driver_mod) do
            public?(true)
            destination_attribute(:version_id)
          end
        end

        identities do
          identity(:unique_forecast_version, [:org_id, :name, :version])
        end

        actions do
          read :read do
            primary?(true)
            pagination(keyset?: true, required?: false)
          end

          create :create do
            accept([:org_id, :name, :version, :starts_on, :ends_on, :scenario_weights])

            # The version's monthly drivers, materialized in this create's
            # transaction. A bad driver rolls the whole version back.
            argument(:drivers, {:array, :map}, allow_nil?: true)

            primary?(true)

            change(Samen.Scopes.Finance.ForecastWeights)
            change({Samen.Scopes.Finance.ForecastDriverWriter, driver: unquote(driver_mod)})
          end

          update :publish do
            accept([])
            require_atomic?(false)
            change({Samen.Scopes.Finance.ForecastPublication, op: :publish})
          end

          update :archive do
            accept([])
            require_atomic?(false)
            change({Samen.Scopes.Finance.ForecastPublication, op: :archive})
          end

          # APPEND-ONLY ROLL: a CREATE, not an update. The source row is read
          # and copied; the driver writer runs in the new version's transaction.
          create :roll do
            accept([:org_id])
            argument(:source_version_id, :uuid, allow_nil?: false)

            change({Samen.Scopes.Finance.ForecastRoller, driver: unquote(driver_mod)})
            change(Samen.Scopes.Finance.ForecastWeights)
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
  # ForecastDriver — one bounded monthly driver fact
  # ---------------------------------------------------------------------------
  defmacro define_forecast_driver(module, otp_app, domain, repo, abbrev, version_mod) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Finance.ForecastDriver — one bounded monthly driver fact inside a
        forecast version (WS-ACCT Phase 14; ADR-054 D11).

          * `driver` — the closed tree: `slot_price`, `die_yield`, `eda_spend`,
            `headcount`, `burn`, `grant_pipeline`.
          * `scenario` — `base`, `upside` or `downside`, matching the version's
            weights.
          * `period_on` — the first day of the forecast month, inside the
            version's range.
          * `amount_cents` — the driver's monetary impact for that month
            (non-negative; the category supplies the sign).
          * `category` — derived from `driver`, never caller input: revenue,
            cogs, operating expense, cash in or cash out.

        APPEND-ONLY. There is no update or destroy action; a corrected driver
        belongs to a new rolled version. The guard also refuses any create
        against a published version, so publication freezes the whole fact
        set, not just the header row.

        No PII (INV-1).
        """

        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_forecast_driver")
          repo(unquote(repo))
        end

        attributes do
          attribute(:driver, :atom,
            public?: true,
            allow_nil?: false,
            constraints: [
              one_of: [:slot_price, :die_yield, :eda_spend, :headcount, :burn, :grant_pipeline]
            ]
          )

          attribute(:scenario, :atom,
            public?: true,
            allow_nil?: false,
            constraints: [one_of: [:base, :upside, :downside]]
          )

          attribute(:category, :atom,
            public?: true,
            allow_nil?: false,
            default: :revenue,
            constraints: [one_of: [:revenue, :cogs, :operating_expense, :cash_in, :cash_out]]
          )

          attribute(:period_on, :date, public?: true, allow_nil?: false)

          attribute(:amount_cents, :integer,
            public?: true,
            allow_nil?: false,
            constraints: [min: 0]
          )

          attribute(:memo, :string, public?: true, constraints: [max_length: 500])
        end

        relationships do
          belongs_to :version, unquote(version_mod) do
            public?(true)
            attribute_type(:uuid)
            allow_nil?(false)
          end
        end

        identities do
          identity(:unique_forecast_driver, [:org_id, :version_id, :scenario, :driver, :period_on])
        end

        changes do
          change({Samen.Policy.SameOrgFk, relationships: [:version]})
        end

        actions do
          read :read do
            primary?(true)
            pagination(keyset?: true, required?: false)
          end

          create :create do
            accept([
              :org_id,
              :version_id,
              :driver,
              :scenario,
              :period_on,
              :amount_cents,
              :memo
            ])

            change({Samen.Scopes.Finance.ForecastDriverGuard, version: unquote(version_mod)})
          end

          # INTERNAL: the aggregate writer and the roll copier run after the
          # version row exists inside the same transaction, where a separate
          # guard lookup cannot see it. They supply the derived category
          # themselves; the public `:create` above remains guarded.
          create :system_create do
            accept([
              :org_id,
              :version_id,
              :driver,
              :scenario,
              :category,
              :period_on,
              :amount_cents,
              :memo
            ])
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

          policy action(:system_create) do
            forbid_if(always())
          end
        end
      end
    end
  end
end
