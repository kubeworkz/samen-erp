defmodule Samen.Scopes.Banking do
  @moduledoc """
  The **Banking** universal scope (WS-ERP E9; ADR-049). Ships as a
  **library-authored blueprint** (ADR-004), same shape as `Samen.Scopes.Finance`
  and `Samen.Scopes.Inventory`: `use`-ing this module inside a host's Ash
  domain expands into host-owned resources in the host's namespace.

  ## Resources — `bank_account · statement_line · statement_import · match · rule`

  - **`BankAccount`** — a bank/credit card account linked to a Finance.Account
    (the GL cash account). `name`, `account_id` (FK to Finance.Account),
    `statement_balance_cents` (the last imported statement balance), `currency`.
    Org-scoped. No PII.

  - **`StatementLine`** — a raw imported bank transaction. `bank_account_id`,
    `posted_at`, `amount_cents` (signed: positive = credit, negative = debit),
    `description`, `counterparty`, `import_hash` (SHA-256 for dedup),
    `status ∈ {unmatched, matched, categorized, reconciled}`.
    Append-only after import. No PII.

  - **`StatementImport`** — an import batch with audit trail. `bank_account_id`,
    `file_hash`, `line_count`, `imported_at`. Org-scoped.

  - **`Match`** — links a StatementLine to one or more GL entries.
    `statement_line_id`, `entry_id` (FK to JournalEntry). Exactly-once per
    line (a statement line cannot be matched twice). Amount-strict: the sum
    of matched GL entries must equal the statement line amount (±0.01 tolerance).

  - **`Rule`** — auto-categorization pattern. `pattern` (regex or substring
    matched against statement line description), `account_id` (the GL expense/
    income account), `min_amount_cents` / `max_amount_cents` (optional bounds).
    Evaluated on import; highest-specificity match wins.

  ## Dependencies

  Banking depends on Finance: categorization creates journal entries, matching
  resolves against posted journal entries, reconciliation verifies GL balances.
  The host wires `finance: [entry: ..., posting_account: ...]` like Inventory
  does.

  ## PII map — EMPTY (INV-1)

  Statement line descriptions may contain merchant names but not PII. The
  `pii_classify` backstop ensures nothing vaulted leaks into bank data.
  """

  defmacro __using__(opts) do
    otp_app = Keyword.fetch!(opts, :otp_app)
    repo = Keyword.fetch!(opts, :repo)
    domain = Keyword.fetch!(opts, :namespace)

    finance_opts = Keyword.get(opts, :finance, [])
    entry_mod = Keyword.get(finance_opts, :entry)
    _posting_account_mod = Keyword.get(finance_opts, :posting_account)

    abbrevs = resolve_abbrevs(Keyword.get(opts, :abbrevs), __CALLER__)

    bank_account_mod = Module.concat(domain, BankAccount)
    statement_line_mod = Module.concat(domain, StatementLine)
    statement_import_mod = Module.concat(domain, StatementImport)
    match_mod = Module.concat(domain, Match)
    rule_mod = Module.concat(domain, Rule)

    quote do
      require Samen.Scopes.Banking.Blueprint

      resources do
        resource(unquote(bank_account_mod))
        resource(unquote(statement_line_mod))
        resource(unquote(statement_import_mod))
        resource(unquote(match_mod))
        resource(unquote(rule_mod))
      end

      Samen.Scopes.Banking.Blueprint.define_bank_account(
        unquote(bank_account_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.bank_account),
        unquote(entry_mod)
      )

      Samen.Scopes.Banking.Blueprint.define_statement_line(
        unquote(statement_line_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.statement_line),
        unquote(bank_account_mod)
      )

      Samen.Scopes.Banking.Blueprint.define_statement_import(
        unquote(statement_import_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.statement_import),
        unquote(bank_account_mod)
      )

      Samen.Scopes.Banking.Blueprint.define_match(
        unquote(match_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.match),
        unquote(statement_line_mod),
        unquote(entry_mod)
      )

      Samen.Scopes.Banking.Blueprint.define_rule(
        unquote(rule_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.rule),
        unquote(bank_account_mod)
      )
    end
  end

  # Resolve abbrevs to a plain %{atom => string} map AT EXPANSION TIME.
  # Mirrors Samen.Scopes.Finance and Samen.Scopes.Inventory.
  defp resolve_abbrevs(nil, _caller) do
    %{
      bank_account: "bka",
      statement_line: "bkl",
      statement_import: "bki",
      match: "bkm",
      rule: "bkr"
    }
  end

  defp resolve_abbrevs(overrides, _caller) when is_map(overrides) do
    Map.merge(
      %{
        bank_account: "bka",
        statement_line: "bkl",
        statement_import: "bki",
        match: "bkm",
        rule: "bkr"
      },
      overrides
    )
  end
end
