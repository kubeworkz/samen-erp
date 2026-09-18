defmodule Samen.Scopes.Inventory.LandedCost do
  @moduledoc """
  Landed Cost (WS-ERP E14; BigCapital-inspired).

  Additional costs (freight, duties, insurance) allocated to inventory
  items on a purchase bill. The landed cost increases the effective unit
  cost of the items, providing a more accurate inventory valuation.

  ## Design

  - `bill_id` — the purchase bill this landed cost is attached to
  - `amount_cents` — the total landed cost amount
  - `allocation_method` — `:value` (proportional to item value) or
    `:quantity` (proportional to item quantity)
  - `status` — `:draft` → `:allocated`
  - `cost_account_id` — the GL account for the landed cost (e.g., "Freight-In")

  ## Allocation

  When `:allocate` is called, the landed cost is distributed across the
  bill's line items using the chosen method:

  - **Value-proportional:** each item gets `item_value / total_value * landed_cost`
  - **Quantity-proportional:** each item gets `item_qty / total_qty * landed_cost`

  The allocation creates `LandedCostAllocation` records and adjusts the
  inventory unit cost for each item.

  ## Fail-closed invariant

  If the sum of allocations does not equal the landed cost amount (±1 cent),
  the allocation is refused. The landed cost must be fully allocated or not
  at all — partial allocation is not supported.
  """

  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.Core.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "lcd",
    archivable: true

  postgres do
    table("lcd_landed_cost")
    repo(SamenCore.TestRepo)
  end

  attributes do
    attribute(:bill_id, :uuid, public?: true, allow_nil?: false)
    attribute(:amount_cents, :integer, public?: true, allow_nil?: false)

    attribute(:allocation_method, :atom,
      public?: true,
      allow_nil?: false,
      default: :value,
      constraints: [one_of: [:value, :quantity]]
    )

    attribute(:status, :atom,
      public?: true,
      allow_nil?: false,
      default: :draft,
      constraints: [one_of: [:draft, :allocated]]
    )

    attribute(:cost_account_id, :uuid, public?: true, allow_nil?: false)
    attribute(:description, :string, public?: true)
  end

  actions do
    defaults([:read])

    create :create do
      accept([:org_id, :bill_id, :amount_cents, :allocation_method, :cost_account_id, :description])
    end

    update :allocate do
      accept([])
      change(Samen.Scopes.Inventory.LandedCostAllocator)
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
