defmodule Samen.Scopes.Inventory.TransferOrder do
  @moduledoc """
  Transfer Order (WS-ERP E13; BigCapital-inspired warehouse transfers).

  Coordinates a two-sided stock movement between warehouses:
  1. `:transfer_out` at the source warehouse (debit)
  2. `:transfer_in` at the destination warehouse (credit)

  Both movements happen in ONE transaction — the same cross-row-cascade
  discipline as `GoodsReceipt` (E4) and `ProduceWo` (E6).

  ## Design

  - `item_id` — the item being transferred (must be the same item at both ends)
  - `source_warehouse_id` — where the stock leaves
  - `dest_warehouse_id` — where the stock arrives
  - `qty` — positive integer in the item's base UOM
  - `status` — `:draft` → `:posted` (no void — a transfer is a fact)
  - `note` — freeform description

  ## Invariants

  - **Same item.** Source and destination must stock the same item (enforced
    by the resource — both movements reference the same `item_id`).
  - **Same org.** Both warehouses must belong to the same org (enforced by
    `OrgScope` policy).
  - **Source has stock.** The source warehouse must have `qty_on_hand >= qty`
    (the `NegativeStock` guard — `allow_negative: false` is the default).
  - **Double-entry.** The two movements net to zero for the org-wide stock
    level (one warehouse gains what the other loses).

  ## Fail-closed invariant

  If either movement fails, the entire transfer rolls back — the source
  warehouse is never debited without the destination being credited.
  """

  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.Core.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "trn",
    archivable: true

  postgres do
    table("trn_transfer_order")
    repo(SamenCore.TestRepo)
  end

  attributes do
    attribute(:item_id, :uuid, public?: true, allow_nil?: false)
    attribute(:source_warehouse_id, :uuid, public?: true, allow_nil?: false)
    attribute(:dest_warehouse_id, :uuid, public?: true, allow_nil?: false)
    attribute(:qty, :integer, public?: true, allow_nil?: false)

    attribute(:status, :atom,
      public?: true,
      allow_nil?: false,
      default: :draft,
      constraints: [one_of: [:draft, :posted]]
    )

    attribute(:note, :string, public?: true)
    attribute(:posted_at, :utc_datetime, public?: true)
  end

  actions do
    defaults([:read])

    create :create do
      accept([:org_id, :item_id, :source_warehouse_id, :dest_warehouse_id, :qty, :note])
      change(Samen.Scopes.Inventory.TransferGuard)
    end

    update :post do
      accept([])
      change(Samen.Scopes.Inventory.TransferGuard)
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
