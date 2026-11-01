defmodule Samen.Scopes.Finance do
  @moduledoc """
  The **Finance** universal scope (WS-ERP E1; ADR-049 §2). Ships as a
  **library-authored blueprint** (ADR-004), same shape as `Samen.Scopes.Work`:
  `use`-ing this module inside a host's Ash domain expands into THREE
  host-owned resources in the host's namespace, each a normal `use Samen.Resource`
  with the host's `otp_app`, `repo`, and `domain`.

  ## Resources — `account · journal_entry · journal_line · ap_invoice ·
  ## payment_receipt · posting_account`

  - **`Account`** — the chart of accounts (Tier-0 config row): `code` (unique
    per org), `name`, `kind ∈ {asset, liability, equity, income, expense}`,
    `normal_side ∈ {debit, credit}`, `parent_id` (the self-referential CoA tree,
    cycle-refused — `Samen.Scopes.Finance.CycleGuard`). No PII.
  - **`JournalEntry`** — the append-only-by-posting journal: `entry_date`,
    `memo` (freeform → default-deny-CDC-excluded, not vaulted), `status ∈
    {draft, posted, void}`, `source_key`/`source_id` (the ADR-041 §3.2 object-ref
    anchor — the ledger names its upstream without coupling to it),
    `posted_at`, `voided_entry_id`. Drafts are editable; `:post` freezes the
    entry (a DB trigger refuses UPDATE/DELETE on posted rows); `:void` posts a
    linked REVERSING entry (`Samen.Scopes.Finance.VoidGuard`) — nothing is ever
    destroyed or rewritten.
  - **`JournalLine`** — `entry_id`, `account_id`, `debit_cents`/`credit_cents`
    (unsigned integer cents; **exactly one non-zero per line** —
    `Samen.Scopes.Finance.LineAmounts`).
  - **`ApInvoice`** — a vendor bill (AP document; E2): `vendor_id` (the
    SalesOps.Vendor reference), `number`, dates, embedded jsonb `lines`
    (`account_id` + `amount_cents` + `memo` — the design's P2-promote-if-hot
    shape), `status ∈ {draft, approved, paid, void}`. `:approve` rides the
    ADR-040 approvals engine as an ApprovalRequired GATE (`requester ≠
    approver` is the engine's two-layer enforcement) and posts the
    expense+liability entry anchored `source_key: "ap_invoice"`.
  - **`PaymentReceipt`** — money actually received against a Billing Invoice
    (AR document; E2): `invoice_key: "billing_invoice"` + `invoice_id` (the
    subledger anchor), `amount_cents`, `paid_at`; `:post_receipt` creates the
    anchored JournalEntry (`source_key: "billing_payment"`) in ONE transaction.
    Exactly-once per anchor (`prc_anchor_unique`).
  - **`PostingAccount`** — the host's named GL posting accounts (Tier-0 config
    row; one per org): a CLOSED `key` enum + the same-org `account_id` FK. The
    base four meanings are `{ap_clearing, ar_clearing, cash, income}`; WS-ACCT
    Phase 1 widened the enum in place to the meanings the Kubeworkz books' flows
    need (`wip_foundry`, `finished_goods_chip`, `deferred_revenue`, `grant_deferred`,
    `variance_*`, `mask_expense`, …) — ADR-054 D2. The enum stays closed and
    fail-honest: an unmapped meaning refuses the posting.
  - **`CostObject`** — the cost/analysis registry (WS-ACCT Phase 1; ADR-054 D1):
    `{code, name, kind ∈ {project, chip, cost_pool, fund}}`, org-scoped, unique
    code per org, archivable. The ids the ledger's dimension seam may name.

  ## R10 — the close ↔ period invariant (LOAD-BEARING)

  Two more resources carry the close control (WS-ACCT Phase 3; ADR-054 D7):

  - **`FiscalPeriod`** — `{year, month, status ∈ {open, soft_closed, closed}}`,
    unique per org and month. The state machine is ONE-WAY
    (`Samen.Scopes.Finance.PeriodTransition`): open → soft_closed → closed, with
    no reopen and no destroy route, so a published period stays published.
  - **`CloseRun`** — one row per period, holding the source manual's ten close
    phases (`Samen.Scopes.Finance.ClosePhases`) and the `:complete_phase` /
    `:finish` lifecycle. A run cannot be completed with a phase outstanding and
    a completed run is final.

  `Samen.Scopes.Finance.PeriodGuard` gates every action that lands a POSTED
  entry (`:post`, `:create_reversal` — the factory AP/stock/sales/reversal all
  use — and `:void`): a closed period refuses always, a soft-closed one refuses
  document-sourced posts and admits journal-only adjustments. A missing period
  row is OPEN, which is what keeps every mount that never opens a period
  behaving exactly as before. The database belt (the migrations' trigger)
  refuses a posted row dated inside a closed period even below Ash, and
  `Samen.Scopes.Finance.PeriodReconcile` is the independent read that detects a
  violation either layer missed.

  ## R8 — the standard ↔ actual invariant (LOAD-BEARING)

  Standard costing is a VARIANCE LAYER, never a second valuation (WS-ACCT
  Phase 7; ADR-054 D4). `CostStandard` + `CostStandardLine` are effective-dated
  cards; `CostVariance` is one posted variance fact per class, carrying the
  accounts it names and the exact inputs it was computed from. The run
  (`Samen.Scopes.Finance.VarianceEngine`) uses only the card IN FORCE for the
  period and refuses any other; variances post through the manual's per-type
  disposition table (`Samen.Scopes.Finance.VarianceDisposition`) — yield and
  BOM absorb into inventory, PPV and overhead volume write off to COGS, labour
  and overhead spending write off to R&D. `Samen.Scopes.Finance.ReconcileVariance`
  is the independent R8 read: per row it checks the arithmetic, the in-force
  card, the tie to that card's lines, and that the entry lands exactly on the
  accounts the row names; per variance account it compares Σ rows with the
  GL's Σ (credit − debit). `Samen.Scopes.Finance.CostOfYield` derives cost of
  yield from the card and the absorbed variance. A standard never touches the
  stock ledger's moving average (`StockLevel.avg_unit_cost_cents`) — the
  variance prices the difference, it never revalues inventory.

  ## D9 — the asset register: derived schedules, an exactly-once run

  `Asset` (intangible/equipment) stores a contract, never a schedule:
  `{cost_cents, salvage_cents, life_months, acquired_on}` is the whole rule,
  and `Samen.Scopes.Finance.AssetSchedule` derives every period's slice from
  it, giving the LAST month the division remainder so the term releases
  `cost − salvage` exactly. `AssetPosting` is the only persisted per-period
  fact — one append-only row per `{asset, period}`, naming the expense and
  contra accounts it paid and anchored to its entry (`source_key:
  "asset_posting"`).

  `Samen.Scopes.Finance.DepreciationRun` posts the due month through the
  governed `:depreciate` action, exactly-once in two layers (the run's
  `already_posted?` read; the table's unique index). A disposal is one-way and
  stops the schedule from that month — no catch-up, no write-off. The cascade
  re-derives the slice and refuses any other amount, so the posting and the
  contract cannot disagree. `AssetRegister` is the derived read (schedule,
  accumulated, NBV); `ReconcileAssets` is the independent audit — amount, term,
  disposal, backing entry, the two named legs, and Σ slices == the contra
  account's GL movement.

  ## D10 — obsolescence: a policy, an assessment, a gated write-down

  `InventoryReserve` is a POLICY (basis `:age` or `:item`, a threshold, a
  percentage, the item ids it covers), never a GL balance: the manual writes
  obsolescence straight off inventory (`Dr 8000`), so no reserve contra account
  is opened and the `:inventory_reserve` posting meaning stays unmapped.
  `Samen.Scopes.Finance.ReserveAssessment` is the derived read — FIFO-aged
  quantity from the append-only stock ledger, valued at each level's moving
  average, net of every write-down already posted for the item. `:draft`
  persists that assessment and posts nothing; `:post` carries the ADR-040 Gate,
  re-derives the assessment inside the decision transaction, and refuses a
  draft whose lines no longer match. One entry lands: debit
  `write_down_expense`, credit each inventory account the lines name.

  A host that wants reserve posting passes its Inventory resources at mount
  time:

      use Samen.Scopes.Finance,
        inventory: [item: MyApp.Erp.Item, level: MyApp.Erp.StockLevel,
                    ledger: MyApp.Erp.StockLedger]

  Without that wiring the reserve actions refuse fail-honest
  (`:inventory_not_wired`) rather than posting blind.

  ## R6 — the dimension invariant (LOAD-BEARING)

  `JournalLine.dimension_refs` is a bounded jsonb map from the frozen
  vocabulary (`project`/`lot`/`fund`/`cost_pool`) to same-org `CostObject` ids
  — **ids only, never names**. Three guards, all fail-closed:

  * WRITE (line): `Samen.Scopes.Finance.DimensionGuard` refuses an unknown key,
    a non-id value (which is what keeps the axis from becoming a
    de-anonymisation channel), and a cross-org/absent cost object.
  * ENTRY: `Samen.Scopes.Finance.DimensionBalance` refuses a partially
    dimensioned entry (R6a) and a cost object whose debits ≠ credits (R6b),
    both over the `lines` argument and over the persisted rows at `:post`.
  * READ: `Samen.Scopes.Finance.DimensionReconcile` reports the per-cost-object
    balances and the R6a violations as bare SQL sums over posted lines.

  An undimensioned entry — every base-system posting — passes vacuously.

  ## R1 — the double-entry invariant (LOAD-BEARING)

  `Σ debits == Σ credits` per entry, always, by construction:

  * WRITE side: `Samen.Scopes.Finance.UnbalancedEntry` refuses a create/update
    whose `lines` argument does not sum to zero (before_action, in-transaction).
  * POST side: `:post` re-runs the same guard over the lines argument.
  * READ side: `Samen.Scopes.Finance.Reconcile` computes balances as bare SQL
    sums over posted lines; org_balance is zero, always. Non-zero is a broken
    ledger — the reconciliation red-path suite proves both the invariant and
    its refutability (sabotage 302).

  ## PII map — EMPTY (INV-1)

  No resource in this scope carries a vault-routed field. Every column is a
  bounded id, enum, integer, timestamp, or bounded map. `memo` fields are
  freeform user content — default-deny-CDC-excluded, not vaulted (Work-scope
  parity). The vendor's 🔒 contact stays vaulted WHERE IT LIVES (SalesOps
  Vendor); Finance references `vendor_id`, never re-declares the person.

  ## R2 — the Finance↔Billing reconciliation (LOAD-BEARING)

  For any period, Σ(`PaymentReceipt` cash) == Σ(Billing Payment mirror
  amounts) — the reconciliation red-path (design §6.3). The GL side is
  computed by `Samen.Scopes.Finance.ReconcilePayments` (a bare SQL sum over
  the anchored entries: exactly the cash postings), so a divergence is a
  broken spine, not a rounding opinion.  Non-vacuous via anti-tautology
  (sabotage 303's bypass flips the R2 red paths).

  ## Mounting the Finance scope (the host side)

      defmodule Demo.FinanceScope do
        use Ash.Domain, validate_config_inclusion?: false

        use Samen.Scopes.Finance,
          otp_app: :demo,
          repo: Demo.Repo,
          namespace: Demo.FinanceScope

  This defines, in the host's namespace:

    * `Demo.FinanceScope.Account`
    * `Demo.FinanceScope.JournalEntry`
    * `Demo.FinanceScope.JournalLine`
    * `Demo.FinanceScope.ApInvoice`
    * `Demo.FinanceScope.PaymentReceipt`
    * `Demo.FinanceScope.PostingAccount`
    * `Demo.FinanceScope.CostObject`
    * `Demo.FinanceScope.FiscalPeriod`
    * `Demo.FinanceScope.CloseRun`
    * `Demo.FinanceScope.RevenueSchedule`
    * `Demo.FinanceScope.RevenueRecognition`
    * `Demo.FinanceScope.CostStandard`
    * `Demo.FinanceScope.CostStandardLine`
    * `Demo.FinanceScope.CostVariance`
    * `Demo.FinanceScope.Asset`
    * `Demo.FinanceScope.AssetPosting`
    * `Demo.FinanceScope.InventoryReserve`
    * `Demo.FinanceScope.ReserveWriteDown`
    * `Demo.FinanceScope.ReserveWriteDownLine`

  ## Posting accounts (`posting_accounts:`)

  Every posting action (E2) resolves the org's named GL accounts through
  `PostingAccount` rows: `ap_clearing` (the liability), `ar_clearing` (the
  receivable), `cash`, `income`. A mount without the rows REFUSES the posting
  fail-honest — accounts are a host decision, never invented by the scope.

  ## Abbrevs (permanent, registry-checked)

  Each resource carries a permanent 3-letter abbrev, reserved in
  `samen_core/priv/abbrev_registry.json` under the HOST module name via
  `mix samen.abbrev.reserve` (ADR-023 — the macro does NOT invent abbrevs):

    * `Demo.FinanceScope.Account`       → `fca` (demo default)
    * `Demo.FinanceScope.JournalEntry`  → `fje` (demo default)
    * `Demo.FinanceScope.JournalLine`   → `fjl` (demo default)
    * `Demo.FinanceScope.ApInvoice`     → `fai` (demo default)
    * `Demo.FinanceScope.PaymentReceipt` → `frr` (demo default)
    * `Demo.FinanceScope.PostingAccount` → `fpa` (demo default)
    * `Demo.FinanceScope.CostObject`     → `fco` (demo default; WS-ACCT Phase 1)
    * `Demo.FinanceScope.FiscalPeriod`   → `fpe` (demo default; WS-ACCT Phase 3)
    * `Demo.FinanceScope.CloseRun`       → `fcr` (demo default; WS-ACCT Phase 3)

  Other hosts pass `abbrevs:` overrides (mirroring `Samen.Scopes.Work`'s
  `abbrevs:` plumbing) when the defaults are already claimed.
  """

  # Demo defaults are UNCLAIMED-in-the-registry abbrevs (ADR-025 discipline: a
  # default that collides with an existing owner — e.g. the original `fac` pick,
  # claimed by Driftwood.Crm.Activity — is a foot-gun, so defaults must verify
  # free). A host whose namespace already claims one of these passes `abbrevs:`
  # overrides (allocator-reserved, ADR-023).
  @default_abbrevs %{
    account: "fca",
    journal_entry: "fje",
    journal_line: "fjl",
    ap_invoice: "fai",
    payment_receipt: "frr",
    posting_account: "fpa",
    budget: "fbg",
    budget_line: "fbl",
    exchange_rate: "fxr",
    org_fx_settings: "fxf",
    # WS-ACCT Phase 1 (ADR-054 D1): the cost/analysis registry the dimension
    # seam names. Reserved by the allocator under the `samen_web` host (whose
    # mount takes the scope defaults).
    cost_object: "fco",
    # WS-ACCT Phase 3 (ADR-054 D7): the close control — the fiscal month and its
    # checklist. Also allocator-reserved under the `samen_web` host.
    fiscal_period: "fpe",
    close_run: "fcr",
    # WS-ACCT Phase 6 (ADR-054 D5): deferred revenue's schedule and its
    # per-period recognitions. Allocator-reserved under the `samen_web` host
    # (the fixture and samenerp pass their own overrides).
    revenue_schedule: "frs",
    revenue_recognition: "frn",
    # WS-ACCT Phase 7 (ADR-054 D4): standard costing's card, its lines, and the
    # posted variance. Allocator-reserved under the `samen_web` host.
    cost_standard: "fst",
    cost_standard_line: "fsu",
    cost_variance: "fsw",
    # WS-ACCT Phase 8 (ADR-054 D9): the asset register and its per-period
    # postings. Allocator-reserved under the `samen_web` host.
    asset: "fas",
    asset_posting: "fad",
    # WS-ACCT Phase 9 (ADR-054 D10): the obsolescence policy, its gated
    # write-down and the assessed lines. Allocator-reserved under `samen_web`.
    inventory_reserve: "fro",
    reserve_write_down: "frv",
    reserve_write_down_line: "frw"
  }

  @doc false
  def default_abbrevs, do: @default_abbrevs

  defmacro __using__(opts) do
    otp_app = Keyword.fetch!(opts, :otp_app) |> Macro.expand(__CALLER__)
    repo = Keyword.fetch!(opts, :repo) |> Macro.expand(__CALLER__)
    namespace = Keyword.fetch!(opts, :namespace) |> Macro.expand(__CALLER__)
    domain = __CALLER__.module

    # Resolve abbrevs to a plain %{atom => string} map AT EXPANSION TIME so each
    # blueprint call receives a LITERAL abbrev string (mirrors Samen.Scopes.Work —
    # the base macro validates abbrevs caller-side and requires a compile-time literal).
    abbrevs = resolve_abbrevs(Keyword.get(opts, :abbrevs), __CALLER__)
    inventory = resolve_inventory(Keyword.get(opts, :inventory), __CALLER__)

    account_mod = Module.concat(namespace, Account)
    entry_mod = Module.concat(namespace, JournalEntry)
    line_mod = Module.concat(namespace, JournalLine)
    ap_invoice_mod = Module.concat(namespace, ApInvoice)
    receipt_mod = Module.concat(namespace, PaymentReceipt)
    posting_account_mod = Module.concat(namespace, PostingAccount)
    budget_mod = Module.concat(namespace, Budget)
    budget_line_mod = Module.concat(namespace, BudgetLine)
    exchange_rate_mod = Module.concat(namespace, ExchangeRate)
    org_fx_settings_mod = Module.concat(namespace, OrgFxSettings)
    cost_object_mod = Module.concat(namespace, CostObject)
    fiscal_period_mod = Module.concat(namespace, FiscalPeriod)
    close_run_mod = Module.concat(namespace, CloseRun)
    revenue_schedule_mod = Module.concat(namespace, RevenueSchedule)
    revenue_recognition_mod = Module.concat(namespace, RevenueRecognition)
    cost_standard_mod = Module.concat(namespace, CostStandard)
    cost_standard_line_mod = Module.concat(namespace, CostStandardLine)
    cost_variance_mod = Module.concat(namespace, CostVariance)
    asset_mod = Module.concat(namespace, Asset)
    asset_posting_mod = Module.concat(namespace, AssetPosting)
    inventory_reserve_mod = Module.concat(namespace, InventoryReserve)
    reserve_write_down_mod = Module.concat(namespace, ReserveWriteDown)
    reserve_write_down_line_mod = Module.concat(namespace, ReserveWriteDownLine)

    quote do
      require Samen.Scopes.Finance.Blueprint

      require Samen.Scopes.Finance.BudgetBlueprint

      require Samen.Scopes.Finance.PeriodBlueprint

      require Samen.Scopes.Finance.RevenueBlueprint

      require Samen.Scopes.Finance.VarianceBlueprint

      require Samen.Scopes.Finance.AssetBlueprint

      require Samen.Scopes.Finance.ReserveBlueprint

      resources do
        resource(unquote(account_mod))
        resource(unquote(entry_mod))
        resource(unquote(line_mod))
        resource(unquote(ap_invoice_mod))
        resource(unquote(receipt_mod))
        resource(unquote(posting_account_mod))
        resource(unquote(budget_mod))
        resource(unquote(budget_line_mod))
        resource(unquote(exchange_rate_mod))
        resource(unquote(org_fx_settings_mod))
        resource(unquote(cost_object_mod))
        resource(unquote(fiscal_period_mod))
        resource(unquote(close_run_mod))
        resource(unquote(revenue_schedule_mod))
        resource(unquote(revenue_recognition_mod))
        resource(unquote(cost_standard_mod))
        resource(unquote(cost_standard_line_mod))
        resource(unquote(cost_variance_mod))
        resource(unquote(asset_mod))
        resource(unquote(asset_posting_mod))
        resource(unquote(inventory_reserve_mod))
        resource(unquote(reserve_write_down_mod))
        resource(unquote(reserve_write_down_line_mod))
      end

      # WS-ACCT Phase 9 (ADR-054 D10) — the obsolescence policy, its derived
      # assessment and the gated write-down. The assessment reads the host's
      # Inventory resources passed via `inventory:` (nil when unwired — the
      # actions then refuse fail-honest rather than posting blind).
      Samen.Scopes.Finance.ReserveBlueprint.define_inventory_reserve(
        unquote(inventory_reserve_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.inventory_reserve)
      )

      Samen.Scopes.Finance.ReserveBlueprint.define_reserve_write_down(
        unquote(reserve_write_down_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.reserve_write_down),
        unquote(inventory_reserve_mod),
        unquote(reserve_write_down_line_mod),
        unquote(entry_mod),
        unquote(posting_account_mod),
        unquote(account_mod),
        unquote(inventory[:item]),
        unquote(inventory[:level]),
        unquote(inventory[:ledger])
      )

      Samen.Scopes.Finance.ReserveBlueprint.define_reserve_write_down_line(
        unquote(reserve_write_down_line_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.reserve_write_down_line),
        unquote(reserve_write_down_mod),
        unquote(account_mod)
      )

      # WS-ACCT Phase 8 (ADR-054 D9) — the asset register and its exactly-once
      # per-period postings. The schedule is derived; the posting cascade posts
      # through this host's entry + posting-account resources.
      Samen.Scopes.Finance.AssetBlueprint.define_asset(
        unquote(asset_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.asset),
        unquote(asset_posting_mod),
        unquote(cost_object_mod)
      )

      Samen.Scopes.Finance.AssetBlueprint.define_asset_posting(
        unquote(asset_posting_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.asset_posting),
        unquote(asset_mod),
        unquote(entry_mod),
        unquote(posting_account_mod),
        unquote(account_mod)
      )

      # WS-ACCT Phase 7 (ADR-054 D4) — standard costing and the variance layer.
      # The card is append-only; the only update action is the period run, whose
      # cascade posts each variance through this host's entry + posting-account
      # resources.
      Samen.Scopes.Finance.VarianceBlueprint.define_cost_standard(
        unquote(cost_standard_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.cost_standard),
        unquote(cost_standard_line_mod),
        unquote(cost_variance_mod),
        unquote(cost_object_mod)
      )

      Samen.Scopes.Finance.VarianceBlueprint.define_cost_standard_line(
        unquote(cost_standard_line_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.cost_standard_line),
        unquote(cost_standard_mod)
      )

      Samen.Scopes.Finance.VarianceBlueprint.define_cost_variance(
        unquote(cost_variance_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.cost_variance),
        unquote(cost_standard_mod),
        unquote(cost_object_mod),
        unquote(entry_mod),
        unquote(posting_account_mod)
      )

      # WS-ACCT Phase 6 (ADR-054 D5) — deferred revenue and its recognition
      # schedule. The schedule aggregates its recognitions; the recognition
      # cascade posts through this host's entry + posting-account resources.
      Samen.Scopes.Finance.RevenueBlueprint.define_revenue_schedule(
        unquote(revenue_schedule_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.revenue_schedule),
        unquote(revenue_recognition_mod),
        unquote(cost_object_mod)
      )

      Samen.Scopes.Finance.RevenueBlueprint.define_revenue_recognition(
        unquote(revenue_recognition_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.revenue_recognition),
        unquote(revenue_schedule_mod),
        unquote(entry_mod),
        unquote(posting_account_mod)
      )

      Samen.Scopes.Finance.PeriodBlueprint.define_fiscal_period(
        unquote(fiscal_period_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.fiscal_period)
      )

      Samen.Scopes.Finance.PeriodBlueprint.define_close_run(
        unquote(close_run_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.close_run),
        unquote(fiscal_period_mod)
      )

      Samen.Scopes.Finance.Blueprint.define_cost_object(
        unquote(cost_object_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.cost_object)
      )

      Samen.Scopes.Finance.Blueprint.define_account(
        unquote(account_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.account)
      )

      Samen.Scopes.Finance.Blueprint.define_journal_entry(
        unquote(entry_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.journal_entry),
        unquote(line_mod),
        unquote(fiscal_period_mod)
      )

      Samen.Scopes.Finance.Blueprint.define_journal_line(
        unquote(line_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.journal_line),
        unquote(account_mod),
        unquote(entry_mod),
        unquote(cost_object_mod)
      )

      Samen.Scopes.Finance.Blueprint.define_ap_invoice(
        unquote(ap_invoice_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.ap_invoice),
        unquote(entry_mod),
        unquote(posting_account_mod)
      )

      Samen.Scopes.Finance.Blueprint.define_payment_receipt(
        unquote(receipt_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.payment_receipt),
        unquote(entry_mod),
        unquote(posting_account_mod)
      )

      Samen.Scopes.Finance.Blueprint.define_posting_account(
        unquote(posting_account_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.posting_account),
        unquote(account_mod)
      )

      # WS-ERP E8: the budget plan (Tier-0 config; budget-vs-actual is the
      # pure READ over these lines vs posted journal activity).
      Samen.Scopes.Finance.BudgetBlueprint.define_budget(
        unquote(budget_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.budget),
        unquote(budget_line_mod)
      )

      Samen.Scopes.Finance.BudgetBlueprint.define_budget_line(
        unquote(budget_line_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.budget_line),
        unquote(budget_mod),
        unquote(account_mod)
      )

      Samen.Scopes.Finance.Blueprint.define_exchange_rate(
        unquote(exchange_rate_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.exchange_rate)
      )

      Samen.Scopes.Finance.Blueprint.define_org_fx_settings(
        unquote(org_fx_settings_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.org_fx_settings)
      )
    end
  end

  defp resolve_inventory(nil, _caller), do: %{}

  defp resolve_inventory(opts, caller) when is_list(opts) do
    Map.new(opts, fn {key, mod} -> {key, Macro.expand(mod, caller)} end)
  end

  defp resolve_inventory(other, _caller) do
    raise ArgumentError,
          "use Samen.Scopes.Finance, inventory: must be a keyword list of module " <>
            "aliases ([item: MyApp.Item, level: MyApp.StockLevel, ledger: MyApp.StockLedger]). " <>
            "Got: #{Macro.to_string(other)}"
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
          "use Samen.Scopes.Finance, abbrevs: must be a compile-time map literal " <>
            "(%{account: \"fca\", journal_entry: \"fje\", journal_line: \"fjl\"}). Got: " <>
            Macro.to_string(other)
  end
end
