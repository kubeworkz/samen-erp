defmodule Samen.Scopes.Pos.PosOrderLine do
  @moduledoc """
  POS Order Line (WS-ERP E17; point of sale).

  A line item on a POS order — represents one product in the cart.

  ## Design

  - `order_id` — the parent order
  - `product_id` — the product being sold
  - `product_name` — snapshot of the product name at time of sale
  - `qty` — quantity (positive integer for sales, negative for returns)
  - `unit_price_cents` — price per unit at time of sale
  - `discount_percent` — line-level discount (0-100)
  - `tax_rate_id` — optional: tax rate applied to this line
  - `tax_cents` — computed tax for this line
  - `line_total_cents` — final line total: qty * unit_price * (1 - discount/100) + tax

  Lines are append-only after the order is paid (same immutability
  posture as JournalLine).

  No PII (INV-1).
  """

  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.Core.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "zsl",
    archivable: false

  postgres do
    table("zsl_pos_order_line")
    repo(SamenCore.TestRepo)
  end

  attributes do
    attribute(:order_id, :uuid, public?: true, allow_nil?: false)
    attribute(:product_id, :uuid, public?: true, allow_nil?: false)
    attribute(:product_name, :string, public?: true, allow_nil?: false)
    attribute(:qty, :integer, public?: true, allow_nil?: false, default: 1)
    attribute(:unit_price_cents, :integer, public?: true, allow_nil?: false)
    attribute(:discount_percent, :float, public?: true, allow_nil?: false, default: 0.0)
    attribute(:tax_rate_id, :uuid, public?: true)
    attribute(:tax_cents, :integer, public?: true, allow_nil?: false, default: 0)
    attribute(:line_total_cents, :integer, public?: true, allow_nil?: false, default: 0)
  end

  actions do
    defaults([:read])

    create :create do
      accept([:org_id, :order_id, :product_id, :product_name, :qty, :unit_price_cents,
              :discount_percent, :tax_rate_id, :tax_cents, :line_total_cents])
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
