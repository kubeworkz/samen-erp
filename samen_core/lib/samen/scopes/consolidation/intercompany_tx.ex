defmodule Samen.Scopes.Consolidation.IntercompanyTx do
  @moduledoc """
  Multi-Company Intercompany Transaction (WS-ERP E24; Flectra-inspired).

  Records a transaction between two companies in the same group.
  These transactions must be eliminated during consolidation.

  ## Design

  - `group_id` — parent company group
  - `from_org_id` — selling/receiving company
  - `to_org_id` — buying/sending company
  - `transaction_type` — :sale | :purchase | :loan | :dividend | :service_fee
  - `amount` — transaction amount in minor units
  - `currency` — transaction currency
  - `exchange_rate` — conversion rate to group base currency
  - `amount_base` — amount in group base currency
  - `from_account_id` — account in the sender
  - `to_account_id` - account in the receiver
  - `reference` — transaction reference
  - `transaction_date` — when the transaction occurred
  - `state` — :draft | :posted | :eliminated
  - `eliminated_at` — when eliminated during consolidation

  No PII (INV-1). Archivable.
  """

  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.Core.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "cit",
    archivable: true

  postgres do
    table("cit_intercompany_tx")
    repo(SamenCore.TestRepo)
  end

  attributes do
    attribute(:group_id, :uuid, public?: true, allow_nil?: false)
    attribute(:from_org_id, :uuid, public?: true, allow_nil?: false)
    attribute(:to_org_id, :uuid, public?: true, allow_nil?: false)
    attribute(:transaction_type, :atom, public?: true, allow_nil?: false)
    attribute(:amount, :integer, public?: true, allow_nil?: false)
    attribute(:currency, :string, public?: true, allow_nil?: false, default: "USD")
    attribute(:exchange_rate, :float, public?: true, default: 1.0)
    attribute(:amount_base, :integer, public?: true, allow_nil?: false)
    attribute(:from_account_id, :uuid, public?: true)
    attribute(:to_account_id, :uuid, public?: true)
    attribute(:reference, :string, public?: true)
    attribute(:transaction_date, :date, public?: true, allow_nil?: false)
    attribute(:state, :atom, public?: true, allow_nil?: false, default: :draft)
    attribute(:eliminated_at, :utc_datetime_usec, public?: true)
  end

  actions do
    defaults([:read, create: :*, update: :*])
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
