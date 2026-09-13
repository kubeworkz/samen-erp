defmodule Samen.Scopes.Inventory.Blueprint do
  @moduledoc """
  Resource-definition macros for the **Inventory** scope (WS-ERP E3;
  ADR-049 §3).

  Objects: `item · warehouse · stock_ledger · stock_level` — stock is a
  ledger too: the movement event is the fact, the level is a derived sum
  (`StockLevelSync` in-transaction), never a hand-maintained column.

  ## PII map — exactly one vault-routed field

  `Warehouse.address` is a `Samen.Type.Address` composite vaulted
  `:pii_address` (ADR-036 H4 — the `Locations.Location` posture verbatim:
  a warehouse address is a place, but the vault class exists so hosts that
  treat locations as sensitive keep the posture). Everything else is a
  bounded id, enum, integer, timestamp, or bounded text — INV-1 clean.
  """

  # ---------------------------------------------------------------------------
  # Item — the item master (Tier-0 config row)
  # ---------------------------------------------------------------------------

  defmacro define_item(module, otp_app, domain, repo, abbrev) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Inventory.Item — the item master (WS-ERP E3; design §3.1): `sku`
        (unique per org), `kind ∈ {stocked, non_stocked, service}`, `uom`
        (bounded enum — integer base-UOM is the binding decision;
        fractional/lot/serial is a documented non-goal), `reorder_point`
        (a floor, not an engine — auto-PO generation is a P2 carry), and
        the OPTIONAL Finance integration seam
        (`default_{income,expense,inventory}_account_id` — same-org FKs;
        an unlinked item simply never posts). No PII (INV-1).
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_item")
          repo(unquote(repo))
        end

        attributes do
          attribute(:sku, :string, public?: true, allow_nil?: false)
          attribute(:name, :string, public?: true, allow_nil?: false)

          attribute(:kind, :atom,
            public?: true,
            allow_nil?: false,
            default: :stocked,
            constraints: [one_of: [:stocked, :non_stocked, :service]]
          )

          attribute(:uom, :atom,
            public?: true,
            allow_nil?: false,
            default: :unit,
            constraints: [one_of: [:unit, :case, :kg, :hour]]
          )

          # A floor, not an engine: replenishment suggestions are a pure read;
          # auto-PO generation is a P2 carry (design §7 honesty list).
          attribute(:reorder_point, :integer, public?: true)

          # The Finance integration seam (E4's GoodsReceipt resolves the
          # inventory account here). Optional — an unlinked item never posts.
          # CROSS-SCOPE posture (the E2 precedent): plain uuid attributes, NO
          # belongs_to — Inventory's mount must not require Finance's, and the
          # ledger names its upstream without coupling to it (design §8).
          attribute(:default_income_account_id, :uuid, public?: true)
          attribute(:default_expense_account_id, :uuid, public?: true)
          attribute(:default_inventory_account_id, :uuid, public?: true)
        end

        actions do
          read :read do
            primary?(true)
            pagination(keyset?: true, required?: false)
          end

          create :create do
            # org_id is an explicit accept (the Automation-scope idiom): the
            # tenant-plane write names its own org; OrgScope + SameOrgFk govern it.
            accept([
              :org_id,
              :sku,
              :name,
              :kind,
              :uom,
              :reorder_point,
              :default_income_account_id,
              :default_expense_account_id,
              :default_inventory_account_id
            ])
          end

          update :update do
            accept([
              :name,
              :kind,
              :uom,
              :reorder_point,
              :default_income_account_id,
              :default_expense_account_id,
              :default_inventory_account_id
            ])

            require_atomic?(false)
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
    end
  end

  # ---------------------------------------------------------------------------
  # Warehouse — a stock location with real quantity semantics
  # ---------------------------------------------------------------------------

  defmacro define_warehouse(module, otp_app, domain, repo, abbrev) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Inventory.Warehouse — a stock location with real quantity
        semantics (WS-ERP E3; design §3.1): `code` (unique per org),
        `name`, `address` (🔒 vaulted `Samen.Type.Address` composite,
        `vault: :pii_address` — ADR-036 H4, the Locations.Location
        posture verbatim), `is_sellable`, and `allow_negative` — the
        per-warehouse NegativeStock opt-out (cycle-count realities;
        FAIL-CLOSED default `false`).
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_warehouse")
          repo(unquote(repo))
        end

        attributes do
          attribute(:code, :string, public?: true, allow_nil?: false)
          attribute(:name, :string, public?: true, allow_nil?: false)

          # The per-warehouse NegativeStock opt-out — cycle-count realities.
          # Fail-closed: the default warehouse NEVER goes below zero.
          attribute(:allow_negative, :boolean,
            public?: true,
            allow_nil?: false,
            default: false
          )

          attribute(:is_sellable, :boolean,
            public?: true,
            allow_nil?: false,
            default: true
          )
        end

        pii do
          vault(:pii_address)
          pii_attribute(:address, Samen.Type.Address, vault: :pii_address)
        end

        actions do
          read :read do
            primary?(true)
            pagination(keyset?: true, required?: false)
          end

          create :create do
            accept([:org_id, :code, :name, :address, :allow_negative, :is_sellable])
          end

          update :update do
            accept([:name, :address, :allow_negative, :is_sellable])
            require_atomic?(false)
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
    end
  end

  # ---------------------------------------------------------------------------
  # StockLedger — THE append-only movement event
  # ---------------------------------------------------------------------------

  defmacro define_stock_ledger(module, otp_app, domain, repo, abbrev, item_mod, warehouse_mod, level_mod) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Inventory.StockLedger — THE append-only movement event (WS-ERP E3;
        design §3.1): `item_id`, `warehouse_id`, `kind ∈ {receipt, issue,
        transfer_out, transfer_in, adjust, sale, production_in,
        production_consume}`, `qty` (SIGNED integer in the item's UOM — the
        binding base-UOM decision), `unit_cost_cents` (the moving-average
        cost SNAPSHOT at movement time), and the `source_key`/`source_id`
        object-ref anchor (goods receipt / PO / work order / sales order /
        manual adjust — the ledger names its upstream without coupling to
        it).

        APPEND-ONLY: no update action exists and the DB trigger refuses
        UPDATE and DELETE outright — a stock event is a fact, never a
        mutable row (the `mov`/`aud_event` discipline). Corrections are NEW
        events (`:adjust`). The level rollup is maintained in-transaction by
        `Samen.Scopes.Inventory.StockLevelSync`; R3 reconciles the two
        independently (`Samen.Scopes.Inventory.ReconcileStock`).
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_stock_ledger")
          repo(unquote(repo))
        end

        attributes do
          attribute(:kind, :atom,
            public?: true,
            allow_nil?: false,
            constraints: [
              one_of: [
                :receipt,
                :issue,
                :transfer_out,
                :transfer_in,
                :adjust,
                :sale,
                :production_in,
                :production_consume
              ]
            ]
          )

          # SIGNED integer in the item's UOM — the binding base-UOM decision
          # (fractional quantities are a documented non-goal, design §7).
          attribute(:qty, :integer, public?: true, allow_nil?: false)

          # The moving-average cost SNAPSHOT at movement time (integer cents;
          # non-negative — a movement never carries negative cost).
          attribute(:unit_cost_cents, :integer,
            public?: true,
            allow_nil?: false,
            default: 0,
            constraints: [min: 0]
          )

          # The ADR-041 §3.2 object-ref anchor.
          attribute(:source_key, :string, public?: true)
          attribute(:source_id, :uuid, public?: true)

          # Freeform user content — default-deny-CDC-excluded, not vaulted
          # (Work-scope parity).
          attribute(:note, :string, public?: true)
        end

        relationships do
          belongs_to :item, unquote(item_mod) do
            public?(true)
            attribute_type(:uuid)
            allow_nil?(false)
          end

          belongs_to :warehouse, unquote(warehouse_mod) do
            public?(true)
            attribute_type(:uuid)
            allow_nil?(false)
          end
        end

        changes do
          # F3.2 same-org FK: an event may only name same-org item + warehouse.
          change({Samen.Policy.SameOrgFk, relationships: [:item, :warehouse]})

          # The NegativeStock guard (fail-closed): a posting that would take
          # (item, warehouse) below zero is REFUSED unless the warehouse
          # opts out (`allow_negative: true`). Computes from the LIVE ledger
          # sum in-transaction (design §9 read-your-writes note). Runs on the
          # ONLY write action — stock events are born once, never edited. The
          # warehouse resource is a compile-time module param (design §8 —
          # never runtime coupling between scope files).
          change({Samen.Scopes.Inventory.NegativeStock,
            warehouse: unquote(warehouse_mod),
            ledger: unquote(module)})

          # The rollup writer: rebuilds the (org, item, warehouse) level row
          # from the ledger tail in AFTER_ACTION — inside the SAME Ecto
          # transaction as the event (design §9 read-your-writes: the level is
          # real-time-at-post, the belt marker + divergence check make it
          # derived-by-construction).
          change({Samen.Scopes.Inventory.StockLevelSync, level: unquote(level_mod)})
        end

        actions do
          read :read do
            primary?(true)
            pagination(keyset?: true, required?: false)
          end

          # The ONE write action. No update, no destroy — the DB belt refuses
          # them even if a host re-adds actions.
          create :record do
            accept([
              :org_id,
              :kind,
              :qty,
              :unit_cost_cents,
              :source_key,
              :source_id,
              :note,
              :item_id,
              :warehouse_id
            ])
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
    end
  end

  # ---------------------------------------------------------------------------
  # StockLevel — the derived rollup (design §3.1): (org, item, warehouse) ->
  # qty_on_hand / avg_unit_cost / stock_value. The ONLY sanctioned writer is
  # StockLevelSync (in-transaction, ledger-tail recompute). The `:hand_edit`
  # action exists as the DESIGN'S OWN NEGATIVE PROOF: it is admin-gated AND
  # belt-refused — a rollup row is a derived cache, and editing it does not
  # change the ledger, so the R3 sums immediately diverge (sabotage 304 walks
  # exactly this door). The E3-belt note explains why the belt refuses.
  # ---------------------------------------------------------------------------

  defmacro define_stock_level(module, otp_app, domain, repo, abbrev, item_mod, warehouse_mod) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Inventory.StockLevel — the ROLLUP (WS-ERP E3; design §3.1):
        `(org, item, warehouse)` -> `qty_on_hand`, `qty_on_order` (P2
        carry — always 0 in the base system; the field exists so the
        schema doesn't lie), `avg_unit_cost_cents` (moving average),
        `stock_value_cents`. NEVER a hand-written column: the ONLY
        sanctioned writer is `Samen.Scopes.Inventory.StockLevelSync`,
        which rebuilds the row from the ledger tail IN THE SAME
        TRANSACTION as the event (real-time-at-post; design §9
        read-your-writes note — the rollup serves reads between posts).

        The DB belt refuses any write WITHOUT the sync marker, and the
        `:hand_edit` action is the design's own negative proof: even an
        admin-gated raw edit of a level row is refused (and if a host
        disarms the belt, R3's independent sums diverge — the red-path
        catches it one layer down).
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_stock_level")
          repo(unquote(repo))
        end

        attributes do
          attribute(:qty_on_hand, :integer,
            public?: true,
            allow_nil?: false,
            default: 0
          )

          # P2 carry (replenishment engine): always 0 in the base system —
          # the column exists so the schema doesn't lie about the concept.
          attribute(:qty_on_order, :integer,
            public?: true,
            allow_nil?: false,
            default: 0
          )

          # Moving average: SUM(qty*cost) / SUM(qty) over valued events —
          # StockLevelSync's computation; NULL when nothing valued has moved.
          attribute(:avg_unit_cost_cents, :integer, public?: true)

          # Σ(qty * unit_cost_cents) over the (item, warehouse)'s events —
          # R3's value invariant.
          attribute(:stock_value_cents, :integer,
            public?: true,
            allow_nil?: false,
            default: 0
          )
        end

        relationships do
          belongs_to :item, unquote(item_mod) do
            public?(true)
            attribute_type(:uuid)
            allow_nil?(false)
          end

          belongs_to :warehouse, unquote(warehouse_mod) do
            public?(true)
            attribute_type(:uuid)
            allow_nil?(false)
          end
        end

        actions do
          read :read do
            primary?(true)
            pagination(keyset?: true, required?: false)
          end

          # The design's own negative proof (see the moduledoc): an admin
          # CAN ask to hand-edit a level row; the Ash layer allows, the DB
          # belt refuses (derived-cache discipline), and R3 is the second
          # net. This action MUST NOT be used by hosts — it exists so the
          # red path is exercised against a REAL door, not an invented one.
          update :hand_edit do
            accept([:qty_on_hand, :avg_unit_cost_cents, :stock_value_cents])
            require_atomic?(false)
          end

          # Upsert-shaped sync write, used by StockLevelSync inside the
          # event's transaction (belt-marker-armed). org_id is accepted
          # explicitly — the sync writer passes it like any fixture create.
          create :sync_write do
            accept([
              :org_id,
              :qty_on_hand,
              :avg_unit_cost_cents,
              :stock_value_cents,
              :item_id,
              :warehouse_id
            ])

            upsert?(true)
            upsert_identity(:unique_level)
            upsert_fields([:qty_on_hand, :avg_unit_cost_cents, :stock_value_cents])
          end
        end

        identities do
          identity :unique_level, [:org_id, :item_id, :warehouse_id]
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
