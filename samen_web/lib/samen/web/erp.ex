defmodule Samen.Web.Erp do
  @moduledoc """
  The WS-ERP E8 TENANT SURFACE REGISTRY (design §6.4; build-plan E8 — "mountable
  tenant surfaces … declared in the router macros").

  TWO generic LiveViews serve the six ERP surfaces a host mounts with a
  single router line — `Samen.Web.Erp.SurfaceLive` (the bounded list at
  `<path>/<surface>`) and `Samen.Web.Erp.DetailLive` (the record page at
  `<path>/<surface>/<id>`):

      samen_erp_routes(:erp, SamenCore.Support.FinanceFixture, repo: SamenCore.TestRepo)

  The BOUNDARY is this module, not the caller:

    * `surfaces/0` — the CLOSED surface allowlist (the six design surfaces). A
      URL naming anything else is refused by `surface/1` (fail-closed — the
      caller's input can never mint a surface or a module).
    * `resource/2` — each surface's resource is DERIVED from the host's mounted
      namespace by the ADR-004 `Module.concat(namespace, name)` convention (the
      `Samen.Web.Mount.resource/2` mechanism). The host brings the mount; the
      registry brings the names; no caller input reaches either.
    * `columns/1` — the bounded per-surface column list the table renders. The
      surface CANNOT render a column outside its list — the roster's
      mask-by-omission discipline, applied to every ERP surface (the HR roster
      surface stays a SEPARATE E7 module because it wraps `Csv.export`; these
      surfaces are bounded READS with no export path at all).

  ## No PII on any surface

  Every column across all six surfaces is a bounded id, enum, integer cents,
  code/sku/number, or date. `Employee` (the one vault-routed ERP resource) has
  NO surface here — HR identity belongs to the E7 roster (`Samen.Web.Hr.Roster`)
  and its reveal-gated surface, never to a general ERP table. The headcount is
  the rollup's business (`shc_headcount_by_org`), the employee ledger's is the
  E7 surface's — this registry simply does not carry a people surface.

  ## Writes — the resources' OWN governed actions, never a surface-local path

  Every write the ERP surfaces offer is a form or button over the mounted
  resource's EXISTING action: `create_fields/1` and `edit_fields/1` mirror the
  actions' `accept` lists, `line_fields/1` mirrors the line argument shapes
  (journal lines, AP lines, PO lines), and `transitions/1` names only the
  `accept([])` state actions (`:post`/`:void`/`:approve`/`:release`/…). The
  LiveViews pass the caller's org-pinned scope (`Samen.Web.Mount.scope/2`) to
  `AshPhoenix.Form` — so the kernel's `OrgScope` + `RoleAtLeast :member`
  policies govern every write exactly as they govern a direct API call; the UI
  posture (`Samen.Web.Erp.Live.writable?/1`, tenant plane only) is cosmetic
  over that. There is still no destroy and no export path anywhere on these
  surfaces, and the DETAIL field lists stay bounded the same way `columns/1`
  bounds the table (no PII column exists on any ERP surface; `Employee` remains
  the E7 roster's business).
  """

  alias Samen.Web.Mount

  @type surface ::
          :coa | :entries | :ap_invoices | :stock | :purchase_orders | :work_orders

  @surfacedoc """
  The six design §6.4 tenant surfaces, each a bounded read over the host's
  mounted ERP namespaces:

    * `:coa`             — the Chart of Accounts (`Account`): code, name, kind,
      normal side, archived flag. The plan of record, read-only.
    * `:entries`         — the journal (`JournalEntry`): entry date, status,
      memo, posted-at. The audit surface over the event-sourced GL.
    * `:ap_invoices`     — the AP inbox (`ApInvoice`): number, vendor, dates,
      amount, status — the bills awaiting action.
    * `:stock`           — stock on hand (`Item`): SKU, name, kind, on-hand
      quantity, reorder point. The warehouse view over the ledger's rollup.
    * `:purchase_orders` — the PO inbox (`PurchaseOrder`): number, dates,
      status, committed total. What is ordered and what has arrived.
    * `:work_orders`     — the shop floor (`WorkOrder`): number, item, qty,
      status. What production has released and where it stands.
  """

  @surfaces [:coa, :entries, :ap_invoices, :stock, :purchase_orders, :work_orders]

  @doc @surfacedoc
  @spec surfaces() :: [surface(), ...]
  def surfaces, do: @surfaces

  @doc """
  Validate a caller-supplied surface name against the CLOSED allowlist. Anything
  else is `nil` — the surface LiveView renders its not-found state. There is no
  path from URL input to a resource module that does not go through here.
  """
  @spec surface(String.t() | atom() | nil) :: surface() | nil
  def surface(nil), do: nil

  def surface(name) when is_binary(name) do
    # `String.to_existing_atom/1` — the six surface atoms are compiled; a URL
    # can never mint a new one. The allowlist check is the boundary.
    atom = String.to_existing_atom(name)
    if atom in @surfaces, do: atom, else: nil
  rescue
    ArgumentError -> nil
  end

  def surface(atom) when is_atom(atom), do: if(atom in @surfaces, do: atom)

  @doc """
  The surface's resource, DERIVED from the host's mounted namespace (ADR-004).
  `nil` when the host has not mounted a namespace carrying that resource — the
  honest not-mounted state renders, never a crash.
  """
  @spec resource(Mount.t(), surface()) :: module() | nil
  def resource(%Mount{} = mount, :coa), do: derived(mount, :Account)
  def resource(%Mount{} = mount, :entries), do: derived(mount, :JournalEntry)
  def resource(%Mount{} = mount, :ap_invoices), do: derived(mount, :ApInvoice)
  def resource(%Mount{} = mount, :stock), do: derived(mount, :Item)
  def resource(%Mount{} = mount, :purchase_orders), do: derived(mount, :PurchaseOrder)
  def resource(%Mount{} = mount, :work_orders), do: derived(mount, :WorkOrder)

  defp derived(mount, name) do
    mod = Mount.resource(mount, name)
    if Code.ensure_loaded?(mod), do: mod
  end

  @doc """
  The surface's BOUNDED column list — the exact columns the table renders, in
  order. The LiveView cannot render a column outside its surface's list (the
  roster mask-by-omission discipline, generalized): the row renderer walks THIS
  list, never a caller's.
  """
  @spec columns(surface()) :: [atom()]
  def columns(:coa), do: [:code, :name, :kind, :normal_side]
  def columns(:entries), do: [:entry_date, :status, :memo, :posted_at]
  # AP/PO totals are Σ lines (the subledger shape) — the header surface shows
  # the document facts, the journal/GL carries the money.
  def columns(:ap_invoices), do: [:number, :vendor_id, :bill_date, :due_date, :status]

  # On-hand is a (item, warehouse) fact on the DERIVED `StockLevel` (and the
  # `spw` WIP rollup serves the BI read) — the Item master row carries the
  # planning floor, never a quantity that would go stale.
  def columns(:stock), do: [:sku, :name, :kind, :uom, :reorder_point]
  def columns(:purchase_orders), do: [:number, :order_date, :status]
  def columns(:work_orders), do: [:number, :qty, :status]

  @doc "The surface's sortable fields (the bounded ListLive `:sortable` list)."
  @spec sortable(surface()) :: [atom()]
  def sortable(:coa), do: [:code, :name]
  def sortable(:entries), do: [:entry_date, :status]
  def sortable(:ap_invoices), do: [:bill_date, :due_date]
  def sortable(:stock), do: [:sku, :qty_on_hand]
  def sortable(:purchase_orders), do: [:order_date, :status]
  def sortable(:work_orders), do: [:number, :status]

  @doc """
  The singular human label for one record of a surface — the "New …" button,
  the detail page's heading, and its not-found copy.
  """
  @spec record_label(surface()) :: String.t()
  def record_label(:coa), do: "Account"
  def record_label(:entries), do: "Journal entry"
  def record_label(:ap_invoices), do: "AP invoice"
  def record_label(:stock), do: "Item"
  def record_label(:purchase_orders), do: "Purchase order"
  def record_label(:work_orders), do: "Work order"

  @doc """
  The DETAIL page's bounded field list — the same mask-by-omission discipline
  as `columns/1`, one level deeper: the record page renders exactly these
  facts, never a caller's selection. Still no PII (INV-1): every field is a
  code/number/date/enum/foreign-key id.
  """
  @spec detail_fields(surface()) :: [atom()]
  def detail_fields(:coa), do: [:code, :name, :kind, :normal_side, :currency, :parent_id]
  def detail_fields(:entries), do: [:entry_date, :status, :memo, :source_key, :source_id, :posted_at, :inserted_at]
  def detail_fields(:ap_invoices), do: [:number, :vendor_id, :bill_date, :due_date, :memo, :status, :posted_at, :inserted_at]
  def detail_fields(:stock), do: [:sku, :name, :kind, :uom, :reorder_point, :inserted_at]
  def detail_fields(:purchase_orders), do: [:number, :vendor_id, :order_date, :memo, :status, :warehouse_id, :inserted_at]
  def detail_fields(:work_orders), do: [:number, :status, :qty, :scheduled_for, :memo, :item_id, :bom_id, :warehouse_id, :labor_cents, :overhead_cents, :released_at, :completed_at]

  @doc """
  A form field spec `{field, type, opts}` for the create modal — `type` is one
  of `:text | :number | :date | :select` (`opts` carries `options:` for a
  select). Every field here is in the surface's `:create` action's `accept`
  (server-derived facts like `org_id` are merged by the LiveView, never by the
  form); a field NOT accepted by the action can never appear here.
  """
  @spec create_fields(surface()) :: [{atom(), atom(), keyword()}, ...]
  def create_fields(:coa) do
    [
      {:code, :text, []},
      {:name, :text, []},
      {:kind, :select, [options: ~w(asset liability equity income expense)]},
      {:normal_side, :select, [options: ~w(debit credit)]},
      {:currency, :text, []}
    ]
  end

  def create_fields(:entries), do: [{:entry_date, :date, []}, {:memo, :text, []}]

  def create_fields(:ap_invoices) do
    [
      {:vendor_id, :text, [placeholder: "Vendor id (uuid)"]},
      {:number, :text, []},
      {:bill_date, :date, []},
      {:due_date, :date, []},
      {:memo, :text, []}
    ]
  end

  def create_fields(:stock) do
    [
      {:sku, :text, []},
      {:name, :text, []},
      {:kind, :select, [options: ~w(stocked non_stocked service)]},
      {:uom, :select, [options: ~w(unit case kg hour)]},
      {:reorder_point, :number, []}
    ]
  end

  def create_fields(:purchase_orders) do
    [
      {:vendor_id, :text, [placeholder: "Vendor id (uuid)"]},
      {:number, :text, []},
      {:order_date, :date, []},
      {:warehouse_id, :text, [placeholder: "Warehouse id (uuid)"]},
      {:memo, :text, []}
    ]
  end

  def create_fields(:work_orders) do
    [
      {:item_id, :text, [placeholder: "Item id (uuid)"]},
      {:bom_id, :text, [placeholder: "BOM id (uuid)"]},
      {:warehouse_id, :text, [placeholder: "Warehouse id (uuid)"]},
      {:number, :text, []},
      {:qty, :number, []},
      {:scheduled_for, :date, []},
      {:memo, :text, []},
      {:labor_cents, :number, []},
      {:overhead_cents, :number, []}
    ]
  end

  @doc """
  The bounded field list for the DETAIL page's Edit form — again exactly the
  surface's `:update` action's `accept`. Deliberately narrower than
  `create_fields/1` where the action is (e.g. a stock item's SKU and an
  account's code are identity fields the actions keep off the update path).
  """
  @spec edit_fields(surface()) :: [{atom(), atom(), keyword()}, ...]
  def edit_fields(:coa) do
    [
      {:name, :text, []},
      {:kind, :select, [options: ~w(asset liability equity income expense)]},
      {:normal_side, :select, [options: ~w(debit credit)]},
      {:currency, :text, []}
    ]
  end

  def edit_fields(:entries), do: [{:entry_date, :date, []}, {:memo, :text, []}]
  def edit_fields(:ap_invoices), do: [{:due_date, :date, []}, {:memo, :text, []}]

  def edit_fields(:stock) do
    [
      {:name, :text, []},
      {:kind, :select, [options: ~w(stocked non_stocked service)]},
      {:uom, :select, [options: ~w(unit case kg hour)]},
      {:reorder_point, :number, []}
    ]
  end

  def edit_fields(:purchase_orders) do
    [{:order_date, :date, []}, {:memo, :text, []}, {:warehouse_id, :text, [placeholder: "Warehouse id (uuid)"]}]
  end

  def edit_fields(:work_orders) do
    [
      {:scheduled_for, :date, []},
      {:memo, :text, []},
      {:labor_cents, :number, []},
      {:overhead_cents, :number, []}
    ]
  end

  @doc """
  The bounded column spec for one LINE row — used BOTH by the detail page's
  line table and the create form's line repeater. The three line-bearing
  surfaces name exactly the shape their action's line argument/attribute
  declares (journal lines, the AP bill's embedded lines, the PO's materialized
  lines); the other three carry no lines and render an empty list.
  """
  @spec line_fields(surface()) :: [{atom(), atom(), keyword()}, ...]
  def line_fields(:entries) do
    [
      {:account_id, :text, [placeholder: "Account id (uuid)"]},
      {:debit_cents, :number, []},
      {:credit_cents, :number, []},
      {:memo, :text, []}
    ]
  end

  def line_fields(:ap_invoices) do
    [
      {:account_id, :text, [placeholder: "Account id (uuid)"]},
      {:amount_cents, :number, []},
      {:memo, :text, []}
    ]
  end

  def line_fields(:purchase_orders) do
    [
      {:item_id, :text, [placeholder: "Item id (uuid)"]},
      {:qty, :number, []},
      {:unit_cost_cents, :number, []}
    ]
  end

  def line_fields(_surface), do: []

  @doc """
  The surface's GOVERNED state transitions as `{action, label, from_statuses}`
  — only `accept([])` actions (no caller inputs; the state machine guard owns
  the pre-state), rendered as detail-page buttons when the record's status is
  in `from_statuses`. Gate-guarded actions (`:approve`) honestly surface the
  opened approval as an inline banner when refused. `[]` for surfaces whose
  records have no direct transition (the CoA and the item master are config).
  """
  @spec transitions(surface()) :: [{atom(), String.t(), [atom()]}, ...]
  def transitions(:entries) do
    [
      {:post, "Post entry", [:draft]},
      {:void, "Void entry", [:posted]}
    ]
  end

  def transitions(:ap_invoices), do: [{:approve, "Approve bill", [:draft]}]

  def transitions(:purchase_orders) do
    [
      {:approve, "Approve PO", [:draft]},
      {:close, "Close PO", [:received]},
      {:void, "Void PO", [:draft, :approved, :sent]}
    ]
  end

  def transitions(:work_orders) do
    [
      {:release, "Release order", [:draft]},
      {:complete, "Complete order", [:released]},
      {:cancel, "Cancel order", [:draft, :released]}
    ]
  end

  def transitions(_surface), do: []

  @doc "The human label for a surface (the nav + heading)."
  @spec label(surface()) :: String.t()
  def label(:coa), do: "Chart of Accounts"
  def label(:entries), do: "Journal"
  def label(:ap_invoices), do: "AP Invoices"
  def label(:stock), do: "Stock"
  def label(:purchase_orders), do: "Purchase Orders"
  def label(:work_orders), do: "Work Orders"
end
