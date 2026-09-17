defmodule Samen.Web.Erp do
  @moduledoc """
  The WS-ERP E8 TENANT SURFACE REGISTRY (design §6.4; build-plan E8 — "mountable
  tenant surfaces … declared in the router macros").

  ONE generic surface LiveView (`Samen.Web.Erp.SurfaceLive`) serves the six ERP
  surfaces a host mounts with a single router line:

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

  ## Writes

  These surfaces are READ-ONLY by construction: the mounted resources' writes
  ride their governed actions (the E1–E7 red paths prove them); the ERP surface
  adds no write affordance and its reads pass the caller's org-pinned scope
  (`Samen.Web.Mount.scope/2`) to the kernel's `OrgScope` policy — the org
  boundary is the policy, exactly as every other mounted surface.
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

  @doc "The human label for a surface (the nav + heading)."
  @spec label(surface()) :: String.t()
  def label(:coa), do: "Chart of Accounts"
  def label(:entries), do: "Journal"
  def label(:ap_invoices), do: "AP Invoices"
  def label(:stock), do: "Stock"
  def label(:purchase_orders), do: "Purchase Orders"
  def label(:work_orders), do: "Work Orders"
end
