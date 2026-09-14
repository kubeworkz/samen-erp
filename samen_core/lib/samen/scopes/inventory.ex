defmodule Samen.Scopes.Inventory do
  @moduledoc """
  The **Inventory** universal scope (WS-ERP E3; ADR-049 §3): stock is a
  ledger too. Ships as a **library-authored blueprint** (ADR-004), same
  shape as `Samen.Scopes.Finance`: `use`-ing this module inside a host's
  Ash domain expands into FOUR host-owned resources in the host's
  namespace, each a normal `use Samen.Resource` with the host's `otp_app`,
  `repo`, and `domain`.

  ## Resources — `item · warehouse · stock_ledger · stock_level`

  - **`Item`** — the item master (Tier-0 config row): `sku` (unique per
    org), `name`, `kind ∈ {stocked, non_stocked, service}`, `uom` (bounded
    enum: unit/case/kg/hour — integer base-UOM is the binding decision;
    fractional UOM is a documented non-goal), `reorder_point` (a floor,
    not an engine — auto-PO generation is a P2 carry), and the optional
    Finance integration seam (`default_income_account_id` /
    `default_expense_account_id` / `default_inventory_account_id` — an
    unlinked item simply never posts). No PII (INV-1).
  - **`Warehouse`** — a stock location with real quantity semantics:
    `code` (unique per org), `name`, `address` (🔒 vaulted
    `Samen.Type.Address` composite, `vault: :pii_address` — ADR-036 H4,
    exactly the Locations.Location posture: a place, but the vault class
    exists so hosts that treat locations as sensitive keep the posture),
    `is_sellable`, and `allow_negative` (the per-warehouse NegativeStock
    opt-out — cycle-count realities; fail-closed default `false`).
  - **`StockLedger`** — THE append-only movement event (the `mov` /
    `aud_event` discipline applied to quantity): `item_id`, `warehouse_id`,
    `kind ∈ {receipt, issue, transfer_out, transfer_in, adjust, sale,
    production_in, production_consume}`, `qty` (SIGNED integer in the
    item's UOM), `unit_cost_cents` (the moving-average cost SNAPSHOT at
    movement time), `source_key`/`source_id` (the ADR-041 §3.2 object-ref
    anchor: goods receipt / PO / work order / sales order / manual
    adjust), `note`. NO update action exists; the DB trigger refuses
    UPDATE and DELETE outright.
  - **`StockLevel`** — the rollup (design §3.1): `(org, item, warehouse)`
    → `qty_on_hand`, `qty_on_order`, `avg_unit_cost_cents`, `stock_value_cents`.
    **Never a hand-written column** — `Samen.Scopes.Inventory.StockLevelSync`
    rebuilds the row in the SAME transaction as the ledger event, and
    `Samen.Scopes.Inventory.ReconcileStock` recomputes both sums via bare
    SQL over the ledger for R3.

  ## R3 — the Inventory↔Ledger reconciliation (LOAD-BEARING)

  For any `(item, warehouse)`: the rollup's `qty_on_hand` == Σ ledger
  `qty`, and the rollup's `stock_value_cents` == Σ (`qty` ×
  `unit_cost_cents`) over the valued events. The equality is computed by
  `Samen.Scopes.Inventory.ReconcileStock` INDEPENDENTLY of the sync writer
  (bare SQL over the ledger — the two sums share only the org id, never a
  code path), so a bypass that edits the rollup or skips the ledger
  DIVERGES and the red-path fails. Non-vacuous via anti-tautology
  (sabotage 304's hand-edit flips the R3 red paths).

  ## The NegativeStock guard (fail-closed)

  A ledger posting that would take `(item, warehouse)` below zero is
  REFUSED — `Samen.Scopes.Inventory.NegativeStock` computes the would-be
  balance from the LIVE ledger sum (in-transaction; design §9's
  read-your-writes note) and refuses; a warehouse with `allow_negative:
  true` opts out explicitly (cycle-count realities). The DB trigger
  enforces the same floor over the persisted rows, so even a raw-SQL
  event into a guard-on warehouse cannot go negative.

  ## Mounting the Inventory scope (the host side)

      defmodule Demo.InventoryScope do
        use Ash.Domain, validate_config_inclusion?: false

        use Samen.Scopes.Inventory,
          otp_app: :demo,
          repo: Demo.Repo,
          namespace: Demo.InventoryScope

  This defines, in the host's namespace:

    * `Demo.InventoryScope.Item`
    * `Demo.InventoryScope.Warehouse`
    * `Demo.InventoryScope.StockLedger`
    * `Demo.InventoryScope.StockLevel`

  ## The Procurement documents (E4 — the Finance↔Inventory chokepoint)

  A mount that ALSO passes `finance:` (the host's Finance entry + posting-
  account modules, compile-time — design §8's cross-scope posture) gets the
  design §3.2 document pair, mounted as four more host resources:

    * **`PurchaseOrder`** — `vendor_id`, `number`, `order_date`, embedded-free
      real `PoLine` rows (`item_id`, `qty`, `unit_cost_cents`), `status ∈
      {draft, approved, sent, received, closed, void}`. `:approve` rides the
      ADR-040 Gate exactly like the AP bill's — but a PO posts NOTHING
      (committed-not-realized): the approval transitions the state machine
      only. `:sent`/`:closed`/`:void` are later lifecycle states (the base
      system lands `:approved`/`:received`).
    * **`PoLine`** — the PO's line rows: `po_id`, `item_id` (same-org), `qty`
      (positive integer), `unit_cost_cents` (non-negative). Immutable once
      the PO leaves draft (the belt refuses; draft edits re-materialize).
    * **`GoodsReceipt`** — receiving against approved PO lines. `:receive`
      takes the `lines` argument (`po_line_id` + `qty`) and THE ONE-
      TRANSACTION CHOKEPOINT happens: per line, a `StockLedger :receipt`
      event (qty in, cost = the PO line's cost, anchored `source_key:
      "goods_receipt"`) AND the inventory-asset + AP-clearing `JournalEntry`
      (anchored the same), plus the materialized `ReceiptLine` rows — commit
      or roll back TOGETHER. Over-receipt (cumulative received > ordered) is
      refused; the receipt flip is exactly-once.
    * **`ReceiptLine`** — the materialized received-quantity facts per
      `{receipt, po_line}` (R5's received side), immutable once written.

  R3-full: for every goods receipt, the ledger events == the receipt lines
  and the GL entry == the received value (`ReconcileProcurement`). R5: AP
  bill ≤ PO + GR at tolerance (`ThreeWayMatch`).

  ## Abbrevs (permanent, registry-checked)

  Each resource carries a permanent 3-letter abbrev, reserved in
  `samen_core/priv/abbrev_registry.json` under the HOST module name via
  `mix samen.abbrev.reserve` (ADR-023 — the macro does NOT invent
  abbrevs):

    * `Demo.InventoryScope.Item`        → `ini` (demo default)
    * `Demo.InventoryScope.Warehouse`   → `inw` (demo default)
    * `Demo.InventoryScope.StockLedger` → `inl` (demo default)
    * `Demo.InventoryScope.StockLevel`  → `ins` (demo default)
    * `Demo.InventoryScope.PurchaseOrder` → `ipo` (demo default, E4)
    * `Demo.InventoryScope.PoLine`      → `ipl` (demo default, E4)
    * `Demo.InventoryScope.GoodsReceipt` → `igr` (demo default, E4)
    * `Demo.InventoryScope.ReceiptLine` → `ird` (demo default, E4)

  Other hosts pass `abbrevs:` overrides (mirroring
  `Samen.Scopes.Finance`'s `abbrevs:` plumbing) when the defaults are
  already claimed.
  """

  # Demo defaults are UNCLAIMED-in-the-registry abbrevs (ADR-025 discipline —
  # verified free against priv/abbrev_registry.json at authoring time). A host
  # whose namespace already claims one of these passes `abbrevs:` overrides
  # (allocator-reserved, ADR-023).
  @default_abbrevs %{
    item: "ini",
    warehouse: "inw",
    stock_ledger: "inl",
    stock_level: "ins",
    purchase_order: "ipo",
    po_line: "ipl",
    goods_receipt: "igr",
    receipt_line: "ird",
    sales_order: "iso",
    so_line: "iol",
    bom: "ibo",
    bom_line: "ibl",
    work_order: "iwo",
    production_log: "ipg"
  }

  @doc false
  def default_abbrevs, do: @default_abbrevs

  defmacro __using__(opts) do
    otp_app = Keyword.fetch!(opts, :otp_app) |> Macro.expand(__CALLER__)
    repo = Keyword.fetch!(opts, :repo) |> Macro.expand(__CALLER__)
    namespace = Keyword.fetch!(opts, :namespace) |> Macro.expand(__CALLER__)
    domain = __CALLER__.module

    # Resolve abbrevs to a plain %{atom => string} map AT EXPANSION TIME so each
    # blueprint call receives a LITERAL abbrev string (mirrors Samen.Scopes.Finance —
    # the base macro validates abbrevs caller-side and requires a compile-time literal).
    abbrevs = resolve_abbrevs(Keyword.get(opts, :abbrevs), __CALLER__)

    item_mod = Module.concat(namespace, Item)
    warehouse_mod = Module.concat(namespace, Warehouse)
    ledger_mod = Module.concat(namespace, StockLedger)
    level_mod = Module.concat(namespace, StockLevel)

    # The E6 Manufacturing documents ride the BASE mount unconditionally:
    # manufacturing is a posting FACADE over the scope's own ledger (design
    # §4 — "zero new quantity mechanisms"), so it needs no cross-scope
    # modules and every Inventory host carries it.
    bom_mod = Module.concat(namespace, Bom)
    bom_line_mod = Module.concat(namespace, BomLine)
    work_order_mod = Module.concat(namespace, WorkOrder)
    production_log_mod = Module.concat(namespace, ProductionLog)

    # The E4 Procurement documents compile ONLY when the mount wires
    # `finance:` — the chokepoint needs the host's Finance entry +
    # posting-account modules at compile time (an Inventory-only host mounts
    # none of these). Decided OUTSIDE the quote (macro-expansion time), with
    # each branch's modules/abbrevs pre-resolved to expansion-time values.
    finance_opts = Keyword.get(opts, :finance)

    # The E5 SalesOrder bridge compiles ONLY when the mount wires `billing:`
    # (the host's Billing Invoice surface — or a mirror shaped like its
    # money/status contract). Fulfillment emits the invoice INTO that module.
    billing_opts = Keyword.get(opts, :billing)

    e4_defines =
      if finance_opts do
        purchase_order_mod = Module.concat(namespace, PurchaseOrder)
        po_line_mod = Module.concat(namespace, PoLine)
        goods_receipt_mod = Module.concat(namespace, GoodsReceipt)
        receipt_line_mod = Module.concat(namespace, ReceiptLine)

        finance_entry = Keyword.fetch!(finance_opts, :entry)
        finance_posting_account = Keyword.fetch!(finance_opts, :posting_account)

        quote do
          resources do
            resource(unquote(purchase_order_mod))
            resource(unquote(po_line_mod))
            resource(unquote(goods_receipt_mod))
            resource(unquote(receipt_line_mod))
          end

          Samen.Scopes.Inventory.Blueprint.define_purchase_order(
            unquote(purchase_order_mod),
            unquote(otp_app),
            unquote(domain),
            unquote(repo),
            unquote(abbrevs.purchase_order),
            unquote(po_line_mod),
            unquote(warehouse_mod)
          )

          Samen.Scopes.Inventory.Blueprint.define_po_line(
            unquote(po_line_mod),
            unquote(otp_app),
            unquote(domain),
            unquote(repo),
            unquote(abbrevs.po_line),
            unquote(purchase_order_mod),
            unquote(item_mod)
          )

          Samen.Scopes.Inventory.Blueprint.define_goods_receipt(
            unquote(goods_receipt_mod),
            unquote(otp_app),
            unquote(domain),
            unquote(repo),
            unquote(abbrevs.goods_receipt),
            unquote(purchase_order_mod),
            unquote(po_line_mod),
            unquote(receipt_line_mod),
            unquote(warehouse_mod),
            unquote(ledger_mod),
            unquote(level_mod),
            unquote(finance_entry),
            unquote(finance_posting_account)
          )

          Samen.Scopes.Inventory.Blueprint.define_receipt_line(
            unquote(receipt_line_mod),
            unquote(otp_app),
            unquote(domain),
            unquote(repo),
            unquote(abbrevs.receipt_line),
            unquote(goods_receipt_mod),
            unquote(po_line_mod)
          )
        end
      else
        :ok
      end

    e5_defines =
      if finance_opts && billing_opts do
        sales_order_mod = Module.concat(namespace, SalesOrder)
        so_line_mod = Module.concat(namespace, SoLine)

        billing_invoice = Keyword.fetch!(billing_opts, :invoice)

        quote do
          resources do
            resource(unquote(sales_order_mod))
            resource(unquote(so_line_mod))
          end

          Samen.Scopes.Inventory.Blueprint.define_sales_order(
            unquote(sales_order_mod),
            unquote(otp_app),
            unquote(domain),
            unquote(repo),
            unquote(abbrevs.sales_order),
            unquote(so_line_mod),
            unquote(warehouse_mod),
            unquote(ledger_mod),
            unquote(level_mod),
            unquote(billing_invoice)
          )

          Samen.Scopes.Inventory.Blueprint.define_so_line(
            unquote(so_line_mod),
            unquote(otp_app),
            unquote(domain),
            unquote(repo),
            unquote(abbrevs.so_line),
            unquote(sales_order_mod),
            unquote(item_mod)
          )
        end
      else
        :ok
      end

    quote do
      require Samen.Scopes.Inventory.Blueprint
      require Samen.Scopes.Inventory.BlueprintE6

      resources do
        resource(unquote(item_mod))
        resource(unquote(warehouse_mod))
        resource(unquote(ledger_mod))
        resource(unquote(level_mod))
      end

      Samen.Scopes.Inventory.Blueprint.define_item(
        unquote(item_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.item)
      )

      Samen.Scopes.Inventory.Blueprint.define_warehouse(
        unquote(warehouse_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.warehouse)
      )

      Samen.Scopes.Inventory.Blueprint.define_stock_ledger(
        unquote(ledger_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.stock_ledger),
        unquote(item_mod),
        unquote(warehouse_mod),
        unquote(level_mod)
      )

      Samen.Scopes.Inventory.Blueprint.define_stock_level(
        unquote(level_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.stock_level),
        unquote(item_mod),
        unquote(warehouse_mod)
      )

      # ── E4: the Procurement documents (present ONLY when the mount wired
      # `finance:` — see the expansion-time branch above) ──
      unquote(e4_defines)

      # ── E5: the SalesOrder bridge (present ONLY when BOTH `finance:` and
      # `billing:` are wired — fulfillment needs the stock machinery AND the
      # host's invoice surface) ──
      unquote(e5_defines)

      # ── E6: Manufacturing — BOM/WorkOrder/ProductionLog, always present
      # (the posting facade needs only this scope's own machinery) ──
      resources do
        resource(unquote(bom_mod))
        resource(unquote(bom_line_mod))
        resource(unquote(work_order_mod))
        resource(unquote(production_log_mod))
      end

      Samen.Scopes.Inventory.BlueprintE6.define_bom(
        unquote(bom_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.bom),
        unquote(item_mod),
        unquote(bom_line_mod),
        unquote(work_order_mod)
      )

      Samen.Scopes.Inventory.BlueprintE6.define_bom_line(
        unquote(bom_line_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.bom_line),
        unquote(bom_mod),
        unquote(item_mod)
      )

      Samen.Scopes.Inventory.BlueprintE6.define_work_order(
        unquote(work_order_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.work_order),
        unquote(item_mod),
        unquote(bom_mod),
        unquote(bom_line_mod),
        unquote(warehouse_mod),
        unquote(ledger_mod),
        unquote(level_mod),
        unquote(production_log_mod)
      )

      Samen.Scopes.Inventory.BlueprintE6.define_production_log(
        unquote(production_log_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.production_log),
        unquote(work_order_mod),
        unquote(item_mod)
      )
    end
  end

  defp resolve_abbrevs(nil, _caller), do: @default_abbrevs

  defp resolve_abbrevs({:%{}, _, pairs}, caller) do
    override =
      Map.new(pairs, fn {k, v} ->
        {Macro.expand(k, caller), Macro.expand(v, caller)}
      end)

    Map.merge(@default_abbrevs, override)
  end

  defp resolve_abbrevs(other, _caller) do
    raise ArgumentError,
          "use Samen.Scopes.Inventory, abbrevs: must be a compile-time map literal " <>
            "(%{item: \"ini\", warehouse: \"inw\", stock_ledger: \"inl\", stock_level: \"ins\"}). Got: " <>
            Macro.to_string(other)
  end
end
