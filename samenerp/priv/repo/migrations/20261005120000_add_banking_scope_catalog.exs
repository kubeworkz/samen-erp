defmodule Samenerp.Repo.Migrations.AddBankingScopeCatalog do
  @moduledoc """
  WS-ERP E9 host-mount — catalog truth for the FIVE banking tables.

  The DDL landed in `20260918010000` (bka/bkl/bki/bkm/bkr — live in prod), but that
  migration's `catalog_sync` covered only the E10/E13/E14 resources: the banking
  five could not be synced because `Samenerp.Banking.*` did not exist yet (the scope
  was never mounted — the orphan this work closes). Now that `Samenerp.Banking`
  mounts the blueprint, this migration writes the catalog rows (ADR-004
  catalog-in-tx) so `catalog_parity` / `verify.prefixes` see exactly what Ash
  introspects. NO DDL: every table and column already exists and must not change.
  """
  use Samen.Migration

  @resources [
    Samenerp.Banking.BankAccount,
    Samenerp.Banking.StatementLine,
    Samenerp.Banking.StatementImport,
    Samenerp.Banking.Match,
    Samenerp.Banking.Rule
  ]

  def up do
    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)
  end
end
