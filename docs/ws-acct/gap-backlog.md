# ACCT gap backlog — sized, sequenced, and split from the non-goals

- **Status:** proposed, second pass (2026-11-17). Nothing here is started; no source file is
  touched by this document.
- **Scope:** the accounting estate that closed at `docs/gate-ws-acct.md` (Finance + Banking +
  the Billing AR document + the samenerp/Kubeworkz host), audited against what an
  enterprise-style GL/AR/AP function is expected to operate. It does **not** re-open ADR-054's
  decisions; where an item is a deliberate refusal it is recorded in Part A with a re-open
  trigger, not scheduled.
- **Inputs:** `docs/ws-acct/design.md` (§5 honesty list, D5/D12a), `docs/adr/ADR-054-fabless-accounting-books.md`,
  `docs/ws-acct/build-plan.md` (carries), `docs/gate-ws-acct.md`, `docs/guides/stripe-tax.md`, and a
  read of the modules named under each item.
- **Sizing unit:** one *session* is the unit the ws-acct build plan already uses (~half a focused
  day, including its tests and gate work). Ranges include the house obligations: green test, red-path
  twin, committed sabotage, abbrev reservation, fixture **and** host migrations, `./ci.sh` green.

Sizes: **S** ≤ 2 sessions · **M** 3–4 · **L** 5–6 · **XL** > 6.

> **Second-pass correction (2026-11-17).** B2, B4 and B6 were re-read against the code. All three
> changed: the CAD rail has to be a real rail (profile + artifact), tax determination is a scope
> promotion that also needs an AR issuance posting, and the contract-asset item depends on that same
> posting for the customer path. That posting is now **B0**, a prerequisite. Sizes below replace the
> first-pass numbers.

---

## Part A — Deliberate non-goals (do not schedule; review quarterly)

These are refusals, not omissions. Each has a stated trigger at which it becomes a real item;
until then, building it would add a surface nobody operates.

| # | Non-goal | Why it stays out (source) | Re-open trigger | Size if reopened |
|---|---|---|---|---|
| N1 | **Payroll computation** — gross-to-net, withholdings, T4/ROE | The GL consumes an external register; `PayRun`/`Payslip` post, they never compute (`design §5.9`, ADR-049 §7). `Samenerp.Payroll.GustoAdapter` is the intended seam. | Payroll provider API is unavailable/too costly, or headcount makes the register import unmanageable (~25+). | L (8–12) |
| N2 | **Multi-entity consolidation / intercompany elimination** | Kubeworkz is one legal entity; `scopes/consolidation/*` is dormant and is the documented starting point when a second entity exists (ADR-054 D16). | A second legal entity or a parent-company reporting requirement. | XL (10–15; audit the dormant set first, per ADR-055 discipline) |
| N3 | **ASC 606 multi-element contracts** | Schedules are single-obligation (straight-line or cost-incurred); no allocation across performance obligations (`design §5.1`). | First bundled contract (hardware + support + NRE) that must allocate consideration. | L (8–12) |
| N4 | **Tax determination, filing, nexus/registrations, 1099/T4A, e-invoicing** | Design §5.2 puts the whole tax path out of scope: `TaxRate` is uninstantiated, `TaxCalculator` is a preserved test oracle with no invoice/line integration, the seeded books have no tax accounts, and there is no registration model. For SaaS billing, the provider computes tax and Billing mirrors it (`docs/guides/stripe-tax.md`). | Host confirms a GST/QST registration and a filing obligation. Then **B4 is the promotion** (see Part B), with an ADR-054 amendment; filing/nexus/e-invoicing stay in this row. | B4a–B4c below (8–11) |
| N5 | **AR/cash/intercompany FX revaluation, CTA** | Single functional currency is ratified (CAD); only AP FX is live (ADR-054 D15 + amendment). | First foreign-currency customer, bank account, or intercompany balance. | M (5–8) |
| N6 | **Serials, fractional UOM, recall genealogy, MRP/scheduling** | Lots landed; unit-level serials and planning did not (`design §5.4–5.5`). | Serialized hardware shipments, or more than one production line needing capacity planning. | XL (10+) |
| N7 | **Formula/spreadsheet engine, generated board narrative** | Forecast is a bounded driver model; board prose is authored (ADR-054 D11/D12). Permanent product posture. | None. | — |
| N8 | **Impairment, deferred tax, tax provision** | Book depreciation only; no tax basis and no provision (`asset_schedule.ex` is straight-line, one method). | First audit that requires a tax provision, or a material impairment review. | M (4–6) |
| N9 | **4-4-5 / 13-period fiscal calendar** | `FiscalPeriod` is `{year, month}` by design; `period_blueprint.ex` notes a 4-4-5 calendar is host data it does not model. | A parent/retail reporting calendar, or an acquired entity on 4-4-5. | M (3–5) |
| N10 | **Positive pay, wire/SEPA rails** | Only ACH (NACHA) exists; adding rails was never scoped. (The missing **CAD** rail is different — it is B2.) | A US bank requiring positive pay, or EUR/SEPA payees. | S–M (2–4) |

**Recommendation:** keep this table in the ADR register's shadow — when a trigger fires, promote
the row into Part B with its size, rather than building "just in case."

---

## Part B — Worth closing now

Ordered by the recommendation in Part C. "Why now" is the operational cost of leaving it; all
items are additive and none re-opens the ledger's event-sourced posture (no stored balances
except the GL itself).

| # | Item | Why now | Layer | Size |
|---|---|---|---|---|
| B0 | **AR invoice → GL bridge** — post issuance (Dr AR / Cr income or deferred) **and the sale's COGS** (Dr COGS / Cr inventory), enforce the functional-currency precondition, backfill open invoices, and add the AR/COGS reconciliations | Invoices never reach the journal: `FulfillOrder` emits a **USD** Billing invoice with `status: :open` and no entry, while `GoodsPosting` posts the receipt side. Receipts/credit notes only credit `ar_clearing`; the balance sheet is GL-only, so AR, product revenue, COGS and the inventory credit are all missing. B4b and B6b need this seam. | kernel (Finance + Inventory) + host | **L (7–9)** |
| B1 | **Accounting export package** — GL detail, trial balance, journal listing, AP/AR aging as bounded CSVs, plus a per-period "audit pack" (the tax-summary sheet lands with B4a) | The only CSV today is the board pack; the generic ERP surfaces have *no export path at all*. An accountant cannot take the books away, and every later item reuses this path. | web + reads | **S–M (2–3)** |
| B2 | **CAD payment rail** — a CPA-005 EFT renderer beside NACHA, with rail-keyed vendor profiles and artifacts | `ApAchFile` refuses non-USD by design; `VendorPaymentProfile` requires ABA routing and is unique per `{org, vendor}`; `ApAchArtifact` is a NACHA-shaped table that also refuses non-USD. A CAD run is already possible (`ApPaymentRun` enforces one currency) but cannot produce a bank file. | kernel + web | **M–L (4–6)** |
| B3 | **Consume the labour driver** — rewire the Phase 7 labour-rate/efficiency legs and grant cost-incurred recognition to approved timesheet minutes | The driver landed but the build-plan carry says consumers still use ratios and are labelled so. This is the one "built but not wired" integrity gap. | kernel | **S (2)** |
| B4a | **Tax determination (document)** — live `TaxRate` with jurisdiction + effective windows, an org-scoped calculator, local invoice tax fields, and a period tax register | **Scope promotion from N4**; requires the host to confirm GST/QST registration and an ADR-054 §5.2 amendment. The current `TaxRate` has no jurisdiction or dates and no call site; `TaxCalculator`'s SQL is not org-scoped and is a test oracle; Billing's tax fields are provider mirrors that must not be overwritten. | kernel + web + host seed | **L (4–5)** |
| B4b | **Tax posting and sales-tax remittance** — post the tax leg on invoice issuance, reverse it on credit notes, and tie the tax register to the GL | Depends on B0 (the issuance entry exists) and B4a. The host books have no tax payable account and `PostingAccount.key` has no tax meaning, so this also seeds the chart and widens the closed enum. Input tax is B4c. | kernel + host seed | **M (2–3)** |
| B4c | **Input tax on AP bills + net remittance** — bill-level tax capture, `input_tax_receivable`, and the net GST/QST return read | Without ITCs the register is one-sided; defer only if AP bills genuinely carry no recoverable tax. Adds bill fields and splits the AP posting. | kernel + web | **M (2–3)** |
| B5 | **Audit evidence attachments** — link source documents (AP invoice PDF, contracts, approvals) to bills, journal entries, credits and payment runs, via the existing Files chokepoint | Nothing in Finance references a file id; capture parses a document but does not retain it. The hash chain proves actions, not the paper behind them. | kernel + web | **M (3–4)** |
| B6a | **Grant contract asset** — allow `deferred_key: :contract_asset`, recognize against it, and convert to a grant receivable on claim approval | The grant path already posts Dr `grant_deferred` / Cr income through `RecognitionPosting`, which debits the schedule's `deferred_key`; the missing pieces are the enum value, the posting key, and a claim-approval posting (claims are state-only today). | kernel + web | **M (3–4)** |
| B6b | **Customer unbilled revenue** — let a schedule accrue to contract asset and have invoice issuance clear it instead of crediting income/deferred | Depends on B0 and B4a. On top of B0 this is small: the issuance cascade chooses the credit side from the schedule's `deferred_key`. Explicitly **not** a second AR ledger and not an aging bucket. | kernel | **S (1–2)** |
| B7 | **Budget phasing, versions, approval** — monthly phasing/spread, version rows with approved/locked status, monthly budget-vs-actual | Budgets today are annual per-account totals with no approval machinery; variance analysis is coarse and budgets are editable config, not a controlled plan. | kernel + web | **S–M (2–3)** |
| B8 | **Commitment control (encumbrance)** — committed = approved open POs; available = budget − actual − committed; funds check at PO approval and non-PO bill approval | POs have an approval Gate, but it approves the document, not the budget. Overruns are detected after the fact; enterprises expect them refused. | kernel + web | **M (3–4)** |
| B9 | **Customer credit management** — credit profile (limit, terms, hold), order/invoice credit check, aging-driven hold, approved override | `credit_limit` appears nowhere. Dunning and statements exist, but nothing prevents shipping to a customer already over terms. | kernel + web | **S–M (2–3)** |
| B10 | **Tax depreciation (CCA) book** — tax class/rate by year, CCA schedule read, half-year rule, disposal recapture | Asset schedules are straight-line book only. A Canadian tax return needs CCA; today it is an offline spreadsheet. No deferred tax (N8). | kernel | **S–M (2–3)** |
| B11 | **Controlled period reopen** — admin + reason + approval, audit event, and the existing guard honouring the reopened state | Close is one-way by design and that is defensible — but practice usually needs a documented exception path, and today the only correction route is "post in the open period." | kernel + web | **S (2)** |
| B12 | **Inventory cycle counts** — count document, snapshot, variance, adjustment posting, approval | Stock is reconciled to its ledger, never to the floor; no `StockCount`/`CycleCount` exists. Needed once physical inventory is material. | kernel + web | **M (3–4)** |
| B13 | **Treasury transfers** — bank-to-bank transfer document posting Dr/Cr cash and matching both statement legs | No transfer document exists; inter-account moves are manual JEs today. Low frequency, easy to get wrong. | kernel + web | **S (2)** |
| B14 | **Lease depth** — escalations, variable payments, renewal/termination options, modifications | `LeaseSchedule` is explicitly fixed-payment, month-end, single-currency. Only worth doing when a real lease contract needs it. | kernel | **M (3–4)** |

**Not in Part B on purpose:** report writer / configurable statements (B1's export path first),
AP interest/late fees, and multi-currency AR (N5). Those should be demand-driven.

---

## Part B detail — the re-checked items

### B0 — The missing AR/COGS issuance posting (new)

**What the code says.**
- `FulfillOrder` writes the `StockLedger :sale` events with `unit_cost_cents` (the moving-average
  snapshot) and emits a Billing `Invoice` with `status: :open`, `amount_due_cents`, and
  **`currency: "USD"`**, then flips the SO. It posts **no journal entry**. The receipt side,
  `GoodsPosting`, does post Dr inventory / Cr AP clearing, so inventory has receipt debits with no
  sale-side credit.
- `ReceiptPosting` posts Dr `cash` / Cr `ar_clearing`; `CreditNotePosting` posts
  Dr `credit_note_clearing` / Cr `ar_clearing`. Nothing ever debits `ar_clearing` for an invoice.
- `ArAging` is a subledger read; `BalanceSheet` is GL-only. AR and product revenue are absent from
  the statements, and COGS is absent while inventory stays overstated.
- `Item.default_inventory_account_id` is the receipt-side inventory seam (an unlinked item refuses
  the receipt). The same account is the natural COGS credit.
- `OrgFxSettings.base_currency` defaults to `"USD"` when no row exists, but the Kubeworkz books
  seed **CAD**; `ApFx.base_currency/2` resolves it. The bridge's hard-coded `"USD"` is therefore a
  call-site bug on a CAD host.

**Scope.**
- A new issuance cascade on the invoice's `:open` transition (the status is plain CRUD today, so
  this needs an explicit issue action or a guard, not a callback on any status write).
- One transaction, two anchored entries: the **revenue/AR entry** (`billing_invoice`) —
  Dr `ar_clearing` / Cr `income` for point-in-time sales, Cr `deferred_revenue` when a
  `RevenueSchedule` is anchored — and the **COGS entry** (`sales_order`) — Dr `:cogs` / Cr each
  line's item `default_inventory_account_id` for `qty × moving-average cost`, reusing the cost
  snapshot the stock events already took. (`:cogs` is already in the closed posting enum and
  mapped to `5000` in the Kubeworkz books; no new COGS key is needed.)
- **Functional-currency precondition:** resolve the org's `OrgFxSettings.base_currency`; fix
  `emit_invoice/4` to stamp it instead of `"USD"`; refuse any invoice whose currency differs with
  `{:unsupported_invoice_currency, invoice_currency, functional_currency}`. No conversion and no
  rate lookup — AR FX stays N5.
- Exactly-once per document; credit notes reverse the same accounts they offset; closed periods
  refuse through the ordinary `:post` path.
- Backfill for existing open invoices (idempotent, reports what it skips), extend
  `ReconcileFulfillment` to read both GL sides (the `ReconcileProcurement` shape), and add **R12**
  on the close board: local invoice aging less local on-account cash ties to `ar_clearing`;
  provider-mirror invoices are excluded and counted, and provider-linked receipts/credit notes/
  allocations are refused (legacy ones make R12 fail, not tie).
- ADR-054 amendment: the AR document becomes a GL event; `ar_clearing` becomes a true control
  account rather than a cash clearing.

**Acceptance.**
- A CAD org's fulfilled order emits a CAD invoice and posts both entries: the P&L shows revenue
  and COGS, the balance sheet shows the receivable and the inventory reduction.
- A USD invoice in a CAD org refuses with `{:unsupported_invoice_currency, "USD", "CAD"}` and
  posts nothing — no conversion, no partial entry.
- COGS equals `Σ qty × moving-average cost` from the stock events; each credit names the line
  item's `default_inventory_account_id`; an item without that link refuses the whole fulfillment
  (mirroring `GoodsPosting`).
- Both entries exist or neither does; issuing twice posts once; a credit note reverses the
  revenue side; a closed period refuses.
- `ReconcileFulfillment` reports a missing, foreign or misvalued GL side.
- R12: local invoice aging **less local on-account cash** ties to the `ar_clearing` debit balance
  at period end; a provider-mirror invoice is excluded and counted; a provider-linked receipt,
  credit note or allocation is contamination even if the cents happen to net.
- A receipt or credit note against a provider-mirror invoice refuses with a named reason and
  writes no `billing_payment`/`credit_note` entry; an on-account receipt is allowed, posts once,
  and applying it later creates no second entry.
- A schedule-backed invoice must have the schedule's total equal the invoice's pre-tax amount;
  a mismatch refuses rather than crediting a guessed deferred balance.
- Backfill leaves already-posted invoices untouched and names every skipped invoice with a reason.
- Cross-org invoice ids are invisible; no second AR ledger is created.

**Out:** AR FX conversion and any foreign-currency invoice (N5); tax (B4b); contract assets
(B6b); changes to the Billing provider mirror.

**Why this grew (5–7 → 7–9):** the COGS leg and the currency guard belong to the same
transaction, not to a follow-up item.

### B0 — Implementation plan (not started)

**One deliverable:** the invoice/COGS posting seam, landed in eight steps. **No Billing table
change:** the local/provider discriminator is the existing `provider_invoice_ref` (nil = local,
set = provider mirror), and exactly-once is a partial unique index on the journal anchor.
`amount_due_cents` is the gross document total at issue; `amount_paid_cents` must be 0 at issue
(a prepayment is a receipt, not an invoice field).

#### Decisions locked by the code

1. `Samen.Billing.AshInvoiceMirror` writes through Ash `:create`/`:update`, so the guard must
   allow provider rows (ref present) and refuse a local row (ref nil) that tries to reach an
   issued status except through `:issue`.
2. One posting service, `ArInvoicePosting`, is called by Billing's `:issue` action and by
   `FulfillOrder`; it is never duplicated per caller.
3. COGS is a second anchored entry (`source_key: "sales_order"`) in the same transaction as the
   revenue/AR entry (`source_key: "billing_invoice"`). `:cogs` already exists in the closed
   `PostingAccount` enum and maps to `5000`; the credit is each item's
   `default_inventory_account_id`.
4. R12 compares **local** AR aging (`provider_invoice_ref IS NULL`) **less local on-account
   cash** to `ar_clearing`; provider mirror invoices are excluded and counted, and provider-linked
   receipts/credit notes/allocations are contamination, never silently folded into the tie.
5. A void does not auto-reverse an issued invoice; a credit note is the reversal path (B0 posts
   at issue only).
6. Any invoice module passed as Inventory's `billing: [invoice: ...]` must expose `:issue` —
   `Samenerp.Billing.Invoice` does once step 2 lands, and the fixture `InvoiceMirror` gains it;
   a host that wires Inventory's billing without a B0-capable invoice fails at fulfillment, not
   silently (the mount contract is documented in `Samen.Scopes.Inventory`).
7. Marker nesting is why both paths are safe: `:fulfill` arms first, nested `:issue` reads the
   armed prior value and restores it, and the outer `:fulfill` restores the original. A manual
   `:issue` arms from `"off"` and restores to `"off"`. No blind `"off"` restore anywhere.
   This holds only because `FulfillOrder.emit_invoice` runs inside its `before_action` (after
   `:fulfill`'s arm) and `ArInvoicePosting` likewise creates its entry inside `before_action`;
   building either changeset at `change/3` time would capture the wrong prior value.
8. The local AR control is **refused, not re-keyed**: a provider invoice was never posted, so a
   dedicated provider account would only move an orphan credit. `ArReceiptGuard`,
   `ArReceiptApplication` and `ReceiptAllocation` refuse a provider-ref invoice, and
   `CreditNotePosting` refuses one. On-account cash stays local and is explained by R12. No new
   `PostingAccount` key and no migration.

#### Files to change

**Billing (kernel)**

| File | Change |
|---|---|
| `samen_core/lib/samen/scopes/billing.ex` | `__using__` accepts `finance:`; expand aliases; pass the map to `define_invoice/8`. |
| `samen_core/lib/samen/scopes/billing/blueprint.ex` | `define_invoice/8`; when `finance` is present add `update :issue` (`accept([])`, `require_atomic?(false)`, `Samen.Scopes.Finance.PostingMarker` **then** `ArInvoicePosting`, force `:open`, admin policy) and the create/update guard. Marker-before-posting is load-bearing: `ArInvoicePosting` builds the `:create_reversal` entry inside the armed transaction. |
| `samen_core/lib/samen/scopes/billing/issue_guard.ex` (new) | Resource change: a **local** row (`provider_invoice_ref` nil) may not be created non-draft, and may not transition `:draft → {:open, :paid, :uncollectible}`, except through `:issue`; provider rows and `:open → :paid/:void` pass. |

**Finance (kernel)**

| File | Change |
|---|---|
| `samen_core/lib/samen/scopes/finance/ar_invoice_posting.ex` (new) | `post/2` + Ash change. Resolve org/provider/currency; find the single `billing_invoice`-anchored schedule; resolve `:ar_clearing` + `:income`/`schedule.deferred_key`; **build and create** the POSTED `:create_reversal` entry inside `before_action` (never in `change/3`, where `PostGuard` would read the marker before the outer arm and restore it to `"off"` mid-action); stamp nothing on the invoice (the anchor is the link); refuse an existing anchor, a provider ref, a non-functional currency, a non-positive amount, a paid-at-issue invoice, a schedule-total mismatch, and unmapped accounts. |
| `samen_core/lib/samen/scopes/finance/reconcile_ar.ex` (new) | R12: `local_aging_cents` (provider nil) **less** `unapplied_cents` vs the `ar_clearing` GL debit balance at `as_of`; returns `%{aging_cents, unapplied_cents, expected_gl_cents, gl_cents, difference_cents, balanced?, excluded_provider_invoices, provider_linked_receipts, provider_linked_credit_notes, provider_linked_allocations, contaminated?}`; `balanced?` is false when contamination exists even if the cents net; an unmapped `ar_clearing` refuses fail-honest. Reads the same resources as `ArAging` plus `posting_account`, `entry` and `line`; it queries the invoice resource for provider refs so fully paid mirrors still count, counts posted provider-linked receipts, open/applied provider-linked credit notes and provider-linked allocations, and treats a resource without `provider_invoice_ref` as having zero provider docs. |
| `samen_core/lib/samen/scopes/finance/ar_invoice_backfill.ex` (new) | Opt-in, idempotent: local `:open`/`:paid` invoices with no anchor; dry-run default; reports posted/skipped with reasons. |
| `samen_core/lib/samen/scopes/finance/close_board.ex` | Surface the R12 result as a read-only close-board check (no schema). |

**AR containment (existing surfaces)**

| File | Change |
|---|---|
| `samen_core/lib/samen/scopes/finance/ar_receipt_guard.ex` | On an invoice-bound create, read the invoice's `provider_invoice_ref`; a non-empty ref refuses with `:provider_invoice_not_local` before the status/currency checks. |
| `samen_core/lib/samen/scopes/finance/ar_receipt_application.ex` | `plan_allocations/4` and `apply_credit/1` refuse a statement row whose `provider_invoice_ref` is set, naming the invoice; no receipt, allocation or entry is written. |
| `samen_core/lib/samen/scopes/finance/ar_aging.ex` | Expose `provider_invoice_ref` on normalized invoices, aging rows and statement rows, so R12 filters local rows and the receipt application can distinguish a mirror target. |
| `samen_core/lib/samen/scopes/finance/credit_note_posting.ex` | Add `invoice:` to its opts; before resolving posting accounts, read the note's invoice and refuse a non-empty `provider_invoice_ref` (`:provider_invoice_not_local`), a missing invoice or a cross-org invoice; no entry. |
| `samen_core/lib/samen/scopes/finance/credit_note_blueprint.ex` | Pass `invoice: unquote(invoice_mod)` to `CreditNotePosting`. |
| `samen_core/lib/samen/scopes/finance/receipt_allocation_blueprint.ex` | `define_receipt_allocation/6` gains the invoice module, so direct allocation creates cannot bypass the provider-ref refusal. |
| `samen_core/lib/samen/scopes/finance/receipt_allocation_guard.ex` (new) | Read the invoice by org/id; refuse a provider ref, a missing invoice or an unwired invoice resource before the allocation row. |
| `samen_core/lib/samen/scopes/finance.ex` | Pass `billing[:invoice]` to `define_receipt_allocation/6`. |

**Inventory (kernel)**

| File | Change |
|---|---|
| `samen_core/lib/samen/scopes/inventory.ex` | Extract `entry`, `posting_account`, and optional `org_fx_settings` from `finance:`; pass them plus `item` into `define_sales_order`. |
| `samen_core/lib/samen/scopes/inventory/blueprint.ex` | `define_sales_order/14` — append `entry_mod`, `posting_account_mod`, `item_mod`, `org_fx_settings_mod`; pass them in the `FulfillOrder` change opts. |
| `samen_core/lib/samen/scopes/inventory/fulfill_order.ex` | Emit a **draft** invoice with the functional currency, call `:issue`, then stock events, then the COGS entry (Dr `:cogs` / Cr each item's inventory account, `qty × moving-average cost`). Refuse an item with no inventory account. The `:fulfill` action's existing `PostingMarker` stays; `:issue`'s own marker nests and restores to the outer arm. |
| `samen_core/lib/samen/scopes/inventory/reconcile_fulfillment.ex` | Read both GL anchors (`billing_invoice` revenue, `sales_order` COGS) and report missing/foreign/misvalued sides alongside the existing stock↔invoice read. |

**Hosts and fixtures**

| File | Change |
|---|---|
| `samenerp/lib/samenerp/billing.ex` | Pass `finance: [entry: Samenerp.Erp.JournalEntry, posting_account: Samenerp.Erp.PostingAccount, revenue_schedule: Samenerp.Erp.RevenueSchedule, org_fx_settings: Samenerp.Erp.OrgFxSettings]`. |
| `samenerp/lib/samenerp/erp.ex` | Add `org_fx_settings: Samenerp.Erp.OrgFxSettings` to the Inventory `finance:` map. |
| `samenerp/lib/mix/tasks/samenerp.backfill_ar.ex` (new) | Thin host task: `--dry-run` (default) / `--apply`, calling the core backfill with Samenerp's modules. |
| `samen_core/test/support/finance_fixture.ex` | Add `update :issue` to `InvoiceMirror` with the same chain: `PostingMarker` **then** `ArInvoicePosting` (`revenue_schedule: nil, org_fx_settings: nil` — the USD default); exclude `:status` from its create accept. CAD and schedule-backed cases are samenerp tests, so no new fixture resource or abbrev is needed. |
| `samenerp/lib/samenerp/kubeworkz/ar_demo.ex` | No change: its synthetic `provider_invoice_ref` keeps it a provider-mirror row, outside B0 and R12 (asserted in the test). |

#### Migrations (exactly two, both anchor indexes)

1. **Fixture** — `samen_core/priv/test_repo/migrations/20261117120000_add_billing_anchor_uniques.exs`,
   module `SamenCore.TestRepo.Migrations.AddBillingAnchorUniques`, `use Samen.Migration`:

   ```elixir
   create unique_index(:sje_journal_entry,
     [:sje_org_id, :sje_source_key, :sje_source_id],
     name: :sje_billing_anchor_unique,
     where: "sje_source_key IN ('billing_invoice','sales_order') AND sje_source_id IS NOT NULL")
   ```
   `down/0` drops the index by name (mirror the payroll-register migration's shape).

2. **samenerp** — `samenerp/priv/repo/migrations/20261117120000_add_billing_anchor_uniques.exs`,
   module `Samenerp.Repo.Migrations.AddBillingAnchorUniques`, `use Ecto.Migration`: the same
   index on `ecj_journal_entry` (`ecj_org_id`, `ecj_source_key`, `ecj_source_id`), name
   `:ecj_billing_anchor_unique`.

No invoice-table migration in either app. If B4a later adds local tax fields, that is its own
Billing migration set; B0 deliberately does not enter those tables.

#### Tests

| Test file | Cases |
|---|---|
| `samen_core/test/finance_ar_invoice_posting_test.exs` (new) | `"a local invoice posts Dr AR / Cr income exactly once"`; `"a non-functional-currency invoice refuses before any entry"` (EUR against the USD default); `"manual :issue restores the posting marker after the entry lands"` (`PostingMarker.current(@repo) == "off"`); a paid-at-issue invoice refuses; duplicate retry refuses; unmapped `ar_clearing`/`income` refuses; closed period refuses; a schedule module of `nil` takes the income path (the schedule branch is samenerp-only). |
| `samen_core/test/inventory_sales_order_test.exs` (extend) | `"fulfill posts revenue and COGS in the same transaction"`; `"a nested :issue keeps the marker armed and restores it after :fulfill"`; `"an item without an inventory account refuses the whole fulfillment"`; update f8's walkthrough to assert both entries and the SO/invoice anchors. |
| `samen_core/test/finance_e2_scope_test.exs` (extend) | `"an on-account receipt is allowed and R12 reports it as unapplied cash"`; `"applying on-account cash to an issued local invoice posts no second entry and R12 still ties"`. |
| `samen_core/test/finance_reconcile_ar_test.exs` (new) | `"local aging less unapplied cash ties to the ar_clearing debit balance"`; an on-account receipt against an issued local invoice is netted; a missing/misvalued local entry makes `balanced?` false. Provider-ref fixtures live in samenerp, because `InvoiceMirror` has no provider column. |
| `samen_core/test/finance_ar_invoice_backfill_test.exs` (new) | `"backfill posts only local open invoices and reports the rest"`; dry-run writes nothing; a second apply is a no-op. |
| `samenerp/test/kubeworkz_ar_posting_test.exs` (new) | `"a CAD order posts revenue and COGS through the real Billing invoice"` (invoice CAD, both anchors, books `1100`/`4000`/`5000`); `"manual :issue and sales :fulfill both restore the posting marker"`; `"a USD invoice in a CAD org refuses at issue"`; `"a provider-mirror invoice cannot be issued locally"`; `"a provider-mirror invoice refuses local receipts"`; `"a direct allocation to a provider-mirror invoice is refused"`; `"a credit note against a provider-mirror invoice refuses before posting"`; `"a CAD on-account receipt is netted by R12 and applying it to an issued invoice posts no second entry"`; `"a legacy provider-linked receipt is counted and makes balanced? false"` (seeded below the guard to model pre-B0 data); `"a schedule-backed invoice credits its deferred key and refuses a total mismatch"`; `"R12 ties local invoices only and counts the provider invoice as excluded"`. |
| Existing Billing suites (`samen_core/test/billing_*`, `samen_web/test/samen/web/*billing*`) | Provider mirror still creates/updates `:open` rows through Ash; no guard or `:issue` regression. |

#### Sabotages (next free numbers; 418 is the current last)

| Patch | Flips | MUST_FAIL |
|---|---|---|
| `419-acct-b0-invoice-issue-posting-dropped.patch` | `:issue` forces `:open` but skips `ArInvoicePosting` (or makes `post/2` a no-op) | `a local invoice posts Dr AR / Cr income exactly once` |
| `420-acct-b0-invoice-currency-guard-dropped.patch` | `ArInvoicePosting` stops comparing `invoice.currency` to `ApFx.base_currency/2` | `a non-functional-currency invoice refuses before any entry` |
| `421-acct-b0-fulfill-cogs-entry-dropped.patch` | `FulfillOrder` skips the COGS entry and lands only the stock/invoice legs | `fulfill posts revenue and COGS in the same transaction` |
| `422-acct-b0-ar-tie-diff-swallowed.patch` | `ReconcileAr` returns `balanced?: true` and a zero difference unconditionally | `local aging less unapplied cash ties to the ar_clearing debit balance` |
| `423-acct-b0-inventory-account-fallback.patch` | A missing `default_inventory_account_id` falls back to `:cogs` instead of refusing | `an item without an inventory account refuses the whole fulfillment` |
| `424-acct-b0-samenerp-billing-finance-unwired.patch` | `Samenerp.Billing` drops the `finance:` map, so `:issue` is not installed (APP: samenerp) | `a CAD order posts revenue and COGS through the real Billing invoice` |
| `425-acct-b0-provider-invoice-receipt-guard-dropped.patch` | `ArReceiptGuard`/`ArReceiptApplication`/`ReceiptAllocationGuard` drop the provider-ref check (APP: samenerp) | `a provider-mirror invoice refuses local receipts` |
| `426-acct-b0-provider-invoice-credit-note-guard-dropped.patch` | `CreditNotePosting` drops the provider-ref check (APP: samenerp) | `a credit note against a provider-mirror invoice refuses before posting` |
| `427-acct-b0-reconcile-ar-unapplied-ignored.patch` | `ReconcileAr` compares aging directly and omits `unapplied_cents` | `local aging less unapplied cash ties to the ar_clearing debit balance` |

Each patch uses the harness header shape (`# APP:`, `# TEST_FILES:`, `# MUST_FAIL:`) and must
revert byte-exact. `TEST_FILES` are app-relative (e.g. `test/finance_ar_invoice_posting_test.exs`).

#### Land order

1. **Schema belt first.** Add the two migrations (no fixture resource). Check:
   `cd samen_core && mix compile --warnings-as-errors`, then `MIX_ENV=test mix ecto.migrate` and
   `MIX_ENV=test mix ecto.rollback` on the fixture DB to prove `down/0`; the same migrate/rollback
   in `samenerp`.
2. **Billing issue path.** `finance:` plumbing, `IssueGuard`, `update :issue` with
   `PostingMarker` **before** `ArInvoicePosting`, Samenerp wiring. Check:
   `cd samen_core && mix test test/billing_invoice_test.exs test/billing_provider_test.exs
   test/billing_webhook_dispatch_test.exs` and `cd samenerp && MIX_ENV=test bash ci.sh`; the
   provider-mirror tests must stay green and the manual-issue marker test lands with step 3.
3. **Posting service.** `ArInvoicePosting` + `InvoiceMirror` `:issue` (same marker-first chain);
   keep the entry build/create inside `before_action`; run
   `cd samen_core && mix test test/finance_ar_invoice_posting_test.exs`, including
   `"manual :issue restores the posting marker after the entry lands"`.
4. **Sales bridge.** `FulfillOrder` currency + draft→issue + COGS; `emit_invoice` stays inside
   the existing `before_action` (after the outer arm); run
   `cd samen_core && mix test test/inventory_sales_order_test.exs`, including the nested
   `:issue` marker restore after `:fulfill`.
5. **AR containment.** `ArReceiptGuard`/`ArReceiptApplication`/`ReceiptAllocation` provider
   refusal, `CreditNotePosting` provider refusal, `ArAging` provider-ref exposure; run
   `cd samen_core && mix test test/finance_e2_scope_test.exs` (existing on-account path must stay
   green; R12 assertions land with step 6).
6. **Reconciliation.** `ReconcileAr` net-of-unapplied + contamination counts, plus
   `ReconcileFulfillment` GL legs; run
   `cd samen_core && mix test test/finance_e2_scope_test.exs test/finance_reconcile_ar_test.exs
   test/inventory_sales_order_test.exs`.
7. **Backfill + host.** `ArInvoiceBackfill`, `samenerp.backfill_ar`, `kubeworkz_ar_posting_test.exs`
   (including the manual-issue, sales-fulfill, provider-refusal and on-account cases); run
   `cd samenerp && MIX_ENV=test bash ci.sh`, then a dry-run against the dev DB.
8. **Gate.** Add patches 419–427; run
   `SAMEN_SABOTAGE=1 ./scripts/sabotage.sh --app samen_core --range 419-423`,
   `SAMEN_SABOTAGE=1 ./scripts/sabotage.sh --app samen_core --range 427-427` and
   `SAMEN_SABOTAGE=1 ./scripts/sabotage.sh --app samenerp --range 424-426`, then `./ci-fast.sh`
   and finally `./ci.sh` to `ROOT CI: ALL PASSED`.

#### Definition of done

- A CAD sales order creates a CAD invoice, one `billing_invoice` revenue/AR entry and one
  `sales_order` COGS entry; inventory and revenue both move on the statements.
- A non-CAD invoice refuses with a named reason and leaves no entry; a provider-mirror invoice
  is never issued locally; a retry is refused by the pre-read and the unique index.
- COGS equals the stock-event cost and each credit names the line item's inventory account; an
  unlinked item refuses the whole fulfillment.
- R12: local invoice aging less local on-account cash ties to `ar_clearing`; provider invoices
  are excluded and counted; provider-linked receipts/credits/allocations make `balanced?` false
  even when the cents net.
- A receipt or credit note against a provider-mirror invoice refuses and writes no entry;
  on-account cash is allowed, posts once, and applying it posts no second entry.
- `ReconcileFulfillment` reports a missing, foreign or misvalued GL side.
- Both paths are marker-safe: manual `:issue` arms from `"off"` and restores it; `:fulfill`'s
  nested `:issue` restores to the outer `"on"`, then `:fulfill` restores `"off"`. No blind
  `"off"` restore; `PostingMarker` sits before `ArInvoicePosting` in both the real invoice and
  `InvoiceMirror`.
- No new `PostingAccount` key and no Billing table change; both migrations roll back cleanly; both suites and `./ci.sh` green.

### B2 — Implementation plan (not started)

**One deliverable:** a CAD EFT rail beside NACHA, landed in eight steps. The USD path is not
refactored: `ApAchFile` keeps its behavior and its bytes, and a new pure `ApEftFile` renders
CPA-005. The rail is a stored dimension on both the profile and the artifact, never a `format:`
flag on either renderer.

> **Target pinned (2026-11-18): TD Business Central — EFT Import File, 1464.** TD's public page
> confirms Business Central imports **80- or 1464-byte** file layouts. This is the CPA-005 plan, not
> TD's 80-byte WBB path (whose Import Payments page accepts only 80-byte files). TD supports the
> 1464 layout but does not publish a public 1464 delimiter/encoding sheet; its 80-byte guide
> requires CRLF, and public TD-specific setup guidance (Treasury Software) assigns destination
> data centre `00420`, return institution `0004` + the 5-digit transit, an 11-digit TD return
> account, and a 0001–9999 incrementing file creation number (0000 refused; TD rejects a number
> reused within its last 18 submissions).
> Test and production are separate `{org, bank, environment}` profiles with independent FCN
> sequences: test allocation never advances production, and production starts at `0001`.
> Payments Canada Standard 005 specifies **EBCDIC** for 1464 records, while TD's public 80-byte
> guide is a CRLF text upload and does not state a character set. The ASCII/CRLF values below are
> therefore the **TD profile defaults pending TD's 1464 test file**, not a universal CPA-005
> default. Before step 2, obtain that test file (or TD's 1464 implementation guide); if TD requires
> EBCDIC or CR-only, add the encoder/separator before cutting the golden. Do not ship the
> provisional pair unverified.

#### Decisions locked by the code

1. **Two renderers, no flag.** `ApAchFile` stays the USD NACHA renderer with its 94-character
   records, ABA checksum and 17-character account limit. `ApEftFile` is a separate pure module
   for CPA-005: 1464-character records, 240-character segments, CAD only. Neither module gains a
   `format:` option.
2. **The rail is `:ach_usd` or `:eft_cad`**, stored as `"ach_usd"` / `"eft_cad"`. The profile
   key becomes `{org, vendor, rail}`; the artifact gains `ach_rail`. One vendor may hold both a
   USD ACH profile and a CAD EFT profile, but no lookup or render may fall back from one rail to
   the other.
3. **CAD identifiers are vaulted too.** A CAD profile stores its 3-digit institution number and
   5-digit transit number as `vt_*` tokens under the same row DEK as the account number. The
   plaintext-only fingerprints are `institution_last4` (the three significant digits) and
   `transit_last4`; the UI never reveals the full branch identifiers.
4. **Rail is immutable on an existing profile.** A different rail is a different profile row,
   not an update: otherwise a verified ACH profile could become a CAD profile while keeping the
   old verification evidence. `change_bank_details/1` changes details only, never the rail.
5. **The artifact stays one append-only table.** `ach_ap_payment_ach_file` gains `ach_rail` and
   rail-specific receiver fingerprints instead of a sibling table. Rows remain immutable and
   undeletable; `list/3` and `reveal/2` return both rails without a second read path.
6. **The run currency is the rail selector.** The web does not offer a free rail switch on a fixed
   currency run: `USD` renders ACH, `CAD` renders CPA-005, and any other currency is refused before
   a profile is read or a file is rendered. The profile form does choose a rail, because one vendor
   can have both profiles.
7. **`ApPaymentRun` is untouched.** It already snapshots one currency per run and exposes
   `vendor_ids/1` and `payments_for_vendor/2`; B2 adds no run action and no mixed-currency path.
8. **USD bytes are frozen by a fixture.** Before changing any Finance module, capture the current
   `ApAchFile` output for the existing two-payment sample as
   `samen_core/test/fixtures/ap_ach_usd_golden.ach`; the B2 suite must render byte-identical bytes.
   This is stronger than field assertions and catches an accidental shared-helper refactor.
9. **Down migrations do not silently destroy a rail.** `down/0` restores the pre-B2 schema on an
   empty/pre-CAD database, but raises if CAD profile or artifact rows exist; dropping the rail
   columns under live CAD data would be data loss, not a rollback.
10. **TD framing is profile data, not a universal default.** `ApEftFile` requires `:encoding`
    (`:ascii` for TD) and `:record_separator` (`"\r\n"` for TD); it has no fallback. TD's
    80-byte guide requires CRLF, and its 1464 setup is a text upload, but TD has not published a
    1464 delimiter/encoding sheet. ASCII/CRLF are therefore the TD profile values to certify
    against TD's 1464 test file, not a claim about CPA-005. If that test requires EBCDIC or
    CR-only, add the adapter/separator before the golden; do not silently substitute.
11. **TD originator details are durable, bank-controlled and environment-split.** Add one
    `ApEftOriginatorProfile` per `{org, bank, environment}`, where environment is `:test` or
    `:production`, holding the 10-digit TD client number, destination data centre `00420`, return
    institution `0004` + transit, the vaulted 11-digit TD return account, encoding/separator, and
    the next file creation number. The two rows have independent sequences: allocating a test
    file updates only the test row, and the production row starts at `0001`.
    `allocate_file_creation_number/3` requires the caller's environment to match the profile
    (`:environment_mismatch` otherwise), locks only that row, returns `0001..9999`, wraps `9999` to
    `0001`, refuses `0000`, and persists the next value. `eop_environment` is immutable and deletes
    are refused, so a removed profile cannot silently reset production to `0001`. Allocation is
    monotonic, so TD's rule against reusing a number within its last 18 submissions holds; there is
    no reset action. There is no default environment: the web reads
    `:samen_core, :eft_environment` and refuses `:environment_not_configured`. The CAD form does not
    accept a free FCN or plaintext return account.

#### Files to change

**Finance (kernel)**

| File | Change |
|---|---|
| `samen_core/lib/samen/scopes/finance/ap_eft_originator_profile.ex` (new) | TD originator config and FCN allocator. `environment/0` reads `Application.fetch_env(:samen_core, :eft_environment)` and accepts only `:test`/`:production`, refusing `:environment_not_configured` or `:invalid_environment`; `get/3` is org-scoped and bank/environment-pinned (`:td_business_central`); `configure/1` is admin-only, requires the environment, validates the 10-digit client number, `00420`, `0004` + 5-digit transit return institution, and 11-digit return account, vaults the return account under the row DEK, and stores `:ascii`/`:crlf`; `render_details/3` reveals the return account only to the server-side renderer after the environment matches; `allocate_file_creation_number/3` requires the environment to match the profile, locks only that row `FOR UPDATE`, returns the stored 1–9999 value, and advances it (9999→0001), refusing a missing or cross-environment profile; it is the only FCN writer, so TD's 18-file reuse window cannot be violated by a reset. Cross-org and cross-environment reads return nil. |
| `samen_core/lib/samen/scopes/finance/ap_eft_originator_profile_record.ex` (new) | Schema/changeset for `eop_ap_eft_originator_profile`: required `eop_org_id`, `eop_bank`, `eop_environment`, `eop_client_number`, `eop_destination_data_centre`, `eop_return_institution`, `pii_eop_return_account`, `eop_next_file_creation_number`, `eop_encoding`, `eop_record_separator`; unique `{org, bank, environment}`; environment is immutable (a changeset change is refused), and token/TD-field validations apply per environment. |
| `samen_core/lib/samen/scopes/finance/ap_eft_file.ex` (new) | Pure CPA-005 renderer: `render/2`, `@record_width 1464`, `@segment_width 240`, `@segments_per_record 6`, `@max_account_length 12`. Requires the run currency `"CAD"`, `:originator_id` (TD 10-digit client number), `:destination_data_centre` (TD `00420`), `:originator_return_institution` (9 digits; TD `0004` + transit), `:originator_return_account` (11 digits), `:file_creation_number` (4 digits, 0001–9999), `:encoding` (`:ascii`), `:record_separator` (`"\r\n"`), receiver institution (3 digits) and transit (5 digits), account (alphanumeric, at most 12, never truncated), names, and amounts; builds A/C/Z records; packs six payments per C record and pads unused segments with 240 spaces; trailer totals cents and transaction count. `effective_date` defaults to the run payment date, `created_at` defaults to now, and all dates use `0YYDDD`. There is no encoding or separator default; `:ebcdic` refuses with `:not_implemented` until a certified encoder exists. No bank-calendar/date-window policy is invented; only the CPA encoding and TD field edits are enforced. |
| `samen_core/lib/samen/scopes/finance/ap_ach_file.ex` | **No behavioral change.** Do not add a format flag, a CAD branch, or a shared record builder that changes bytes. The existing USD golden test is the regression fence. |
| `samen_core/lib/samen/scopes/finance/vendor_payment_profile.ex` | Add `@rails [:ach_usd, :eft_cad]`; `get/4` with a defaulted rail; `prevalidate/2` with a defaulted rail; rail in `register/1` and `change_bank_details/1`; `payment_details/2` returns rail-specific receiver fields: ACH `%{receiver_name, receiver_account, receiver_dfi, account_type, rail: :ach_usd}`, CAD `%{receiver_name, receiver_account, receiver_institution, receiver_transit, account_type, rail: :eft_cad}`. ACH behavior is byte-for-byte the same; CAD requires institution/transit and a 12-character account. `store_tokens!/3` stores `:account_number` plus `:routing_number` for ACH, or both `:institution_number` and `:transit_number` for CAD. `verify/1` is rail-pinned through `get/4`. |
| `samen_core/lib/samen/scopes/finance/vendor_payment_profile_record.ex` | Add `rail` (Ecto.Enum, default `:ach_usd`), `institution_number`, `transit_number`, `institution_last4`, `transit_last4`; make `routing_number` optional only for CAD; conditional required fields by rail; unique constraint `[:org_id, :vendor_id, :rail]` named `:fvp_vendor_payment_profile_org_vendor_rail_index`; validate every present token is `vt_*`; `change_details_changeset/2` accepts the new fields but not `:rail`. |
| `samen_core/lib/samen/scopes/finance/ap_ach_artifact.ex` | `store/1` accepts `rail:` (default `:ach_usd` for existing callers), validates the rail and that the run currency matches it, snapshots `rail`, `file_creation_number` and rail-specific fingerprints, and chooses the default artifact name by rail (`ach-…ach` unchanged, `eft-…txt` for CAD). CAD bytes are still PII: store them through the same `:pii_bank` vault and `:ach_file` token label, never a second storage path. `list/3` and `reveal/2` stay the same read paths for both rails. |
| `samen_core/lib/samen/scopes/finance/ap_ach_artifact_record.ex` | Add `rail` (Ecto.Enum, default `:ach_usd`), `file_creation_number`, `originator_institution_last4`, `originator_return_account_last4`, `receiver_institution_last4`, `receiver_transit_last4`; cast/validate `rail` in `[:ach_usd, :eft_cad]`; require the FCN and return-account fingerprint when `rail == :eft_cad`, and keep the existing digest/token/size validations. |

**Web**

| File | Change |
|---|---|
| `samen_web/lib/samen/web/erp/ap_payments_live.ex` | Add `ach_rail`, `profile_rail` and `originator_environment` assigns. Infer the file rail from `run.currency` (`USD` → `:ach_usd`, `CAD` → `:eft_cad`, otherwise refuse), and initialize **both** `ach_rail` and `profile_rail` from the loaded run so a CAD run opens the CAD profile, not the ACH one. Read the originator environment through `ApEftOriginatorProfile.environment/0`; do not default it. Load `vendor_profile` by `{org, vendor, profile_rail}`; on `save_profile` load/save and on `verify_profile`, pass the submitted/selected rail. Pass `rail:` to `register/change_bank_details/verify`. Branch the render/store path: `ApAchFile` for `:ach_usd`, `ApEftFile` for `:eft_cad`; pass `originator: %{name: …, id: …, dfi: …}` for ACH and the `ApEftOriginatorProfile.render_details/3` plus `allocate_file_creation_number/3` result for CAD (environment, 10-digit client number, `00420`, `0004` + transit return institution, vaulted 11-digit return account, encoding/separator, FCN), plus the rail-specific receiver details; keep the vault-then-artifact order. Replace `ach_name/2` with `file_name(rail, run, vendor_id)`: the ACH name is unchanged, CAD is `eft-…txt` with the same multi-vendor short-id rule. Add the profile rail select, conditional routing vs institution/transit fields, and a read-only TD originator status card showing the environment; no free FCN or plaintext return-account field is exposed. Refuse `:environment_not_configured`, `:environment_mismatch`, and `:originator_not_configured` before rendering. Update the moduledoc to name both renderers. Keep the existing ACH ids/labels and existing ACH error text; add `build-eft`/`download-eft` ids for CAD and rail-aware messages for `:already_registered` ("on this rail"), `:environment_not_configured`, `:environment_mismatch`, `:originator_not_configured`, and CPA currency/account/identifier errors. |
| `samen_web/lib/samen/web/erp/ap_payment_run_live.ex` | Rename the artifact card copy to "Stored payment files", show a `USD ACH`/`CAD EFT` rail badge from `artifact.rail`, and show receiver institution/transit fingerprints plus the FCN/return-account fingerprint for CAD rows instead of the routing last-four. `load_ach_artifacts/3`, `ApAchArtifact.list/3` and `reveal/2` keep their current shape. |

**Hosts and fixtures**

| File | Change |
|---|---|
| `samenerp/lib/samenerp/erp.ex`, `samenerp/lib/samenerp/billing.ex` | **No mount change.** The Finance mount already exposes `VendorPaymentProfile`, `ApAchArtifact` and the renderers directly; B2 adds no host-supplied module. The TD originator profile is configured once per org and environment through `ApEftOriginatorProfile.configure/1` (host task/seed or console; no new admin UI in B2), and the CAD path refuses `:originator_not_configured` until the selected environment exists. The host proof is a test, not a wiring change. |
| `samen_core/config/test.exs`, `samen_web/config/test.exs`, `samenerp/config/test.exs`, `samenerp/config/config.exs` | Set `config :samen_core, :eft_environment, :test` in all three test configs and `:production` in the host config; there is no library default. If `samenerp/config/runtime.exs` reads `TD_EFT_ENVIRONMENT`, parse it to `:test`/`:production` and fail boot on anything else; do not silently fall back to production on an unknown value. |
| `.gitattributes` | Add `*.ach text eol=lf` (the USD golden is LF-exact) and `*.cpa005 -text` (the CPA-005 golden is CRLF-exact and must not be smudged by `core.autocrlf`). Do not reuse the existing `*.golden` rule for the CPA fixture: it forces LF. |
| `samen_core/test/fixtures/ap_ach_usd_golden.ach` (new) | LF bytes captured from the current `ApAchFile` for the existing two-payment sample before B2 edits. |
| `samen_core/test/fixtures/ap_cpa005_golden.cpa005` (new) | Hand-checked CRLF CPA-005 fixture for a fixed two-payment CAD run, `created_at ~U[2026-11-08 15:04:05Z]`, effective date `~D[2026-11-10]`, TD client number `1123456789`, destination data centre `00420`, return institution `000410202`, 11-digit return account `12345678901`, file creation number `0042`. |

#### CPA-005 contract (the renderer's only layout)

`ApEftFile.render(run, opts)` requires `:originator_name`, `:originator_id` (TD's 10-digit client
number), `:destination_data_centre` (TD `00420`), `:originator_return_institution` (9 digits;
TD `0004` + 5-digit transit), `:originator_return_account` (11 digits), `:file_creation_number`
(4 digits, `0001`–`9999`), `:encoding` (`:ascii` for TD), `:record_separator` (`"\r\n"` for TD),
`:receiver_name`, `:receiver_account`, `:receiver_institution` (3 digits), `:receiver_transit`
(5 digits), and `:account_type`; optional `:originator_short_name`, `:entry_description`,
`:effective_date`, and `:created_at`. It returns `{:ok, file}` or `{:error, reason}` naming the
field. There is no encoding or separator default: the TD originator profile supplies both, and a
missing value refuses. `:ebcdic` refuses with `:not_implemented` until a certified encoder exists.
The run's `payments` are the same per-vendor list `ApPaymentRun.payments_for_vendor/2` returns;
amounts are their `amount_cents`, never re-derived.

Every record is 1464 characters in the selected encoding. A file is one A record, then one or more
C records, then one Z record; records are joined with the selected separator and the file ends with
that separator. The TD profile value is ASCII + CRLF, pending TD's 1464 test file; the 1464-byte
width is measured before the separator.

| Record | Positions | Field | Rule |
|---|---|---|---|
| A | 1 | Record type | `A` |
| A | 2–10 | Record count | `000000001` |
| A | 11–20 | Client number | 10 digits, `originator_id` |
| A | 21–24 | File creation number | TD allocation, `0001`–`9999`; `0000` refused; wraps after `9999` |
| A | 25–30 | Creation date | `0YYDDD` from `created_at` |
| A | 31–35 | Destination data centre | TD `00420`; other values refuse |
| A | 36–55 | Reserved | 20 blanks |
| A | 56–58 | Destination currency | `CAD` |
| A | 59–1464 | Filler | 1406 blanks |
| C | 1 | Record type | `C` |
| C | 2–10 | Logical record count | `000000002`, then increments **per C record**, not per payment |
| C | 11–20 | Client number | same 10 digits as A |
| C | 21–24 | File creation number | same TD allocation as A |
| C | 25–264 | Segment 1 | one payment (below), or 240 blanks |
| C | 265–504 | Segment 2 | one payment, or 240 blanks |
| C | 505–744 | Segment 3 | one payment, or 240 blanks |
| C | 745–984 | Segment 4 | one payment, or 240 blanks |
| C | 985–1224 | Segment 5 | one payment, or 240 blanks |
| C | 1225–1464 | Segment 6 | one payment, or 240 blanks |
| segment | 25–27 | Transaction code | `3` checking, `4` savings |
| segment | 28–37 | Amount | 10 digits, implied cents |
| segment | 38–43 | Payment date | `0YYDDD` from `effective_date` |
| segment | 44–52 | Institution + transit | `0` + 3-digit institution + 5-digit transit |
| segment | 53–64 | Account number | left-justified, blank-padded to 12; longer is an error, never truncated |
| segment | 65–86 | Reserved | 22 zeros |
| segment | 87–89 | Reserved | 3 zeros |
| segment | 90–104 | Client short name | first word of `originator_name`, uppercase, 15 |
| segment | 105–134 | Customer name | `receiver_name`, uppercase, 30 |
| segment | 135–164 | Client name | `originator_name`, uppercase, 30 |
| segment | 165–174 | Originator ID | TD client number, 10 digits |
| segment | 175–193 | Customer number | 19 characters; bill number, falling back to the run reference |
| segment | 194–202 | Institution for returns | TD `0004` + 5-digit originator transit; never zeros |
| segment | 203–214 | Account for returns | TD 11-digit TD Commercial account + 1 space; never blank |
| segment | 215–229 | Client sundry | `entry_description` (default `AP PAYMENT`), 15 |
| segment | 230–251 | Reserved | 22 blanks |
| segment | 252–253 | Reserved | 2 blanks |
| segment | 254–264 | Invalid Data Element ID | 11 zeros |
| Z | 1 | Record type | `Z` |
| Z | 2–10 | Logical record count | next count after the last C |
| Z | 11–20 | Client number | same as A |
| Z | 21–24 | File creation number | same as A |
| Z | 25–38 | Reserved | 14 zeros |
| Z | 39–46 | Reserved | 8 zeros |
| Z | 47–60 | Total amount | 14 digits, sum of C amounts in cents |
| Z | 61–68 | Total transactions | 8 digits, number of C payments |
| Z | 69–1464 | Filler | 1396 zeros |

A C record with fewer than six payments is still 1464 characters: the unused segments are 240
spaces, not omitted. The C record count is the number of 1464-character C records, so seven
payments produce two C records (counts `000000002` and `000000003`) and a Z at `000000004`.

The TD 80-byte layout guide (Treasury Software extract) supplies the same values in positions
37–45 and 46–57: return institution `0004` + transit, and an 11-digit TD Commercial account
followed by one space. TD's 1464 layout must be tested to confirm those positions map to 194–202
and 203–214; this plan treats them as the CPA-005 return fields, not as reserved space. The
10-digit originator/client number is TD-assigned; the destination data centre is always `00420`.

#### Migrations (exactly two, one per app)

1. **Fixture** — `samen_core/priv/test_repo/migrations/20261117130000_add_payment_rail_dimensions.exs`,
   module `SamenCore.TestRepo.Migrations.AddPaymentRailDimensions`, `use Samen.Migration`.
2. **samenerp** — `samenerp/priv/repo/migrations/20261117130000_add_payment_rail_dimensions.exs`,
   module `Samenerp.Repo.Migrations.AddPaymentRailDimensions`, `use Samen.Migration`.

The two files have the same shape; only the module name differs. Both `up/0` blocks do the following.

**TD originator profile table**

```elixir
create table(:eop_ap_eft_originator_profile, primary_key: false) do
  add(:eop_id, :uuid, primary_key: true, default: fragment("gen_random_uuid()"))
  add(:eop_org_id, :uuid, null: false)
  add(:eop_bank, :text, null: false, default: "td_business_central")
  add(:eop_environment, :text, null: false)
  add(:eop_client_number, :text, null: false)
  add(:eop_destination_data_centre, :text, null: false, default: "00420")
  add(:eop_return_institution, :text, null: false)
  add(:pii_eop_return_account, :text, null: false)
  add(:eop_next_file_creation_number, :integer, null: false, default: 1)
  add(:eop_encoding, :text, null: false, default: "ascii")
  add(:eop_record_separator, :text, null: false, default: "crlf")
  add(:eop_inserted_at, :utc_datetime_usec, null: false, default: fragment("now()"))
  add(:eop_updated_at, :utc_datetime_usec, null: false, default: fragment("now()"))
end

create(unique_index(:eop_ap_eft_originator_profile,
  [:eop_org_id, :eop_bank, :eop_environment],
  name: :eop_ap_eft_originator_profile_org_bank_environment_index))

create(constraint(:eop_ap_eft_originator_profile, :eop_td_fields,
  check: """
  eop_bank = 'td_business_central'
  AND eop_environment IN ('test','production')
  AND eop_client_number ~ '^[0-9]{10}$'
  AND eop_destination_data_centre = '00420'
  AND eop_return_institution ~ '^0004[0-9]{5}$'
  AND LEFT(pii_eop_return_account, 3) = 'vt_'
  AND eop_next_file_creation_number BETWEEN 1 AND 9999
  AND eop_encoding = 'ascii'
  AND eop_record_separator = 'crlf'
  """))
```

Add the standard `updated_at` trigger and an `eop_environment_immutable` trigger that refuses an
UPDATE of `eop_environment` and every DELETE (a deleted production row would reset the sequence to
`0001`). The return account is a vault token, never a plaintext column. The unique key is
`{org, bank, environment}`: each environment has its own row and FCN sequence, and test allocation
cannot touch production. There is no default environment; every insert states it. The check is
deliberately ASCII + CRLF: if TD's 1464 test requires EBCDIC or CR-only, widen this check and the
profile together, before the golden is accepted.

**Profile table**

```elixir
alter table(:fvp_vendor_payment_profile) do
  add(:fvp_rail, :text, null: false, default: "ach_usd")
  add(:pii_fvp_institution_number, :text)
  add(:pii_fvp_transit_number, :text)
  add(:fvp_institution_last4, :text)
  add(:fvp_transit_last4, :text)
  modify(:pii_fvp_routing_number, :text, null: true)
end

drop(unique_index(:fvp_vendor_payment_profile, [:fvp_org_id, :fvp_vendor_id],
  name: :fvp_vendor_payment_profile_org_vendor_index))

create(unique_index(:fvp_vendor_payment_profile,
  [:fvp_org_id, :fvp_vendor_id, :fvp_rail],
  name: :fvp_vendor_payment_profile_org_vendor_rail_index))
```

Drop and recreate `fvp_bank_details_vaulted` as a rail-aware check:

```sql
(fvp_rail = 'ach_usd'
 AND LEFT(pii_fvp_account_number, 3) = 'vt_'
 AND pii_fvp_routing_number IS NOT NULL AND LEFT(pii_fvp_routing_number, 3) = 'vt_'
 AND pii_fvp_institution_number IS NULL AND pii_fvp_transit_number IS NULL
 AND fvp_institution_last4 IS NULL AND fvp_transit_last4 IS NULL)
OR
(fvp_rail = 'eft_cad'
 AND LEFT(pii_fvp_account_number, 3) = 'vt_'
 AND pii_fvp_routing_number IS NULL
 AND pii_fvp_institution_number IS NOT NULL AND LEFT(pii_fvp_institution_number, 3) = 'vt_'
 AND pii_fvp_transit_number IS NOT NULL AND LEFT(pii_fvp_transit_number, 3) = 'vt_'
 AND fvp_institution_last4 IS NOT NULL AND fvp_transit_last4 IS NOT NULL)
```

Add `fvp_rail_valid` (`fvp_rail IN ('ach_usd','eft_cad')`). Replace the existing
`fvp_vendor_payment_profile_guard()` function body (same trigger name) so that:

- `fvp_rail` joins `fvp_id`, `fvp_org_id`, `fvp_vendor_id` and `fvp_inserted_at` as immutable on
  UPDATE;
- the vault-token INSERT/UPDATE checks follow the same rail branch as the constraint;
- the bank-detail reset check adds `pii_fvp_institution_number`, `pii_fvp_transit_number`,
  `fvp_institution_last4` and `fvp_transit_last4`; a changed `fvp_rail` is refused separately as
  an immutable identity field, never treated as a detail change;
- the existing dual-control, status and delete rules are unchanged.

**Artifact table**

```elixir
alter table(:ach_ap_payment_ach_file) do
  add(:ach_rail, :text, null: false, default: "ach_usd")
  add(:ach_file_creation_number, :text)
  add(:ach_originator_institution_last4, :text)
  add(:ach_originator_return_account_last4, :text)
  add(:ach_receiver_institution_last4, :text)
  add(:ach_receiver_transit_last4, :text)
end
```

Add `ach_rail_valid` (`ach_rail IN ('ach_usd','eft_cad')`) and `ach_rail_fingerprints`:

```sql
(ach_rail = 'ach_usd'
 AND ach_file_creation_number IS NULL
 AND ach_originator_institution_last4 IS NULL
 AND ach_originator_return_account_last4 IS NULL
 AND ach_receiver_institution_last4 IS NULL
 AND ach_receiver_transit_last4 IS NULL)
OR
(ach_rail = 'eft_cad'
 AND ach_file_creation_number ~ '^[0-9]{4}$'
 AND ach_originator_dfi_last4 IS NULL
 AND ach_receiver_routing_last4 IS NULL
 AND ach_originator_institution_last4 IS NOT NULL
 AND ach_originator_return_account_last4 IS NOT NULL
 AND ach_receiver_institution_last4 IS NOT NULL
 AND ach_receiver_transit_last4 IS NOT NULL)
```

Existing rows default to `ach_usd` and satisfy both checks. The artifact trigger still refuses every
UPDATE and DELETE and still requires a `vt_*` file token; no trigger change is needed for the
fingerprint columns. `down/0` drops `eop_ap_eft_originator_profile` and the new artifact columns,
restores the old `fvp_bank_details_vaulted` check and `{fvp_org_id, fvp_vendor_id}` unique index,
restores `pii_fvp_routing_number NOT NULL`, and restores the pre-B2 trigger function byte-for-byte.
Before dropping, `down/0` raises if `fvp_rail = 'eft_cad'` or `ach_rail = 'eft_cad'` rows exist, so
a rollback cannot erase a live rail. An originator profile with no CAD profile/artifact rows is
configuration only and may be dropped with the table.

#### Tests

| Test file | Cases |
|---|---|
| `samen_core/test/ap_eft_file_test.exs` (new) | `"every A/C/Z record is 1464 bytes and the golden CPA-005 file matches"` reading `test/fixtures/ap_cpa005_golden.cpa005`; `"the TD profile uses ASCII + CRLF, and ApEftFile's explicit CR-only separator contains no LF"`; `"a missing encoding or separator refuses instead of defaulting"`; `"six 240-character segments pack into each C record and unused segments are blank"`; `"A/C/Z counts, Julian dates and trailer cents/count are exact"`; `"seven payments produce two C records and a Z at the next logical count"`; `"TD fields put 00420 in A 31-35, 0004+transit in 194-202, the 11-digit return account in 203-214, and zeros in 254-264"`; `"preserves leading zeros in the client number, institution, transit and account"`; `"checking uses transaction code 3 and savings uses 4"`; `"refuses a non-CAD run"`; `"refuses a 13-character account instead of truncating it"`; `"refuses a bad client number, destination data centre, return institution/account, encoding/separator, file creation number, receiver institution or transit"`; `"refuses FCN 0000 and 10000"`; `"empty payments and non-positive amounts refuse"`. |
| `samen_core/test/finance_ap_eft_originator_profile_test.exs` (new) | `"TD profile stores 00420, 0004+transit and a vaulted 11-digit return account"`; `"production profile starts at FCN 0001"`; `"test allocation never changes the production FCN"`; `"FCN allocates 0001, increments, wraps 9999->0001, never 0000"`; `"two allocators locked on one profile never return the same FCN"`; `"allocating with a mismatched environment refuses"`; `"test and production profiles coexist for one org/bank"`; `"environment is immutable and delete is refused"`; `"an unknown or missing originator environment refuses"`; `"a cross-org originator profile is not found"`; `"a cross-environment originator profile is not found"`; `"a missing originator profile refuses"`. |
| `samen_core/test/ap_eft_fcn_render_test.exs` (new) | `"a production allocation's first FCN 0001 is written into A, C and Z 21-24, and a test allocation cannot change it"`; configure separate `:production` and `:test` profiles, allocate production `0001`, render a seven-payment CAD file, assert every A/C/Z record has `0001` at bytes 21–24, then allocate the test profile and assert the production counter stays at `2`, the test counter is `2`, and re-rendering with the original `0001` is byte-identical. |
| `samen_core/test/ap_ach_file_test.exs` (extend) | `"USD ACH bytes are unchanged from the pre-B2 golden"` reading `test/fixtures/ap_ach_usd_golden.ach`; the existing 94-character/block, header, entry, control, currency and account-limit tests stay green. |
| `samen_core/test/finance_vendor_payment_profile_test.exs` (extend) | `"CAD prevalidation requires a 3-digit institution, 5-digit transit and at most 12 account characters"`; `"CAD identifiers are stored only as vault tokens"`; `"a verified CAD profile reveals receiver_institution and receiver_transit, not receiver_dfi"`; `"one vendor can hold an ACH and a CAD profile, and each lookup is rail-pinned"`; `"a wrong-rail lookup returns nil"`; `"changing CAD details resets only the CAD profile and leaves the ACH profile verified"`; `"a CAD profile still needs a distinct verifier"`; `"a cross-org CAD profile is not found"`. |
| `samen_core/test/finance_ap_ach_artifact_test.exs` (new) | `"stores a CAD artifact with rail, FCN and return fingerprints and reveals the exact bytes"`; `"a CAD artifact refuses a USD run and a USD artifact refuses a CAD run"`; `"a CAD artifact row carries the FCN, originator return institution/account last-four and no routing last-four"`; `"list/3 is org-pinned and returns a run's artifact whatever its rail"`; `"a tampered stored file fails reveal with digest_mismatch"`. |
| `samen_web/test/samen/web/erp_ap_payments_test.exs` (extend) | `"a CAD run builds and stores a CPA-005 file from the CAD profile and TD originator profile"` (asserts 1464-byte records, `CAD` header, `00420`, `000410202`, a masked return account, trailer total, `eft-…txt`, one artifact); `"a CAD run without a TD originator profile refuses with :originator_not_configured"`; `"a test CAD run uses the test profile and leaves production at 0001"`; `"the CAD path refuses a missing or invalid originator environment"`; `"the CAD form has no free FCN or plaintext return-account field"`; `"a CAD run refuses an ACH-only profile"`; `"the profile form saves separate ACH and CAD profiles for one vendor"`; `"a CAD profile cannot be used to build an ACH file"`; the existing USD ACH test still expects `ach-NOV-ACH-1.ach` and the same bytes/name. |
| `samen_web/test/samen/web/erp_ap_payment_run_test.exs` (extend) | `"the run page lists and reveals an ACH artifact and a CAD artifact on their respective runs"` with rail badges and a CAD institution/transit fingerprint; the existing USD-only artifact list/reveal test stays green. |
| `samenerp/test/kubeworkz_ap_eft_test.exs` (new) | `"a CAD run on the real host renders CPA-005 and stores the artifact"` using `Samenerp.Erp.ApInvoice` with CAD bills, `Samenerp.Repo`, a verified CAD profile, a `:test` TD originator profile and `ApAchArtifact.store/1`; `"the host's USD ACH path still produces the same bytes"`; `"a CAD profile cannot be mistaken for the USD profile"`; `"the test run leaves the production FCN at 0001"`. No host mount code changes; this is the real-module proof. |

#### Sabotages (next free numbers after B0's 419–427; 428 is the first)

| Patch | Flips | MUST_FAIL |
|---|---|---|
| `428-acct-b2-eft-currency-guard-dropped.patch` | `ApEftFile` accepts any run currency instead of refusing non-CAD | `refuses a non-CAD run` |
| `429-acct-b2-eft-account-truncated.patch` | `ApEftFile` truncates an account longer than 12 instead of refusing it | `refuses a 13-character account instead of truncating it` |
| `430-acct-b2-eft-segment-packing-wrong.patch` | `ApEftFile` emits one C record per payment (or only one segment per record) | `six 240-character segments pack into each C record and unused segments are blank` |
| `431-acct-b2-eft-trailer-totals-wrong.patch` | `ApEftFile` writes zero total/count into the Z record | `A/C/Z counts, Julian dates and trailer cents/count are exact` |
| `432-acct-b2-profile-rail-key-dropped.patch` | The profile unique key or `get/4` ignores the rail, collapsing `{org, vendor}` back to one profile | `one vendor can hold an ACH and a CAD profile, and each lookup is rail-pinned` |
| `433-acct-b2-cad-validation-aba-fallback.patch` | CAD `prevalidate/2` requires an ABA routing number instead of institution/transit | `CAD prevalidation requires a 3-digit institution, 5-digit transit and at most 12 account characters` |
| `434-acct-b2-artifact-rail-guard-dropped.patch` | `ApAchArtifact.store/1` skips the rail/currency match or defaults a CAD store to `ach_usd` | `a CAD artifact refuses a USD run and a USD artifact refuses a CAD run` |
| `435-acct-b2-web-cad-uses-ach.patch` | The web's `:eft_cad` branch calls `ApAchFile` instead of `ApEftFile` | `a CAD run builds and stores a CPA-005 file from the CAD profile and TD originator profile` |
| `436-acct-b2-profile-form-ignores-rail.patch` | The profile form always saves/loads `ach_usd`, ignoring the selected rail | `the profile form saves separate ACH and CAD profiles for one vendor` |
| `437-acct-b2-ach-bytes-changed.patch` | `ApAchFile` changes a field width or separator while adding the rail work (for example account width 12) | `USD ACH bytes are unchanged from the pre-B2 golden` |
| `438-acct-b2-td-data-centre-fallback.patch` | `ApEftFile` writes a generic/`00220` data centre when the TD profile is absent | `TD fields put 00420 in A 31-35, 0004+transit in 194-202, the 11-digit return account in 203-214, and zeros in 254-264` |
| `439-acct-b2-td-return-fields-zeroed.patch` | `ApEftFile` leaves 194–202 zeros and 203–214 blank instead of TD return institution/account | `TD fields put 00420 in A 31-35, 0004+transit in 194-202, the 11-digit return account in 203-214, and zeros in 254-264` |
| `440-acct-b2-fcn-reused.patch` | `ApEftOriginatorProfile.allocate_file_creation_number/3` returns 0000 or never advances/reuses | `FCN allocates 0001, increments, wraps 9999->0001, never 0000` |
| `441-acct-b2-invalid-data-element-blanks.patch` | `ApEftFile` writes 11 blanks at 254–264 instead of zeros | `TD fields put 00420 in A 31-35, 0004+transit in 194-202, the 11-digit return account in 203-214, and zeros in 254-264` |
| `442-acct-b2-framing-defaulted.patch` | `ApEftFile` defaults to ASCII/CRLF when `:encoding`/`:record_separator` are missing | `a missing encoding or separator refuses instead of defaulting` |
| `443-acct-b2-eft-test-fcn-consumes-production.patch` | Test allocation shares or advances the production profile's counter | `test allocation never changes the production FCN` |
| `444-acct-b2-eft-production-fcn-not-0001.patch` | A new production profile starts at 0/2 instead of 0001 | `production profile starts at FCN 0001` |
| `445-acct-b2-eft-environment-not-fail-closed.patch` | `environment/0` defaults to production or accepts an unknown value | `an unknown or missing originator environment refuses` |
| `446-acct-b2-eft-environment-mutable-or-deletable.patch` | The schema allows changing `eop_environment` or deleting an originator profile | `environment is immutable and delete is refused` |
| `447-acct-b2-eft-environment-key-dropped.patch` | The unique key collapses back to `{org, bank}`, so test and production cannot coexist | `test and production profiles coexist for one org/bank` |
| `448-acct-b2-eft-environment-mismatch-allowed.patch` | `allocate_file_creation_number/3` advances a profile whose environment differs from the caller | `allocating with a mismatched environment refuses` |
| `449-acct-b2-eft-get-ignores-environment.patch` | `get/3` returns a profile from another environment | `a cross-environment originator profile is not found` |
| `450-acct-b2-fcn-not-written-to-all-records.patch` | `ApEftFile` writes a different FCN into A, C or Z (or only one record type) | `a production allocation's first FCN 0001 is written into A, C and Z 21-24, and a test allocation cannot change it` |

Each patch uses the harness header shape (`# APP:`, `# TEST_FILES:`, `# MUST_FAIL:`) and must
revert byte-exact. `TEST_FILES` are app-relative (for example
`test/ap_eft_file_test.exs`, `test/samen/web/erp_ap_payments_test.exs`).

#### Land order

1. **Schema belt first.** Add both `20261117130000_add_payment_rail_dimensions.exs` migrations,
   no service edits. Check `cd samen_core && mix compile --warnings-as-errors`, then
   `MIX_ENV=test mix ecto.migrate` and `MIX_ENV=test mix ecto.rollback` on a pre-CAD fixture DB;
   repeat in `samenerp`. The CAD-data refusal is a pre-drop `SELECT EXISTS` check and is asserted
   against a seeded CAD row in a scratch database/schema, never by rolling back the shared fixture
   DB after seeding a row.
2. **TD originator profile + CAD renderer.** Add `ApEftOriginatorProfile` and its record first;
   set `config :samen_core, :eft_environment, :test` in `samen_core/config/test.exs`, then run
   `cd samen_core && mix test test/finance_ap_eft_originator_profile_test.exs`. Then add
   `ApEftFile`, both golden fixtures and the two `.gitattributes` rules; capture the USD golden
   from the current `ApAchFile` **before** touching any Finance module. Run
   `cd samen_core && mix test test/finance_ap_eft_originator_profile_test.exs test/ap_eft_fcn_render_test.exs test/ap_eft_file_test.exs test/ap_ach_file_test.exs`;
   the USD test must pass without a byte change. The CPA golden remains provisional until TD
   accepts a test upload of the same file (record the date and TD reference here); if TD rejects
   the framing or return fields, fix the profile before proceeding, not the fixture.
3. **Profile rail model.** Update `VendorPaymentProfileRecord` and `VendorPaymentProfile`; run
   `cd samen_core && mix test test/finance_vendor_payment_profile_test.exs`. All existing ACH
   tests stay green; the CAD-vault, rail-key and wrong-rail cases land here.
4. **Artifact rail model.** Update `ApAchArtifactRecord` and `ApAchArtifact`; run
   `cd samen_core && mix test test/finance_ap_ach_artifact_test.exs test/ap_ach_file_test.exs`.
   The fixture migration from step 1 must already be applied.
5. **Web profile + run shell.** Add `profile_rail`, `originator_environment`, the profile rail
   select, conditional ACH vs CAD fields, and infer `ach_rail` from the run currency. Set
   `:samen_core, :eft_environment` in the web test config to `:test`; there is no fallback. Keep the
   ACH form ids and labels. Run `cd samen_web && mix test test/samen/web/erp_ap_payments_test.exs`;
   the existing USD flow must pass before the CAD flow test is written.
6. **Web CAD path.** Branch `ApEftFile`/`ApAchFile`, pass rail-specific originator/receiver maps
   with the explicit environment, add the read-only TD originator status card and artifact card
   copy, and add the environment/not-configured refusals, then run
   `cd samen_web && mix test test/samen/web/erp_ap_payments_test.exs test/samen/web/erp_ap_payment_run_test.exs`.
7. **Host proof.** Set `:samen_core, :eft_environment` to `:test` in `samenerp/config/test.exs`, add
   `samenerp/test/kubeworkz_ap_eft_test.exs`, and configure a `:test` TD originator profile; assert
   the production profile is still at `0001` after the test run. Run
   `cd samenerp && MIX_ENV=test bash ci.sh`. No host mount change is expected; if the test cannot
   reach the Finance services through `Samenerp.Erp`, stop and fix the mount rather than adding a
   second service path.
8. **Gate.** Add patches 428–450; run
   `SAMEN_SABOTAGE=1 ./scripts/sabotage.sh --app samen_core --range 428-434`,
   `SAMEN_SABOTAGE=1 ./scripts/sabotage.sh --app samen_web --range 435-436`, and
   `SAMEN_SABOTAGE=1 ./scripts/sabotage.sh --app samen_core --range 437-450`, then `./ci-fast.sh`
   and finally `./ci.sh` to `ROOT CI: ALL PASSED`.

#### Definition of done

- A CAD run produces one CPA-005 file per vendor, each with A/C/Z records, every record exactly
  1464 bytes before the separator, six 240-byte segment slots per C record, `CAD` in the header,
  Julian `0YYDDD` dates, the TD-profile ASCII/CRLF framing, and a Z trailer whose total and
  transaction count equal that vendor's CAD cents and payments.
- A non-CAD run refuses `ApEftFile`; a non-USD run still refuses `ApAchFile`; a CAD profile cannot
  build ACH and an ACH profile cannot build CAD.
- One vendor can hold both an ACH and a CAD profile; each lookup is `{org, vendor, rail}`-pinned,
  and changing one rail's details resets only that rail's verification.
- CAD institution and transit are vault tokens; the account is at most 12 characters and is never
  truncated; a 13-character account refuses before storage or rendering.
- A CAD artifact stores `ach_rail = 'eft_cad'`, the allocated FCN, institution/transit and return
  account last-four fingerprints, the vault token and digest; `list/3` and `reveal/2` work for both
  rails, cross-org lookups find nothing, and a tampered file fails `digest_mismatch`.
- The TD originator profile is org/bank/environment-pinned and stores the 10-digit client number,
  `00420`, the `0004` + transit return institution, a vaulted 11-digit return account,
  encoding/separator and next FCN; allocation returns `0001`–`9999`, refuses `0000`, wraps
  `9999`→`0001`, and two allocators never reuse a value.
- Test and production profiles are separate rows with independent FCN sequences. Production starts
  at `0001`; allocating test files never changes the production counter. The environment is
  explicit, immutable, delete-refused, and mismatch-refused; there is no default to production.
- The first production allocation is `0001` and is the file submitted first. B2 has no upload
  confirmation, so a discarded pre-submission production file is an explicit stop, not a silent
  `0002`; adding void/reuse requires TD's unsent-FCN rule.
- Local sequence separation does not control TD's server-side used-FCN window: if test files are
  uploaded under the production Originator ID, use TD's test originator ID or confirm with TD that
  those uploads do not count against production's last-18 window.
- A CAD file carries `00420` in A 31–35, `0004` + transit in segment 194–202, the 11-digit return
  account + one space in 203–214, 11 zeros in 254–264, and the allocated FCN in A/C/Z 21–24.
- The rendered TD file, not only the profile counter, proves the split: a production allocation's
  first FCN is `0001` in A, every C and Z 21–24; a test-profile allocation cannot change the
  production counter or the production file's bytes.
- TD has accepted a 1464 test upload with ASCII/CRLF and the return fields above (date and TD
  reference recorded); without that acceptance, B2 is implementation-complete but not
  production-ready.
- The USD ACH golden fixture is byte-identical; the existing `ach-…ach` name and 94-character
  records are unchanged.
- The paid-run file card infers the rail from the run currency, never offers a free wrong-rail
  choice, and keeps the verified-profile-only destination rule; the run page lists and reveals
  both rails.
- Both migrations, including `eop_ap_eft_originator_profile`, apply and roll back on a pre-CAD
  database; after CAD data, `down/0` refuses rather than deleting the rail. All three app suites
  and `./ci.sh` are green.
- No `ApPaymentRun` change, no new `PostingAccount` key, no host mount change, and no
  `format:` flag on either renderer.

**Out:** positive pay, wire/SEPA (N10), CAD tax/remittance, multi-currency runs.

### B4 — Tax is a promotion, and posting needs B0

**What the code says.**
- `TaxRate` (`define_tax_rate/5`, defined in `credit_note_blueprint.ex`) is one row per org with
  `name`, a percentage **string**, `type ∈ {sales, vat, withholding}`, and `is_active`. It has no
  jurisdiction, no effective dates, and **no call site** — no table exists.
- `TaxCalculator` reads `WHERE id = $1 AND is_active = true` with **no `org_id` predicate** (a
  cross-org rate read if an id is known), converts the rate to a float, and is on the ADR-055
  preserved test-oracle list.
- `Billing.Invoice` has `tax_amount_cents` and `tax_lines`, documented as provider mirrors
  ("never computed here"; `nil` is an honest "provider computed none", not zero). `line_items` is a
  bounded jsonb with description/quantity/amount and no tax code. Its default currency is **USD**.
- Design §5.2 puts determination and filing out of scope; the host's posting map has no tax key and
  the Kubeworkz chart has no GST/QST account.
- There is no invoice issuance entry (B0), so there is nothing for a tax leg to attach to.

**Scope — split into three.**
- **B4a, determination (no GL):** promote the non-goal with an ADR-054 §5.2 amendment and a host
  confirmation of GST/QST registration. Make `TaxRate` a real resource: `code`, `jurisdiction`,
  `rate` as a decimal string, `effective_from`/`effective_to` (non-overlapping per code),
  `is_active`. Fix `TaxCalculator` to be org-scoped and Decimal-based (no float). Add **local** tax
  fields to the invoice, distinct from the provider mirrors (for example `local_tax_cents` and a
  bounded `local_tax_breakdown`), line-level `tax_code` in the bounded jsonb, and a period tax
  register by jurisdiction. Currency/place of supply come from the host, never Billing's `"USD"`
  default.
- **B4b, posting (depends on B0 + B4a):** widen the closed `PostingAccount.key` enum with
  `:tax_payable`, seed the host chart account, and add the tax credit to B0's issuance entry.
  Credit notes reverse the tax leg. The tax register's collected total ties to the GL liability.
- **B4c, input tax (optional first):** bill-level tax capture on AP, `:input_tax_receivable`, and a
  net return read. Without it the remittance register is one-sided; keep it separate so B4a/b can
  land first.

**Acceptance.** 5% and 9.975% compute exact cents on a stated base; a rate change is selected by
invoice date, not by "current"; an exempt customer (e.g. a university) needs an explicit exemption
record, never a silent zero; a rate id from another org is invisible; the provider mirror fields
are never written by local determination; a missing rate refuses rather than posting zero; the tax
register and the GL liability agree at period end.

**Out:** filing, nexus, e-invoicing, 1099/T4A (N4); multi-jurisdiction sourcing rules; tax on
payroll.

**Why the first estimate moved (4–6 → 8–11 for a–c, 6–8 for a+b):** the first pass treated this as
"instantiate a rate row and post it." The row has no dates/jurisdiction, the calculator is not
tenant-safe, the invoice fields are mirrors, the chart has no tax account, and the issuance entry
does not exist.

### B6 — Contract asset is two paths, one of which needs B0

**What the code says.**
- `RevenueSchedule.deferred_key` is a closed enum `[:deferred_revenue, :grant_deferred]`, enforced
  by DB checks in three migration sets (core fixture, samenerp, samen_web).
  `RecognitionPosting` already debits whatever `schedule.deferred_key` names and credits `:income`,
  so the grant recognition side is one enum value and one posting key away.
- Grants: `GrantAwardPosting` credits `grant_deferred` on receipt; `GrantClaimDecision` is
  **state-only** — no claim posting and no `grant_receivable` meaning exist. `GrantCompliance`
  already checks recognized ≤ incurred.
- Customers: no production code creates a `RevenueSchedule` for a Billing invoice (only
  `GrantRecognitionOpening` creates one, for grants). There is no invoice issuance entry (B0), so a
  customer contract asset has nothing to convert against. `ArAging` is subledger-only and must not
  grow an "unbilled" bucket by invention.

**Scope — split into two.**
- **B6a, grants (independent):** add `:contract_asset` to the `deferred_key` enum and all three DB
  checks; add a `:contract_asset` posting key (host chart seed); add a claim-approval posting that
  moves the recognized amount from contract asset to a new `:grant_receivable` meaning; add the
  claim-receipt path that clears the receivable. Keep `GrantCompliance`'s recognized ≤ incurred
  check and extend it so the conversion cannot exceed what was recognized.
- **B6b, customers (depends on B0; sequenced after B4a so the issuance branch is stable):** when a schedule is anchored to an invoice, B0 credits
  `:contract_asset` (or `:deferred_revenue`) according to the schedule's key, and invoice issuance
  clears contract asset to AR. No new table, no second AR ledger, no aging bucket.

**Acceptance.** A grant that recognizes before its claim shows a contract-asset balance, and the
approved claim moves exactly that balance to the receivable; a second approval is refused; a claim
larger than recognized refuses; the AR aging/statement still shows only billed amounts; the balance
sheet carries contract assets as their own line, not inside receivables; R9 is extended to cover
the conversion and the schedule's remaining balance reaches zero by close.

**Out:** ASC 606 allocation (N3), customer contract assets without an invoice/schedule (park until
a milestone-billing document exists), AR FX (N5).

**Why the first estimate moved (3–5 → 4–6):** the enum is DB-checked in three places, the claim
path has no posting, and the customer path has neither a schedule nor an issuance entry.

---

## Part C — Recommended order

### Wave 1 — quick wins that unblock daily work (8–11 sessions)

1. **B1 — export package** first: no schema change, immediate value to the accountant/auditor, and
   it establishes the bounded CSV path the rest will reuse.
2. **B2 — CAD EFT rail**: independent of everything else; removes a manual bank-portal step for
   every Canadian vendor run. Keep the USD ACH path byte-identical and prove both currency
   refusals.
3. **B3 — labour driver consumption**: small and self-contained; removes a labelled approximation
   from variance and grant reporting.

### Wave 2 — make the ledger whole (10–13 sessions)

4. **B0 — AR invoice → GL bridge**: the highest-value accounting fix. It puts receivables, product
   revenue, COGS and the inventory credit on the statements, makes `ar_clearing` a real control
   account, and is the prerequisite for B4b and B6b. The currency guard and the CAD bridge fix
   land with it. Do it before tax posting and before customer contract assets.
5. **B5 — attachments**: independent of B0, but pairs with it: an auditor asking why a receivable
   exists wants the invoice and its approval beside the entry.

### Wave 3 — compliance and contract assets (10–14 sessions, plus B4c 2–3)

6. **B4a — tax determination**: can start in parallel with B0. Scope the *determination* only;
   filing/nexus/e-invoicing stay N4. Watch the Billing dual role: the provider mirror keeps its
   `tax_amount_cents`/`tax_lines`; local determination gets distinct fields.
7. **B4b — tax posting**: after B0 and B4a. Add the tax leg to the issuance entry; do not invent a
   second issuance path for tax.
8. **B6a — grant contract asset**: independent of B0; can run alongside B4.
9. **B6b — customer contract asset**: last, because it is the smallest piece and depends on B0's
   issuance branch plus B4a's invoice shape.
10. **B4c — input tax/net remittance**: when AP bills actually carry recoverable tax.

### Wave 4 — preventive controls (7–10 sessions)

11. **B7 — budget phasing/versions/approval**: prerequisite for B8; a commitment check against an
    annual total is nearly meaningless.
12. **B8 — commitment control**: keep commits *derived* from PO status (no stored balance, same
    posture as budget-vs-actual). Release on cancel/close; show committed and available in the
    variance read.
13. **B9 — credit management**: after AR aging is stable (it is), cheap and prevents a predictable
    bad-debt path.

### Wave 5 — protective, at the natural moment (4–5 sessions)

14. **B10 — CCA book**: schedule before the first tax return, not before.
15. **B11 — controlled reopen**: schedule with the first audit cycle; until then keep the one-way
    close and document the correction route.

### Triggered, not sequenced

**B12 inventory counts**, **B13 treasury transfers**, **B14 lease depth** — pull in when a count,
a transfer, or a real lease contract appears. They are sized and ready.

### Totals

| Slice | Sessions |
|---|---|
| Wave 1 (B1–B3) | 8–11 |
| Wave 2 (B0, B5) | 10–13 |
| Wave 3 (B4a, B4b, B6a, B6b) | 10–14 |
| Wave 4 (B7–B9) | 7–10 |
| Wave 5 (B10–B11) | 4–5 |
| **Part B total (B0–B11, no B4c)** | **39–53** |
| Optional B4c | 2–3 |
| Triggered (B12–B14) | 8–10 |

If only three things get funded: **B0 (AR bridge), B2 (CAD EFT), B4a (tax determination)** —
~15–20 sessions. If only one: **B0**, because it is the difference between statements that show
the business and statements that do not.

---

## Gate posture for every item

- **Ledger-touching (B0, B2–B4, B6–B10, B12–B14):** green test + red-path twin + committed sabotage
  that flips a named assertion. A guarantee is not claimed until its refutation replays.
- **New resources:** abbrevs reserved through `mix samen.abbrev.reserve` only; migrations in the
  fixture repo **and** the host (`samenerp`), with the catalog/parity/golden refresh. B4a/B4b touch
  Billing, Finance and the host chart; B6a touches all three revenue migration sets.
- **No new balances:** every added figure is a derived read or an append-only fact. B8's committed
  amount is derived from PO status, not stored. B6's contract asset is a GL balance, not a second
  AR ledger, and AR aging stays billed-only.
- **PII:** B5 is the only new PII-adjacent surface; if the source document can carry a person's
  data, it takes the full masking trio. B2's CAD identifiers join the existing bank vault controls.
- **No chokepoint weakened to make a test pass:** approved bills still post through `:post`,
  payment runs keep dual control, files keep quarantine, and the close stays one-way except
  through B11's Gate.
- **Cross-org:** B4a's calculator fix is mandatory before any promotion — the current SQL has no
  `org_id` predicate, and a rate leak is a tenant boundary failure even in a dormant module.

## Evidence index (what this backlog is grounded in)

- `docs/ws-acct/design.md` §5.1–§5.9 (honesty list), D5 (recognition), D12a (statements: aging is a
  subledger read, statement set is GL), D2 (posting map), and §7 carries.
- `docs/adr/ADR-054-fabless-accounting-books.md` decisions 2, 7–9, 15–16; AP-FX amendment.
- `docs/guides/stripe-tax.md` (the provider-tax path Billing already mirrors).
- `docs/ws-acct/kubeworkz-books.md` §2 and `samenerp/lib/samenerp/kubeworkz/books.ex`
  (`@posting_map`: `ar_clearing` 1100, `deferred_revenue` 2200, no tax key).
- Finance: `ap_ach_file.ex`, `ap_ach_artifact.ex`, `ap_ach_artifact_record.ex`,
  `vendor_payment_profile.ex`, `vendor_payment_profile_record.ex`, `ap_payment_run.ex`,
  `tax_calculator.ex`, `recognition_posting.ex`, `recognition_run.ex`, `revenue_blueprint.ex`,
  `grant_award_posting.ex`, `grant_claim_decision.ex`, `grant_compliance.ex`, `receipt_posting.ex`,
  `credit_note_posting.ex`, `ar_aging.ex`, `balance_sheet.ex`, `period_transition.ex`,
  `period_blueprint.ex`, `budget_blueprint.ex`, `asset_schedule.ex`, `lease_schedule.ex`.
- Billing: `samen_core/lib/samen/scopes/billing/blueprint.ex` (invoice fields, tax mirror,
  `line_items`, USD default); `samen_core/lib/samen/billing/invoice.ex`.
- Inventory/Sales: `samen_core/lib/samen/scopes/inventory/fulfill_order.ex` (`emit_invoice/4`:
  `status: :open`, no entry, `currency: "USD"`); `inventory/goods_posting.ex` (the receipt-side
  Dr inventory / Cr AP entry B0 mirrors); `inventory/reconcile_fulfillment.ex` (the stock↔invoice
  read B0 extends to GL); `blueprint.ex` (`Item.default_inventory_account_id`).
- Functional currency: `finance/ap_fx.ex` (`base_currency/2`, default `"USD"`),
  `finance/blueprint.ex` (`OrgFxSettings`, default `"USD"`), and
  `samenerp/lib/samenerp/kubeworkz/books.ex` (seeds `"CAD"`).
- Web: `samen_web/lib/samen/web/erp.ex` ("no export path at all"),
  `finance/board_pack/csv_controller.ex` (the only export), `erp/ap_payments_live.ex`,
  `erp/ap_payment_run_live.ex`, `erp/ar_aging_live.ex`, `erp/ar_receipts_live.ex`.
- Verifiers: `samen.verify.no_dormant_modules` (TaxCalculator and ApAchArtifact are ratified-live
  exceptions); three `add_finance_revenue_schedules` migrations (the `deferred_key` checks).
