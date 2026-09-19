defmodule Samen.Scopes.Pos.PosOrder do
  @moduledoc """
  POS Order (WS-ERP E17; Flectra-inspired point of sale).

  A completed or in-progress sale at a POS terminal. Each order
  has line items, payments, and a total.

  ## Design

  - `pos_config_id` — which terminal this sale was made on
  - `order_number` — human-readable sequential number (unique per org)
  - `customer_id` — optional: the customer making the purchase
  - `status` — `:draft` (cart) → `:paid` → `:invoiced` → `:cancelled`
  - `subtotal_cents` — sum of line items before tax/discount
  - `tax_cents` — total tax
  - `discount_cents` — total discount
  - `total_cents` — final amount: subtotal + tax - discount
  - `payment_status` — `:unpaid` → `:partial` → `:paid`
  - `note` — freeform order note

  ## State machine

  - `:draft` → `:paid` (all payments received)
  - `:paid` → `:invoiced` (invoice generated)
  - `:draft` → `:cancelled` (void before payment)
  - `:paid` → `:cancelled` (refund)

  ## Financial integration

  When an order is `:paid`, a journal entry is posted:
    - **Debit** cash/receivable (payment method account)
    - **Credit** sales income
    - **Credit** tax payable

  This follows the same posting discipline as AP/AR (E2).

  No PII (INV-1). Archivable.
  """

  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.Core.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "zso",
    archivable: true

  postgres do
    table("zso_pos_order")
    repo(SamenCore.TestRepo)
  end

  attributes do
    attribute(:pos_config_id, :uuid, public?: true, allow_nil?: false)
    attribute(:order_number, :string, public?: true, allow_nil?: false)
    attribute(:customer_id, :uuid, public?: true)

    attribute(:status, :atom,
      public?: true,
      allow_nil?: false,
      default: :draft,
      constraints: [one_of: [:draft, :paid, :invoiced, :cancelled]]
    )

    attribute(:subtotal_cents, :integer, public?: true, allow_nil?: false, default: 0)
    attribute(:tax_cents, :integer, public?: true, allow_nil?: false, default: 0)
    attribute(:discount_cents, :integer, public?: true, allow_nil?: false, default: 0)
    attribute(:total_cents, :integer, public?: true, allow_nil?: false, default: 0)

    attribute(:payment_status, :atom,
      public?: true,
      allow_nil?: false,
      default: :unpaid,
      constraints: [one_of: [:unpaid, :partial, :paid]]
    )

    attribute(:note, :string, public?: true)
    attribute(:entry_id, :uuid, public?: true)
    attribute(:paid_at, :utc_datetime, public?: true)
  end

  actions do
    defaults([:read])

    create :create do
      accept([:org_id, :pos_config_id, :order_number, :customer_id, :note])
    end

    update :pay do
      accept([:payment_status, :paid_at])
    end

    update :cancel do
      accept([:status])
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if(Samen.Policy.OrgScope)
    end

    policy action_type([:create, :update, :destroy]) do
      forbid_unless(Samen.Policy.OrgScope)
      forbid_unless({Samen.Policy.RoleAtLeast, role: :member})
      authorize_if(always())
    end
  end
end
