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
    row; one per org): `key ∈ {ap_clearing, ar_clearing, cash, income}` + the
    same-org `account_id` FK. The default set every posting action resolves.

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
    posting_account: "fpa"
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

    account_mod = Module.concat(namespace, Account)
    entry_mod = Module.concat(namespace, JournalEntry)
    line_mod = Module.concat(namespace, JournalLine)
    ap_invoice_mod = Module.concat(namespace, ApInvoice)
    receipt_mod = Module.concat(namespace, PaymentReceipt)
    posting_account_mod = Module.concat(namespace, PostingAccount)

    quote do
      require Samen.Scopes.Finance.Blueprint

      resources do
        resource(unquote(account_mod))
        resource(unquote(entry_mod))
        resource(unquote(line_mod))
        resource(unquote(ap_invoice_mod))
        resource(unquote(receipt_mod))
        resource(unquote(posting_account_mod))
      end

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
        unquote(line_mod)
      )

      Samen.Scopes.Finance.Blueprint.define_journal_line(
        unquote(line_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.journal_line),
        unquote(account_mod),
        unquote(entry_mod)
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
          "use Samen.Scopes.Finance, abbrevs: must be a compile-time map literal " <>
            "(%{account: \"fca\", journal_entry: \"fje\", journal_line: \"fjl\"}). Got: " <>
            Macro.to_string(other)
  end
end
