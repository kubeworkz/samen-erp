defmodule Samenerp.Repo.Migrations.AddFinanceFiscalPeriods do
  @moduledoc """
  WS-ACCT Phase 3 (ADR-054 D7) — fiscal periods and close control on the REAL
  host (`Samenerp.Erp`, abbrevs `efp`/`efq`, entry table `ecj_journal_entry`).

  `efp_fiscal_period` is the month-by-month publication switch the Kubeworkz
  books close against (`{year, month, status}`, unique per org and month) and
  `efq_close_run` carries the source manual's ten-phase close checklist for one
  period.

  The R10 database belt (`ecj_journal_entry_period_guard_tg`) refuses a row that
  becomes POSTED while its `entry_date` falls in a CLOSED period — below Ash, no
  marker bypass — exactly as the `samen_core` fixture migration does it. The
  soft-close policy (documents stop, journal-only adjustments continue) is NOT
  here: it belongs to `Samen.Scopes.Finance.PeriodGuard`, the layer that can
  tell a document anchor from a ledger adjustment.

  Catalog rows via `catalog_sync/1` in the same transaction (ADR-004).
  """

  use Samen.Migration

  @resources [Samenerp.Erp.FiscalPeriod, Samenerp.Erp.CloseRun]

  def up do
    create table(:efp_fiscal_period, primary_key: false) do
      add(:efp_year, :integer, null: false)
      add(:efp_month, :integer, null: false)
      add(:efp_status, :text, null: false, default: "open")
      add(:efp_closed_at, :utc_datetime)
      add(:efp_closed_by, :uuid)
      add(:efp_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:efp_org_id, :uuid, null: false)
      add(:efp_inserted_at, :utc_datetime, null: false)
      add(:efp_updated_at, :utc_datetime, null: false)
    end

    create(index(:efp_fiscal_period, [:efp_org_id]))
    create(unique_index(:efp_fiscal_period, [:efp_org_id, :efp_year, :efp_month]))

    create(
      constraint(:efp_fiscal_period, :efp_status_valid,
        check: "efp_status IN ('open', 'soft_closed', 'closed')"
      )
    )

    create(
      constraint(:efp_fiscal_period, :efp_month_valid,
        check: "efp_month BETWEEN 1 AND 12 AND efp_year BETWEEN 2000 AND 2999"
      )
    )

    create table(:efq_close_run, primary_key: false) do
      add(:efq_status, :text, null: false, default: "in_progress")
      add(:efq_phases, {:array, :map}, null: false, default: fragment("ARRAY[]::jsonb[]"))
      add(:efq_started_at, :utc_datetime)
      add(:efq_completed_at, :utc_datetime)
      add(:efq_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:efq_org_id, :uuid, null: false)
      add(:efq_inserted_at, :utc_datetime, null: false)
      add(:efq_updated_at, :utc_datetime, null: false)

      add(
        :efq_period_id,
        references(:efp_fiscal_period,
          column: :efp_id,
          name: "efq_close_run_efq_period_id_fkey",
          type: :uuid
        ),
        null: false
      )
    end

    create(index(:efq_close_run, [:efq_org_id]))
    create(index(:efq_close_run, [:efq_period_id]))
    create(unique_index(:efq_close_run, [:efq_org_id, :efq_period_id]))

    create(
      constraint(:efq_close_run, :efq_status_valid,
        check: "efq_status IN ('in_progress', 'completed')"
      )
    )

    catalog_sync(@resources)

    execute """
    CREATE OR REPLACE FUNCTION ecj_journal_entry_period_guard()
    RETURNS TRIGGER LANGUAGE plpgsql AS $$
    DECLARE
      period_status text;
    BEGIN
      IF NEW.ecj_status IS DISTINCT FROM 'posted' THEN
        RETURN NEW;
      END IF;

      SELECT p.efp_status INTO period_status
        FROM efp_fiscal_period p
       WHERE p.efp_org_id = NEW.ecj_org_id
         AND p.efp_year = EXTRACT(YEAR FROM NEW.ecj_entry_date)::int
         AND p.efp_month = EXTRACT(MONTH FROM NEW.ecj_entry_date)::int;

      IF period_status = 'closed' THEN
        RAISE EXCEPTION 'ecj_journal_entry: entry dated % falls in a CLOSED fiscal '
          'period for this org (R10) — a posted entry may not be dated inside a closed '
          'period. Post into an open period instead. Entry id: %',
          NEW.ecj_entry_date, COALESCE(NEW.ecj_id::text, '?');
      END IF;

      RETURN NEW;
    END;
    $$
    """, "DROP FUNCTION IF EXISTS ecj_journal_entry_period_guard()"

    execute """
    CREATE TRIGGER ecj_journal_entry_period_guard_tg
    BEFORE INSERT OR UPDATE ON ecj_journal_entry
    FOR EACH ROW EXECUTE FUNCTION ecj_journal_entry_period_guard()
    """, "DROP TRIGGER IF EXISTS ecj_journal_entry_period_guard_tg ON ecj_journal_entry"
  end

  def down do
    execute "DROP TRIGGER IF EXISTS ecj_journal_entry_period_guard_tg ON ecj_journal_entry"
    execute "DROP FUNCTION IF EXISTS ecj_journal_entry_period_guard()"

    catalog_sync_down(@resources)

    drop(table(:efq_close_run))
    drop(table(:efp_fiscal_period))
  end
end
