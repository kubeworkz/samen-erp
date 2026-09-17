defmodule Samen.E8Aggregate do
  @moduledoc """
  The WS-ERP E8 cross-tenant **portfolio** projection (design §6.2): the
  token-blind aggregate plane's ERP-shaped view — revenue by industry across
  every tenant. Inherited machinery, zero new infrastructure: a
  `use Samen.Aggregate.Resource` projection (the C7 `no_pii_columns` verifier
  enforces the bounded-column shape at compile time) inside a separate,
  DEFAULT-DENY domain whose only admissible actor is the singleton
  `Samen.Aggregate.Actor` (`operator_aggregate`).

  A department, product line, or warehouse cohort under the k-anon floor
  renders `%Samen.Aggregate.Suppressed{}` — the design §6.2 clause, proven by
  the x1 red-paths.
  """
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(Samen.E8Aggregate.PortfolioByIndustry)
  end
end

defmodule Samen.E8Aggregate.PortfolioByIndustry do
  @moduledoc """
  Cross-tenant REVENUE by industry. A `use Samen.Aggregate.Resource`
  projection over the vault-excluded `sea_portfolio_by_industry` summary
  table. Every column is bounded / non-PII: `industry` (a coarse bucket, NOT
  a subject), `tenant_count` (the cohort SIZE for k-anon), `revenue_cents`
  (a count-shaped sum). NO `pii_attribute`, NO vault, NO relationship to a
  PII-bearing resource. Cross-tenant (no org boundary).
  """
  use Samen.Aggregate.Resource,
    otp_app: :samen_core,
    domain: Samen.E8Aggregate,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "sea"

  postgres do
    table("sea_portfolio_by_industry")
    repo(SamenCore.TestRepo)
  end

  attributes do
    # Cross-tenant aggregate: NO single org. Declared nullable to opt out of
    # the universal non-null org_id injection — a per-industry revenue spans
    # ALL tenants.
    attribute(:org_id, :uuid, public?: true, allow_nil?: true)
    attribute(:industry, :string, public?: true, allow_nil?: false)
    attribute(:tenant_count, :integer, public?: true, default: 0)
    attribute(:revenue_cents, :integer, public?: true, default: 0)
    attribute(:refreshed_at, :utc_datetime, public?: true)
  end

  actions do
    defaults([:read])
  end

  # DEFAULT DENY. Only the token-blind aggregate actor is admitted. No
  # fallthrough.
  policies do
    policy always() do
      authorize_if(Samen.Policy.AggregateActorOnly)
    end
  end

  @doc """
  The T4.5 cohort spec: the industry cohort's SIZE (k-anonymity) is
  `tenant_count`. The RELEASABLE value `revenue_cents` is suppressed when
  `tenant_count < k` (a single-tenant industry would leak that tenant's
  exact revenue to every operator).
  """
  def aggregate_cohort_spec do
    %Samen.Aggregate.CohortSpec{
      cohort_key_columns: [:industry],
      cohort_count_column: :tenant_count,
      distinct_sensitive_column: nil,
      value_columns: [:revenue_cents],
      sensitive_attribute: nil
    }
  end
end
