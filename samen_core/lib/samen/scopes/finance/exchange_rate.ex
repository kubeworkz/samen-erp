defmodule Samen.Scopes.Finance.ExchangeRate do
  @moduledoc """
  Exchange rate storage (WS-ERP E10; BigCapital-inspired multi-currency).

  Stores historical rates per currency pair with timestamps. Each row is
  an immutable fact — once posted, the rate cannot be changed (the same
  immutability posture as JournalLine and StockLedger).

  ## Design

  - `from_currency` / `to_currency` — ISO 4217 codes (e.g., "USD", "EUR")
  - `rate` — the exchange rate as a rational string (e.g., "0.92" means
    1 USD = 0.92 EUR). Stored as a string to avoid floating-point drift;
    conversion multiplies the source amount by the rate.
  - `source` — where the rate came from: `:manual`, `:api`, or `:import`
  - `valid_at` — the timestamp this rate is valid for (historical snapshot)

  Rates are org-scoped. A rate from USD→EUR is NOT the same as EUR→USD —
  both must be stored explicitly (no implicit inversion). This prevents
  subtle bugs when rates are asymmetric.

  ## Fail-closed invariant

  Posting a transaction in a non-base currency without a stored rate for
  that pair at that time is refused by `FxConversionGuard`. The GL never
  records an FX conversion with an unknown rate.
  """

  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.Core.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "fxr",
    archivable: false

  postgres do
    table("fxr_exchange_rate")
    repo(SamenCore.TestRepo)
  end

  attributes do
    attribute(:from_currency, :string, public?: true, allow_nil?: false)
    attribute(:to_currency, :string, public?: true, allow_nil?: false)

    # Stored as a string to avoid floating-point drift.
    # "1.0" means 1 unit of from_currency = 1 unit of to_currency.
    attribute(:rate, :string, public?: true, allow_nil?: false)

    attribute(:source, :atom,
      public?: true,
      allow_nil?: false,
      default: :manual,
      constraints: [one_of: [:manual, :api, :import]]
    )

    attribute(:valid_at, :utc_datetime, public?: true, allow_nil?: false)
  end

  actions do
    defaults([:read])

    create :create_rate do
      accept([:from_currency, :to_currency, :rate, :source, :valid_at, :org_id])
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if(Samen.Policy.OrgScope)
    end

    policy action_type(:create) do
      forbid_unless(Samen.Policy.OrgScope)
      forbid_unless({Samen.Policy.RoleAtLeast, role: :member})
      authorize_if(always())
    end
  end
end
