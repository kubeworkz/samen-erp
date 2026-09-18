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
  # E4 — the Procurement documents (design §3.2). Mounted ONLY with `finance:`
  # (see the scope macro's expansion-time branch). The PO posts NOTHING
  # (committed-not-realized); the GoodsReceipt is the ONE-transaction
  # chokepoint (GoodsPosting); ReceiptLine is R5's received-quantity fact.
  # ---------------------------------------------------------------------------

  defmacro define_purchase_order(module, otp_app, domain, repo, abbrev, po_line_mod, warehouse_mod) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Inventory.PurchaseOrder — the SCM document pair's head (WS-ERP E4;
        design §3.2): `vendor_id` (the SalesOps.Vendor reference, same-org —
        plain uuid, the E2 cross-scope posture), `number`, `order_date`,
        `warehouse_id` (the receiving sink for its receipts), `status ∈
        {draft, approved, sent, received, closed, void}`.

        **A PO posts NOTHING** (committed-not-realized — design §3.2):
        `:approve` rides the ADR-040 Gate exactly like the AP bill's (the
        ungated call fails `ApprovalRequired`; the DISTINCT approver's
        `approve/3` re-invokes the action inside the decision transaction)
        — but the cascade is the STATE TRANSITION only. No journal entry,
        no stock event: a PO is an intention, not a fact. Realization
        happens exclusively through `GoodsReceipt :receive`.

        Lines are REAL rows (`PoLine`, materialized by the `lines` argument
        in-transaction, the Finance EntryLines shape) and freeze when the PO
        leaves draft — the belt refuses later line edits (a received
        quantity must reconcile against the ordered quantity AS ORDERED).
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_purchase_order")
          repo(unquote(repo))
        end

        attributes do
          attribute(:vendor_id, :uuid, public?: true, allow_nil?: false)
          attribute(:number, :string, public?: true, allow_nil?: false)
          attribute(:order_date, :date, public?: true, allow_nil?: false)
          attribute(:memo, :string, public?: true)

          attribute(:status, :atom,
            public?: true,
            allow_nil?: false,
            default: :draft,
            constraints: [one_of: [:draft, :approved, :sent, :received, :closed, :void]]
          )
        end

        relationships do
          belongs_to :warehouse, unquote(warehouse_mod) do
            public?(true)
            attribute_type(:uuid)
            allow_nil?(false)
          end

          has_many :lines, unquote(po_line_mod) do
            public?(true)
            destination_attribute(:purchase_order_id)
          end
        end

        changes do
          # F3.2 same-org FK: a PO receives into a same-org warehouse.
          change({Samen.Policy.SameOrgFk, relationships: [:warehouse]})

          # The state machine guard (the ApLines shape): only a draft PO
          # edits/approves; :close needs :received; :void needs a pre-receipt
          # state. The belt trigger is the raw-SQL twin.
          change(Samen.Scopes.Inventory.PoState)

          # Materialize the `lines` argument into real PoLine rows on
          # create/draft-edit (the EntryLines shape — lines are born with
          # the PO or not at all).
          change(Samen.Scopes.Inventory.PoLinesWriter)
        end

        actions do
          read :read do
            primary?(true)
            pagination(keyset?: true, required?: false)
          end

          create :create do
            accept([:org_id, :vendor_id, :number, :order_date, :memo, :warehouse_id])

            argument(:lines, {:array, :map},
              allow_nil?: false,
              constraints: [
                items: [
                  fields: [
                    item_id: [type: :uuid, allow_nil?: false],
                    qty: [type: :integer, allow_nil?: false],
                    unit_cost_cents: [type: :integer, allow_nil?: false]
                  ]
                ]
              ]
            )

            # A PO is born a draft — the only route to :approved is :approve.
            change(set_attribute(:status, :draft))
          end

          update :update do
            # Draft edits only (PoLines refuses a non-draft record; the belt
            # is the twin). Line replacement re-materializes.
            accept([:order_date, :memo, :warehouse_id])

            argument(:lines, {:array, :map},
              allow_nil?: true,
              constraints: [
                items: [
                  fields: [
                    item_id: [type: :uuid, allow_nil?: false],
                    qty: [type: :integer, allow_nil?: false],
                    unit_cost_cents: [type: :integer, allow_nil?: false]
                  ]
                ]
              ]
            )

            require_atomic?(false)
          end

          # The gated transition: accept([]) — NO caller inputs (ADR-040
          # §4.4). The approval IS the state transition; nothing posts.
          # The stamp lands through the Gate's re-invocation, INSIDE the
          # decision transaction, under the posting marker (the belt admits
          # →approved ONLY under it — a raw-SQL approval cannot land).
          update :approve do
            accept([])
            require_atomic?(false)

            change({Samen.Approvals.Gate,
             kind: unquote(Atom.to_string(module)) <> ":approve"})

            change(Samen.Scopes.Finance.PostingMarker)

            change(set_attribute(:status, :approved))
          end

          # The cascade's internal transition (the `create_reversal` spirit):
          # GoodsReceipt :receive stamps :received through THIS action — not
          # `:update`, whose PoLinesWriter guard owns draft edits only. The
          # belt trigger admits an →:received transition ONLY under the
          # posting marker (armed by the :receive action), so the stamp is
          # exactly-once with the chokepoint. PoState guards the pre-state.
          update :mark_received do
            accept([])
            require_atomic?(false)

            # The transition itself. The DB belt admits →:received ONLY under
            # the posting marker — so this action alone cannot flip a PO; it
            # succeeds only inside the :receive chokepoint (which arms the
            # marker) with GoodsPosting's receivability check behind it.
            change(set_attribute(:status, :received))
          end

          # The later lifecycle states (the base system lands :received via
          # the first GoodsReceipt; :closed/:void are host lifecycle moves —
          # state-machine-guarded by PoState, never posting anything).
          update :close do
            accept([])
            require_atomic?(false)

            # PoState guards the pre-state (:received only).
            change(set_attribute(:status, :closed))
          end

          update :void do
            accept([])
            require_atomic?(false)

            # PoState guards the pre-state (pre-receipt only).
            change(set_attribute(:status, :void))
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

  defmacro define_po_line(module, otp_app, domain, repo, abbrev, po_mod, item_mod) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Inventory.PoLine — the PO's line row (WS-ERP E4): `item_id` (same-
        org), `qty` (positive integer), `unit_cost_cents` (non-negative).
        Immutable once the PO leaves draft — the receiving quantities
        reconcile against the ordered quantities AS ORDERED (R5's ordered
        side); the belt refuses UPDATE/DELETE on a non-draft PO's lines.
        Written only through the PO's actions (`PoLinesWriter`); the `:create`
        remains for system paths, SameOrgFk-guarded. No PII (INV-1).
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_po_line")
          repo(unquote(repo))
        end

        attributes do
          attribute(:qty, :integer, public?: true, allow_nil?: false)
          attribute(:unit_cost_cents, :integer,
            public?: true,
            allow_nil?: false,
            constraints: [min: 0]
          )
        end

        relationships do
          belongs_to :purchase_order, unquote(po_mod) do
            public?(true)
            attribute_type(:uuid)
            allow_nil?(false)
          end

          belongs_to :item, unquote(item_mod) do
            public?(true)
            attribute_type(:uuid)
            allow_nil?(false)
          end
        end

        changes do
          # F3.2 same-org FK on both referents.
          change({Samen.Policy.SameOrgFk, relationships: [:purchase_order, :item]})
        end

        actions do
          read :read do
            primary?(true)
            pagination(keyset?: true, required?: false)
          end

          create :create do
            accept([:org_id, :purchase_order_id, :item_id, :qty, :unit_cost_cents])
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

  defmacro define_goods_receipt(
             module,
             otp_app,
             domain,
             repo,
             abbrev,
             po_mod,
             po_line_mod,
             receipt_line_mod,
             warehouse_mod,
             ledger_mod,
             _level_mod,
             finance_entry_mod,
             finance_posting_account_mod
           ) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Inventory.GoodsReceipt — receiving against an approved PO (WS-ERP E4;
        design §3.2). `:receive` carries the `lines` argument
        (`po_line_id` + `qty`) and THE ONE-TRANSACTION CHOKEPOINT happens
        (`Samen.Scopes.Inventory.GoodsPosting`): per line, a `StockLedger
        :receipt` event AND the inventory-asset + AP-clearing `JournalEntry`
        (both anchored `source_key: "goods_receipt"`), plus the materialized
        `ReceiptLine` rows, plus the receipt's own flip to `:posted` and the
        PO's progression to `:received` — commit or roll back TOGETHER.

        Exactly-once per receipt; over-receipt (cumulative received >
        ordered, over the ReceiptLine facts) is refused; the inventory
        account resolves from the ITEM's Finance seam (an unlinked item
        never posts), `ap_clearing` from the org's PostingAccount map.
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_goods_receipt")
          repo(unquote(repo))
        end

        attributes do
          attribute(:number, :string, public?: true, allow_nil?: false)
          attribute(:received_date, :date, public?: true, allow_nil?: false)
          attribute(:memo, :string, public?: true)

          # status is NEVER caller-supplied: the only route to :posted is
          # :receive (GoodsPosting stamps it in-transaction).
          attribute(:status, :atom,
            public?: true,
            allow_nil?: false,
            default: :draft,
            constraints: [one_of: [:draft, :posted]]
          )

          attribute(:posted_entry_id, :uuid, public?: true)
          attribute(:received_at, :utc_datetime, public?: true)
        end

        relationships do
          belongs_to :purchase_order, unquote(po_mod) do
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
          # F3.2 same-org FK: a receipt receives against a same-org PO into
          # a same-org warehouse (the blueprint-level guard).
          change({Samen.Policy.SameOrgFk, relationships: [:purchase_order, :warehouse]})
        end

        actions do
          read :read do
            primary?(true)
            pagination(keyset?: true, required?: false)
          end

          create :create do
            accept([:org_id, :purchase_order_id, :warehouse_id, :number, :received_date, :memo])

            # A receipt is born a draft — the only route to :posted is :receive.
            change(set_attribute(:status, :draft))
          end

          # THE chokepoint (see the moduledoc). accept([]) — the facts come
          # from the `lines` ARGUMENT, never persisted caller inputs.
          update :receive do
            accept([])
            require_atomic?(false)

            argument(:lines, {:array, :map},
              allow_nil?: false,
              constraints: [
                items: [
                  fields: [
                    po_line_id: [type: :uuid, allow_nil?: false],
                    qty: [type: :integer, allow_nil?: false]
                  ]
                ]
              ]
            )

            # The belt marker for the receipt's own flip + the PO's stamp.
            change(Samen.Scopes.Finance.PostingMarker)

            change({Samen.Scopes.Inventory.GoodsPosting,
              po_line: unquote(po_line_mod),
              receipt_line: unquote(receipt_line_mod),
              ledger: unquote(ledger_mod),
              entry: unquote(finance_entry_mod),
              posting_account: unquote(finance_posting_account_mod)})
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

  defmacro define_receipt_line(module, otp_app, domain, repo, abbrev, receipt_mod, po_line_mod) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Inventory.ReceiptLine — the materialized received-quantity fact per
        `{receipt, po_line}` (WS-ERP E4): R5's RECEIVED side, written by
        `GoodsPosting` inside the chokepoint transaction, immutable once
        written (no update action; the belt refuses writes outside the
        chokepoint). `qty` is the received quantity at the PO line's cost —
        the cumulative sum per po_line is the over-receipt floor and the
        three-way match's received input. No PII (INV-1).
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_receipt_line")
          repo(unquote(repo))
        end

        attributes do
          attribute(:qty, :integer, public?: true, allow_nil?: false)
          attribute(:unit_cost_cents, :integer,
            public?: true,
            allow_nil?: false,
            constraints: [min: 0]
          )
        end

        relationships do
          belongs_to :goods_receipt, unquote(receipt_mod) do
            public?(true)
            attribute_type(:uuid)
            allow_nil?(false)
          end

          belongs_to :po_line, unquote(po_line_mod) do
            public?(true)
            attribute_type(:uuid)
            allow_nil?(false)
          end
        end

        changes do
          # F3.2 same-org FK on both referents.
          change({Samen.Policy.SameOrgFk, relationships: [:goods_receipt, :po_line]})
        end

        actions do
          read :read do
            primary?(true)
            pagination(keyset?: true, required?: false)
          end

          create :create do
            accept([:org_id, :goods_receipt_id, :po_line_id, :qty, :unit_cost_cents])
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

  # ── E5: the SalesOrder bridge (present ONLY when the mount wires BOTH
  # `finance:` and `billing:`) ─────────────────────────────────────────────────

  defmacro define_sales_order(
             module,
             otp_app,
             domain,
             repo,
             abbrev,
             so_line_mod,
             warehouse_mod,
             ledger_mod,
             level_mod,
             billing_invoice_mod
           ) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Inventory.SalesOrder — stock's DEMAND document (WS-ERP E5; design
        §3.3): `customer_id` (same-org, plain uuid — the E2/E4 cross-scope
        posture), optional `opportunity_id` (the CRM anchor: Lead →
        Opportunity → SO is the governed chain — a walkthrough, not new
        machinery), `number`, `order_date`, `warehouse_id` (the fulfilling
        sink), `status ∈ {draft, confirmed, fulfilled, cancelled}`.

        A SO posts NOTHING until `:fulfill` — THE bridge event: per line, a
        `StockLedger :sale` event (qty NEGATIVE in the item's UOM, cost =
        the rollup's moving-average snapshot, anchored
        `source_key: "sales_order"`) AND the emission of the host's Billing
        invoice (status `:open`, `amount_due` = Σ qty×price, the line items
        as the bounded jsonb) — stock and billing commit or roll back
        TOGETHER, the `GoodsReceipt :receive` discipline applied to demand.
        NegativeStock runs resource-wide on the ledger creates: selling more
        than on-hand is refused fail-closed (unless the warehouse opted
        out). `:fulfill` consumes the order's OWN frozen lines — no partial
        shipments in the base system (the documented P2 carry).

        The SO anchors its emitted invoice with `invoice_key`/`invoice_id`
        — the SAME ADR-041 §3.2 shape `PaymentReceipt` intakes — so
        Lead → Opportunity → SO → Invoice → Receipt → GL is one governed
        chain where every link already has a home.
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_sales_order")
          repo(unquote(repo))
        end

        attributes do
          attribute(:customer_id, :uuid, public?: true, allow_nil?: false)
          attribute(:opportunity_id, :uuid, public?: true)
          attribute(:number, :string, public?: true, allow_nil?: false)
          attribute(:order_date, :date, public?: true, allow_nil?: false)
          attribute(:memo, :string, public?: true)

          attribute(:status, :atom,
            public?: true,
            allow_nil?: false,
            default: :draft,
            constraints: [one_of: [:draft, :confirmed, :fulfilled, :cancelled]]
          )

          # The emitted-invoice anchor (the PaymentReceipt contract shape):
          # `"billing_invoice"` + the host invoice row's id. Set ONLY by the
          # `:fulfill` cascade, in-transaction.
          attribute(:invoice_key, :string, public?: true)
          attribute(:invoice_id, :uuid, public?: true)
          attribute(:fulfilled_at, :utc_datetime, public?: true)
        end

        relationships do
          belongs_to :warehouse, unquote(warehouse_mod) do
            public?(true)
            attribute_type(:uuid)
            allow_nil?(false)
          end

          has_many :lines, unquote(so_line_mod) do
            public?(true)
            destination_attribute(:sales_order_id)
          end
        end

        changes do
          # F3.2 same-org FK: a SO fulfills from a same-org warehouse.
          change({Samen.Policy.SameOrgFk, relationships: [:warehouse]})

          # The state machine guard (the PoState shape).
          change(Samen.Scopes.Inventory.SoState)

          # Materialize the `lines` argument into real SoLine rows on
          # create/draft-edit (the PoLinesWriter shape).
          change(Samen.Scopes.Inventory.SoLinesWriter)
        end

        actions do
          read :read do
            primary?(true)
            pagination(keyset?: true, required?: false)
          end

          create :create do
            accept([
              :org_id,
              :customer_id,
              :opportunity_id,
              :number,
              :order_date,
              :memo,
              :warehouse_id
            ])

            argument(:lines, {:array, :map},
              allow_nil?: false,
              constraints: [
                items: [
                  fields: [
                    item_id: [type: :uuid, allow_nil?: false],
                    qty: [type: :integer, allow_nil?: false],
                    unit_price_cents: [type: :integer, allow_nil?: false]
                  ]
                ]
              ]
            )

            # A SO is born a draft — the only route to :confirmed is :confirm.
            change(set_attribute(:status, :draft))
          end

          update :update do
            # Draft edits only (SoState refuses a non-draft record; the belt
            # is the twin). Line replacement re-materializes.
            accept([:order_date, :memo, :warehouse_id, :customer_id, :opportunity_id])

            argument(:lines, {:array, :map},
              allow_nil?: true,
              constraints: [
                items: [
                  fields: [
                    item_id: [type: :uuid, allow_nil?: false],
                    qty: [type: :integer, allow_nil?: false],
                    unit_price_cents: [type: :integer, allow_nil?: false]
                  ]
                ]
              ]
            )

            require_atomic?(false)
          end

          # The salesperson's commitment: draft → confirmed. No approval —
          # a sale is not a spend (no Gate; the contrast with :approve is
          # the design's point).
          update :confirm do
            accept([])
            require_atomic?(false)

            change(set_attribute(:status, :confirmed))
          end

          # THE bridge (see the moduledoc). accept([]) — the facts come from
          # the order's own frozen lines, never caller inputs. The belt
          # marker arms the SO's own flip; the ledger creates run
          # NegativeStock + StockLevelSync resource-wide.
          update :fulfill do
            accept([])
            require_atomic?(false)

            change(Samen.Scopes.Finance.PostingMarker)

            change({Samen.Scopes.Inventory.FulfillOrder,
              so_line: unquote(so_line_mod),
              ledger: unquote(ledger_mod),
              level: unquote(level_mod),
              invoice: unquote(billing_invoice_mod)})
          end

          update :cancel do
            accept([])
            require_atomic?(false)

            # SoState guards the pre-state (pre-fulfillment only).
            change(set_attribute(:status, :cancelled))
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

  defmacro define_so_line(module, otp_app, domain, repo, abbrev, so_mod, item_mod) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Inventory.SoLine — the SO's line row (WS-ERP E5): `item_id`
        (same-org), `qty` (positive integer — the DEMAND quantity),
        `unit_price_cents` (non-negative — the SALE price; the ledger's cost
        side is the moving average at fulfillment, never the sale price).
        Immutable once the SO leaves draft — fulfillment consumes the order
        AS ORDERED (the belt refuses later line edits). Written only through
        the SO's actions (`SoLinesWriter`); the `:create` remains for system
        paths, SameOrgFk-guarded. No PII (INV-1).
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_so_line")
          repo(unquote(repo))
        end

        attributes do
          attribute(:qty, :integer, public?: true, allow_nil?: false)
          attribute(:unit_price_cents, :integer,
            public?: true,
            allow_nil?: false,
            constraints: [min: 0]
          )
        end

        relationships do
          belongs_to :sales_order, unquote(so_mod) do
            public?(true)
            attribute_type(:uuid)
            allow_nil?(false)
          end

          belongs_to :item, unquote(item_mod) do
            public?(true)
            attribute_type(:uuid)
            allow_nil?(false)
          end
        end

        changes do
          # F3.2 same-org FK on both referents.
          change({Samen.Policy.SameOrgFk, relationships: [:sales_order, :item]})
        end

        actions do
          read :read do
            primary?(true)
            pagination(keyset?: true, required?: false)
          end

          create :create do
            accept([:org_id, :sales_order_id, :item_id, :qty, :unit_price_cents])
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

        changes do
          # F3.2 same-org FK: the rollup row may only name same-org item +
          # warehouse (the blueprint-level guard — the samenerp host gate's
          # F3.5 sweep caught its omission).
          change({Samen.Policy.SameOrgFk, relationships: [:item, :warehouse]})
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

  # ---------------------------------------------------------------------------
  # TransferOrder — multi-warehouse transfer (WS-ERP E13)
  # ---------------------------------------------------------------------------
  defmacro define_transfer_order(module, otp_app, domain, repo, abbrev) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Inventory.TransferOrder — multi-warehouse transfer (WS-ERP E13).
        Coordinates transfer_out + transfer_in in one transaction.
        No PII (INV-1). Archivable.
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev),
          archivable: true

        postgres do
          table("#{unquote(abbrev)}_transfer_order")
          repo(unquote(repo))
        end

        attributes do
          attribute(:item_id, :uuid, public?: true, allow_nil?: false)
          attribute(:source_warehouse_id, :uuid, public?: true, allow_nil?: false)
          attribute(:dest_warehouse_id, :uuid, public?: true, allow_nil?: false)
          attribute(:qty, :integer, public?: true, allow_nil?: false)
          attribute(:status, :atom, public?: true, allow_nil?: false, default: :draft,
            constraints: [one_of: [:draft, :posted]])
          attribute(:note, :string, public?: true)
          attribute(:posted_at, :utc_datetime, public?: true)
        end

        actions do
          defaults([:read])
          create :create do
            accept([:org_id, :item_id, :source_warehouse_id, :dest_warehouse_id, :qty, :note])
          end
          update :post do
            accept([])
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
    end
  end

  # ---------------------------------------------------------------------------
  # LandedCost — additional costs on inventory imports (WS-ERP E14)
  # ---------------------------------------------------------------------------
  defmacro define_landed_cost(module, otp_app, domain, repo, abbrev) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Inventory.LandedCost — additional costs on inventory imports (WS-ERP E14).
        Freight, duties, insurance allocated to item cost. No PII. Archivable.
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev),
          archivable: true

        postgres do
          table("#{unquote(abbrev)}_landed_cost")
          repo(unquote(repo))
        end

        attributes do
          attribute(:bill_id, :uuid, public?: true, allow_nil?: false)
          attribute(:amount_cents, :integer, public?: true, allow_nil?: false)
          attribute(:allocation_method, :atom, public?: true, allow_nil?: false, default: :value,
            constraints: [one_of: [:value, :quantity]])
          attribute(:status, :atom, public?: true, allow_nil?: false, default: :draft,
            constraints: [one_of: [:draft, :allocated]])
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
    end
  end
end
