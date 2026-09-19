defmodule Samen.Scopes.Pos.PosPayment do
  @moduledoc """
  POS Payment (WS-ERP E17; Flectra-inspired point of sale).

  A payment record against a POS order. An order can have multiple
  payments (split tender: part cash, part card).

  ## Design

  - `order_id` — the order being paid
  - `payment_method` — how the customer paid (cash, card, mobile, etc.)
  - `amount_cents` — the amount paid
  - `status` — `:pending` → `:completed` → `:refunded`
  - `reference` — optional: transaction reference (card auth code, etc.)
  - `paid_at` — when the payment was made

  ## State machine

  - `:pending` → `:completed` (payment confirmed)
  - `:completed` → `:refunded` (refund processed)

  No PII (INV-1). Archivable.
  """

  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.Core.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "zpy",
    archivable: true

  postgres do
    table("zpy_pos_payment")
    repo(SamenCore.TestRepo)
  end

  attributes do
    attribute(:order_id, :uuid, public?: true, allow_nil?: false)
    attribute(:payment_method, :string, public?: true, allow_nil?: false)
    attribute(:amount_cents, :integer, public?: true, allow_nil?: false)

    attribute(:status, :atom,
      public?: true,
      allow_nil?: false,
      default: :pending,
      constraints: [one_of: [:pending, :completed, :refunded]]
    )

    attribute(:reference, :string, public?: true)
    attribute(:paid_at, :utc_datetime, public?: true)
  end

  actions do
    defaults([:read])

    create :create do
      accept([:org_id, :order_id, :payment_method, :amount_cents, :reference, :paid_at])
    end

    update :complete do
      accept([:status, :paid_at])
    end

    update :refund do
      accept([:status])
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if(Samen.Policy.OrgScope)
    end

    policy action_type([:create, :update]) do
      forbid_unless(Samen.Policy.OrgScope)
      forbid_unless({Samen.Policy.RoleAtLeast, role: :member})
      authorize_if(always())
    end
  end
end
