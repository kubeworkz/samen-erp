defmodule Samenerp.ErpWalkthroughTest do
  @moduledoc """
  The WS-ERP E8 HOST PROOF (build-plan E8: "the `samenerp` host mounts all
  scopes + surfaces at ≈0 authored LOC (pawchart-shaped proof)") — the E5
  governed walkthrough, replayed on a REAL host namespace with the host's
  OWN abbrevs, REAL Billing invoice as the emission target, and the
  surfaces registry resolving every mounted resource.

  Blocks:

    * the E3 core: stock events land in the append-only host ledger, the
      derived level matches (the belt + `StockLevelSync` on `Samenerp.Repo`);
    * the E4 chokepoint: a PO `:receive` posts the stock event AND the GL
      journal entry in ONE transaction — cross-scope, on the host mount;
    * the E5 bridge: a SalesOrder `:fulfill` consumes stock and emits the
      invoice into the host's REAL Billing mount (`Samenerp.Billing.Invoice`);
    * the surfaces registry: all six `Samen.Web.Erp` surfaces resolve REAL
      host resources by the ADR-004 derivation (`Module.concat`), every
      bounded column exists on its resource, and an unknown surface is
      refused (the closed allowlist).
  """

  use Samenerp.DataCase, async: false

  require Ash.Query

  alias Samen.Web.Erp
  alias Samenerp.Billing.Invoice
  alias Samenerp.Erp.{
    Account,
    Item,
    JournalEntry,
    PostingAccount,
    PurchaseOrder,
    SalesOrder,
    StockLedger,
    Warehouse,
    WorkOrder
  }

  setup do
    org = Ecto.UUID.generate()

    scope = %Samen.Scope{
      actor: %{id: "u:#{org}", org_id: org, role: :member, kind: :tenant, plane: :tenant}
    }

    admin_scope = %Samen.Scope{
      actor: %{id: "a:#{org}", org_id: org, role: :admin, kind: :tenant, plane: :tenant}
    }

    {:ok, org: org, scope: scope, admin: admin_scope}
  end

  test "the E3 core: ledger facts + derived level on the host mount", %{org: org, scope: scope} do
    item =
      Item
      |> Ash.Changeset.for_create(:create, %{
        org_id: org,
        sku: "ERP-1",
        name: "ERP Item",
        kind: :stocked,
        uom: :unit
      })
      |> Ash.create!(scope: scope, authorize?: true)

    wh =
      Warehouse
      |> Ash.Changeset.for_create(:create, %{org_id: org, code: "MAIN", name: "Main"})
      |> Ash.create!(scope: scope, authorize?: true)

    for {kind, qty} <- [receipt: 30, sale: -5] do
      StockLedger
      |> Ash.Changeset.for_create(:record, %{
        org_id: org,
        item_id: item.id,
        warehouse_id: wh.id,
        kind: kind,
        qty: qty,
        unit_cost_cents: 1_000
      })
      |> Ash.create!(scope: scope, authorize?: true)
    end

    level =
      Ash.read!(Samenerp.Erp.StockLevel, scope: scope, authorize?: true)
      |> Enum.find(&(&1.item_id == item.id and &1.warehouse_id == wh.id))

    assert level.qty_on_hand == 25
  end

  test "the E4 chokepoint: PO receive posts stock + GL in ONE transaction", %{org: org, scope: scope, admin: admin} do
    posting_map = [
      {:ap_clearing, "2000", :asset, :debit},
      {:cash, "1000", :asset, :debit}
    ]

    for {key, code, kind, side} <- posting_map do
      account = seed_account(admin, org, code, kind, side)

      case PostingAccount
           |> Ash.Changeset.for_create(:create, %{org_id: org, key: key, account_id: account.id})
           |> Ash.create(scope: admin, authorize?: true) do
        {:ok, _} -> :ok
        {:error, err} -> flunk("PostingAccount seed failed: " <> inspect(err, limit: 15))
      end
    end


    # The item's Finance seam (the E3 design: the inventory-asset side of the
    # receipt's entry resolves per line from the ITEM's default account —
    # "an unlinked item simply never posts").
    inventory_account = seed_account(admin, org, "1300", :asset, :debit)

    item =
      Item
      |> Ash.Changeset.for_create(:create, %{
        org_id: org,
        sku: "PO-1",
        name: "PO Item",
        kind: :stocked,
        uom: :unit,
        default_inventory_account_id: inventory_account.id
      })
      |> Ash.create!(scope: scope, authorize?: true)

    wh =
      Warehouse
      |> Ash.Changeset.for_create(:create, %{org_id: org, code: "MAIN", name: "Main"})
      |> Ash.create!(scope: scope, authorize?: true)

    po =
      PurchaseOrder
      |> Ash.Changeset.for_create(:create, %{
        org_id: org,
        vendor_id: Ecto.UUID.generate(),
        number: "PO-ERP-1",
        order_date: ~D[2026-09-14],
        warehouse_id: wh.id,
        lines: [%{item_id: item.id, qty: 10, unit_cost_cents: 2_500}]
      })
      |> Ash.create!(scope: admin, authorize?: true)

    # The ADR-040 Gate: a direct :approve is REFUSED (a distinct-party
    # approval opens); the DISTINCT approver's decision re-invokes :approve
    # as the requester inside the decision transaction (the d3/d4 discipline,
    # now on the host's own approval resource + registry kind).
    assert {:gated, approval_id} = gate_approve(po, admin)

    requester_id = "a:#{org}"
    approver_id = "a2:#{org}"

    assert {:error, :self_approval} =
             Samen.Approvals.approve(approval_id, requester_id,
               approval_resource: Samenerp.Approvals.Approval,
               repo: Samenerp.Repo
             )

    assert {:ok, _approved, _meta} =
             Samen.Approvals.approve(approval_id, approver_id,
               approval_resource: Samenerp.Approvals.Approval,
               repo: Samenerp.Repo
             )

    po = Ash.get!(PurchaseOrder, po.id, scope: scope, authorize?: true)
    assert po.status == :approved

    # THE CHOKEPOINT: the GoodsReceipt :receive posts the stock event AND the
    # GL entry in ONE transaction. A direct PO mark_received is belt-refused
    # (the state flip requires the transaction-local posting marker — proven
    # by the refusal above being the ONLY path here).
    assert {:error, _} =
             po
             |> Ash.Changeset.for_update(:mark_received, %{}, scope: scope)
             |> Ash.update()

    receipt =
      Samenerp.Erp.GoodsReceipt
      |> Ash.Changeset.for_create(:create, %{
        org_id: org,
        purchase_order_id: po.id,
        warehouse_id: wh.id,
        number: "GR-ERP-1",
        received_date: ~D[2026-09-14]
      })
      |> Ash.create!(scope: scope, authorize?: true)

    # The actual received quantities (the R5 fact — the receipt names the
    # PO line and the received qty; the chokepoint validates the three-way
    # match against the PO's committed lines).
    [po_line] = Ash.read!(Samenerp.Erp.PoLine, scope: scope, authorize?: true)

    receipt =
      receipt
      |> Ash.Changeset.for_update(:receive, %{lines: [%{po_line_id: po_line.id, qty: 10}]}, scope: scope)
      |> Ash.update!()

    po = Ash.get!(PurchaseOrder, po.id, scope: scope, authorize?: true)
    assert po.status == :received

    # The stock fact landed...
    # Stock events name their upstream by the bounded anchor (source_key +
    # source_id — the CROSS-SCOPE posture; the ledger never couples to the PO).
    ledger_count =
      StockLedger
      |> Ash.Query.filter(source_key == "goods_receipt" and source_id == ^receipt.id)
      |> Ash.count!(scope: scope, authorize?: true)

    assert ledger_count == 1

    # ...AND the GL entry, cross-scope, in the SAME transaction (the posted
    # entry exists and is balanced, anchored to the receipt).
    entry = Ash.get!(JournalEntry, receipt.posted_entry_id, scope: scope, authorize?: true)
    assert entry.status == :posted

    lines = Ash.load!(entry, :lines, scope: scope, authorize?: true).lines
    assert Enum.sum(Enum.map(lines, & &1.debit_cents)) == Enum.sum(Enum.map(lines, & &1.credit_cents))
    assert Enum.sum(Enum.map(lines, & &1.debit_cents)) == 25_000
  end

  test "the E5 bridge: fulfill consumes stock and emits the REAL Billing invoice", %{
    org: org,
    scope: scope
  } do
    item =
      Item
      |> Ash.Changeset.for_create(:create, %{org_id: org, sku: "SO-1", name: "SO Item", kind: :stocked, uom: :unit})
      |> Ash.create!(scope: scope, authorize?: true)

    wh =
      Warehouse
      |> Ash.Changeset.for_create(:create, %{org_id: org, code: "MAIN", name: "Main"})
      |> Ash.create!(scope: scope, authorize?: true)

    for {kind, qty} <- [receipt: 20, sale: -0] do
      StockLedger
      |> Ash.Changeset.for_create(:record, %{
        org_id: org,
        item_id: item.id,
        warehouse_id: wh.id,
        kind: kind,
        qty: qty,
        unit_cost_cents: 1_000
      })
      |> Ash.create!(scope: scope, authorize?: true)
    end

    # A REAL host Billing customer (the invoice's SameOrgFk referent — the
    # emitted invoice IS a billable document, so its customer must exist).
    customer =
      Samenerp.Billing.Customer
      |> Ash.Changeset.for_create(:create, %{org_id: org, currency: "USD"})
      |> Ash.create!(scope: scope, authorize?: true)

    so =
      SalesOrder
      |> Ash.Changeset.for_create(:create, %{
        org_id: org,
        customer_id: customer.id,
        number: "SO-ERP-1",
        order_date: ~D[2026-09-14],
        warehouse_id: wh.id,
        lines: [%{item_id: item.id, qty: 5, unit_price_cents: 4_000}]
      })
      |> Ash.create!(scope: scope, authorize?: true)

    so =
      so
      |> Ash.Changeset.for_update(:confirm, %{}, scope: scope)
      |> Ash.update!()
      |> Ash.Changeset.for_update(:fulfill, %{}, scope: scope)
      |> Ash.update!()

    # The invoice is the HOST's REAL Billing document.
    invoice = Ash.get!(Invoice, so.invoice_id, scope: scope, authorize?: true)
    assert invoice.status == :open
    assert invoice.amount_due_cents == 20_000

    # The stock is consumed on the host ledger.
    level =
      Ash.read!(Samenerp.Erp.StockLevel, scope: scope, authorize?: true)
      |> Enum.find(&(&1.item_id == item.id and &1.warehouse_id == wh.id))

    assert level.qty_on_hand == 15
  end

  test "the E6 shop floor: BOM + work order on the host mount", %{org: org, scope: scope, admin: admin} do
    bike =
      Item
      |> Ash.Changeset.for_create(:create, %{org_id: org, sku: "BIKE", name: "Bike", kind: :stocked, uom: :unit})
      |> Ash.create!(scope: scope, authorize?: true)

    wheel =
      Item
      |> Ash.Changeset.for_create(:create, %{org_id: org, sku: "WHEEL", name: "Wheel", kind: :stocked, uom: :unit})
      |> Ash.create!(scope: scope, authorize?: true)

    {:ok, bom} =
      Samenerp.Erp.Bom
      |> Ash.Changeset.for_create(:create, %{
        org_id: org,
        item_id: bike.id,
        name: "BOM-BIKE",
        lines: [%{component_item_id: wheel.id, qty_per: 2, scrap_pct: 0}]
      })
      |> Ash.create(scope: admin, authorize?: true)

    wh =
      Warehouse
      |> Ash.Changeset.for_create(:create, %{org_id: org, code: "SHOP", name: "Shop"})
      |> Ash.create!(scope: scope, authorize?: true)

    {:ok, wo} =
      WorkOrder
      |> Ash.Changeset.for_create(:create, %{
        org_id: org,
        item_id: bom.item_id,
        bom_id: bom.id,
        warehouse_id: wh.id,
        number: "WO-ERP-1",
        qty: 3
      })
      |> Ash.create(scope: admin, authorize?: true)

    wo =
      wo
      |> Ash.Changeset.for_update(:release, %{}, scope: admin)
      |> Ash.update!()

    # The BOM snapshot froze at release (the E6 discipline, on the host).
    assert wo.bom_snapshot != []
    assert wo.status == :released
  end

  test "the surfaces registry resolves every host surface; unknown surfaces are refused" do
    mount =
      Samen.Web.Mount.new(:erp, Samenerp.Erp, Samenerp.Repo, domain: Samenerp.Erp)

    for surface <- Erp.surfaces() do
      resource = Erp.resource(mount, surface)
      assert resource != nil, "surface #{surface} did not resolve on the host mount"
      assert Code.ensure_loaded?(resource)

      # Every bounded column exists on the resolved resource (the registry
      # and the host blueprints agree — no typo'd column can ship).
      for col <- Erp.columns(surface) do
        assert Ash.Resource.Info.attribute(resource, col) != nil,
               "#{surface}.#{col} does not exist on #{inspect(resource)}"
      end
    end

    assert Erp.surface("not-a-surface") == nil
    assert Erp.surface("accounts") == nil
  end

  defp seed_account(scope, org, code, kind, side) do
    Account
    |> Ash.Changeset.for_create(:create, %{
      org_id: org,
      code: code,
      name: "Account #{code}",
      kind: kind,
      normal_side: side
    })
    |> Ash.create!(scope: scope, authorize?: true)
  end

  # The E2 `gate/2` discipline: the gated write MUST refuse, and the refusal
  # MUST name a pending approval — never a bare success (the gate-never-skips
  # control, anti-tautology).
  defp gate_approve(record, scope) do
    result =
      record
      |> Ash.Changeset.for_update(:approve, %{}, scope: scope)
      |> Ash.update()

    case result do
      {:error, %Ash.Error.Forbidden{errors: errors}} ->
        case Enum.find(errors, &match?(%{__struct__: Samen.Approvals.ApprovalRequired}, &1)) do
          nil -> flunk("expected ApprovalRequired, got: #{inspect(errors)}")
          found -> {:gated, found.approval_id}
        end

      {:ok, _} ->
        flunk("the :approve action succeeded WITHOUT the Gate — the approval discipline is broken")

      {:error, other} ->
        flunk("expected ApprovalRequired, got: #{inspect(other)}")
    end
  end
end
