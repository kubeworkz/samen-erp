defmodule Samenerp.Banking do
  @moduledoc """
  Samenerp Banking domain — the WS-ERP E9 mount that makes the orphaned
  `bka/bkl/bki/bkm/bkr` tables (migration `20260918010000`, already live in prod)
  reachable through governed Ash resources.

  `use Samen.Scopes.Banking` expands into the five host-owned resources in this
  namespace (BankAccount · StatementLine · StatementImport · Match · Rule), same
  shape as `Samenerp.Erp`'s Finance/Inventory mounts:

    * `finance:` wires the blueprint's `entry:` seam to THIS host's real GL —
      `Samenerp.Erp.JournalEntry` is what `Match.entry_id` references and what
      `ReconcileGuard`/`MatchAmountGuard` inspect (a match must be amount-strict
      against posted journal lines and must never target a voided entry).
      `account:` names the host's chart-of-accounts `Samenerp.Erp.Account` —
      what `BankAccount.account_id` references (the GL cash/bank account,
      SameOrgFk-guarded), never a JournalEntry.

    * Abbrevs are the scope's permanent defaults (bka/bkl/bki/bkm/bkr) — the SAME
      prefixes the E9 migration already created the prod tables with, so no table
      rename and no new DDL: the tables exist; this mount (plus the catalog-sync
      migration) only makes them catalogued, policy-governed, and reachable.

  No resource in this scope carries a vault-routed field (PII map EMPTY — INV-1),
  so no masking trio applies; `mix samen.verify.pii_classify` is the backstop.
  """
  use Ash.Domain, validate_config_inclusion?: false

  use Samen.Scopes.Banking,
    otp_app: :samenerp,
    repo: Samenerp.Repo,
    namespace: Samenerp.Banking,
    finance: [
      entry: Samenerp.Erp.JournalEntry,
      account: Samenerp.Erp.Account
    ]
end
