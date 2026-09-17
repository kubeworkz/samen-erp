defmodule Samenerp.Erp do
  @moduledoc """
  The WS-ERP base-system mount (build-plan E8, the host proof): the
  Finance + Inventory scopes mounted AS-IS over ONE host namespace — the
  E1–E7 resource set (CoA, journal, AP/AR documents, posting accounts,
  budgets; items, warehouses, the append-only stock ledger, the derived
  stock level; Procurement, the Sales bridge, Manufacturing) with the
  cross-scope bridges wired to the host's own modules:

    * `finance:` — Procurement's GoodsReceipt posts the stock event AND the
      journal entry in ONE transaction, through `Samenerp.Erp.JournalEntry`
      and `Samenerp.Erp.PostingAccount` (the same compile-time wiring the
      E4 fixture legs prove, now on a real host namespace).
    * `billing:` — the SalesOrder `:fulfill` bridge emits the customer
      invoice into the host's REAL Billing mount (`Samenerp.Billing.Invoice`,
      abbrev `eri`) — a stronger shape than the fixture's mirror leg: the
      emitted invoice IS the host's billable document.

  The `abbrevs:` overrides are the host's `ec*/en*/ep*/eg*/es*/eb*/ew*`
  reservations (registry `hosts.samenerp.*`) — the scope defaults are owned
  by the samen_core fixture legs (the global-registry reality every mount
  documents). The tenant surfaces over this namespace mount in the router
  with ONE `samen_erp_routes(:erp, Samenerp.Erp, ...)` line.
  """
  use Ash.Domain, validate_config_inclusion?: false

  use Samen.Scopes.Finance,
    otp_app: :samenerp,
    repo: Samenerp.Repo,
    namespace: Samenerp.Erp,
    abbrevs: %{
      account: "eca",
      journal_entry: "ecj",
      journal_line: "ecl",
      ap_invoice: "ecp",
      payment_receipt: "ecr",
      posting_account: "ecf",
      budget: "ecb",
      budget_line: "ecd"
    }

  use Samen.Scopes.Inventory,
    otp_app: :samenerp,
    repo: Samenerp.Repo,
    namespace: Samenerp.Erp,
    abbrevs: %{
      item: "eni",
      warehouse: "enw",
      stock_ledger: "enl",
      stock_level: "ens",
      purchase_order: "epo",
      po_line: "epl",
      goods_receipt: "egr",
      receipt_line: "erd",
      sales_order: "eso",
      so_line: "esl",
      bom: "ebm",
      bom_line: "ebl",
      work_order: "ewo",
      production_log: "epg"
    },
    finance: [
      entry: Samenerp.Erp.JournalEntry,
      posting_account: Samenerp.Erp.PostingAccount
    ],
    billing: [
      invoice: Samenerp.Billing.Invoice
    ]

  resources do
    resource(Samenerp.Erp.Account)
    resource(Samenerp.Erp.JournalEntry)
    resource(Samenerp.Erp.JournalLine)
    resource(Samenerp.Erp.ApInvoice)
    resource(Samenerp.Erp.PaymentReceipt)
    resource(Samenerp.Erp.PostingAccount)
    resource(Samenerp.Erp.Budget)
    resource(Samenerp.Erp.BudgetLine)
    resource(Samenerp.Erp.Item)
    resource(Samenerp.Erp.Warehouse)
    resource(Samenerp.Erp.StockLedger)
    resource(Samenerp.Erp.StockLevel)
    resource(Samenerp.Erp.PurchaseOrder)
    resource(Samenerp.Erp.PoLine)
    resource(Samenerp.Erp.GoodsReceipt)
    resource(Samenerp.Erp.ReceiptLine)
    resource(Samenerp.Erp.SalesOrder)
    resource(Samenerp.Erp.SoLine)
    resource(Samenerp.Erp.Bom)
    resource(Samenerp.Erp.BomLine)
    resource(Samenerp.Erp.WorkOrder)
    resource(Samenerp.Erp.ProductionLog)
  end
end
