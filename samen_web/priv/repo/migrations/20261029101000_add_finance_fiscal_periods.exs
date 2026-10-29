defmodule Samen.WebTest.Repo.Migrations.AddFinanceFiscalPeriods do
  @moduledoc """
  WS-ACCT Phase 3 (ADR-054 D7) — fiscal periods and close control in the
  `samen_web` test host (`Samen.WebTest.Erp`, scope-DEFAULT abbrevs
  `fpe`/`fcr`, entry table `fje_journal_entry`).

  Exactly as the `samen_core` fixture migration does it, minus the R10 belt: the
  `samen_web` ERP mount is a deliberate SUBSET of the scope (only the tables the
  `Samen.Web.Erp` surfaces read/write) and carries no belt triggers — the web
  tests exercise the Ash-level gates the UI path rides. The belt itself is
  proven where it lives: the `samen_core` fixture and the `samenerp` host.
  """

  use Samen.Migration

  @resources [Samen.WebTest.Erp.FiscalPeriod, Samen.WebTest.Erp.CloseRun]

  def up do
    create table(:fpe_fiscal_period, primary_key: false) do
      add(:fpe_year, :integer, null: false)
      add(:fpe_month, :integer, null: false)
      add(:fpe_status, :text, null: false, default: "open")
      add(:fpe_closed_at, :utc_datetime)
      add(:fpe_closed_by, :uuid)
      add(:fpe_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:fpe_org_id, :uuid, null: false)
      add(:fpe_inserted_at, :utc_datetime, null: false)
      add(:fpe_updated_at, :utc_datetime, null: false)
    end

    create(index(:fpe_fiscal_period, [:fpe_org_id]))
    create(unique_index(:fpe_fiscal_period, [:fpe_org_id, :fpe_year, :fpe_month]))

    create(
      constraint(:fpe_fiscal_period, :fpe_status_valid,
        check: "fpe_status IN ('open', 'soft_closed', 'closed')"
      )
    )

    create(
      constraint(:fpe_fiscal_period, :fpe_month_valid,
        check: "fpe_month BETWEEN 1 AND 12 AND fpe_year BETWEEN 2000 AND 2999"
      )
    )

    create table(:fcr_close_run, primary_key: false) do
      add(:fcr_status, :text, null: false, default: "in_progress")
      add(:fcr_phases, {:array, :map}, null: false, default: fragment("ARRAY[]::jsonb[]"))
      add(:fcr_started_at, :utc_datetime)
      add(:fcr_completed_at, :utc_datetime)
      add(:fcr_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:fcr_org_id, :uuid, null: false)
      add(:fcr_inserted_at, :utc_datetime, null: false)
      add(:fcr_updated_at, :utc_datetime, null: false)

      add(
        :fcr_period_id,
        references(:fpe_fiscal_period,
          column: :fpe_id,
          name: "fcr_close_run_fcr_period_id_fkey",
          type: :uuid
        ),
        null: false
      )
    end

    create(index(:fcr_close_run, [:fcr_org_id]))
    create(index(:fcr_close_run, [:fcr_period_id]))
    create(unique_index(:fcr_close_run, [:fcr_org_id, :fcr_period_id]))

    create(
      constraint(:fcr_close_run, :fcr_status_valid,
        check: "fcr_status IN ('in_progress', 'completed')"
      )
    )

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    drop(table(:fcr_close_run))
    drop(table(:fpe_fiscal_period))
  end
end
