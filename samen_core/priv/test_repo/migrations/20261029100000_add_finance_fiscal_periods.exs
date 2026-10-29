defmodule SamenCore.TestRepo.Migrations.AddFinanceFiscalPeriods do
  @moduledoc """
  WS-ACCT Phase 3 (ADR-054 D7) — fiscal periods and close control, in the
  `samen_core` test fixture (`SamenCore.Support.FinanceFixture`, abbrevs
  `cfp`/`clr`, entry table `sje_journal_entry`):

    * `cfp_fiscal_period` — one row per org and month: `{year, month, status}`,
      unique per `(org, year, month)`. A missing row is OPEN (that is what keeps
      every mount that never opens a period behaving as before).
    * `clr_close_run` — one row per period: the ten-phase checklist, started at
      `:start`, finished one-way.
    * `sje_journal_entry_period_guard_tg` — the R10 **database belt**: a row
      whose status becomes `posted` while its `entry_date` falls in a CLOSED
      period is refused, marker or no marker, so a raw-SQL write cannot forge
      one either. The belt deliberately does NOT implement soft-close: that is a
      POLICY layer (documents stop, adjustments continue) and lives in
      `Samen.Scopes.Finance.PeriodGuard`, which is the layer that can tell the
      two apart.

  Neither table carries an archive or delete surface: a period is the book's
  publication switch and a close run is a record of a close. `down/0` drops
  them, which is the migration's own privilege, not an API path.

  Catalog rows are written by `catalog_sync/1` in the SAME transaction
  (ADR-004).
  """

  use Samen.Migration

  @resources [
    SamenCore.Support.FinanceFixture.FiscalPeriod,
    SamenCore.Support.FinanceFixture.CloseRun
  ]

  def up do
    create table(:cfp_fiscal_period, primary_key: false) do
      add(:cfp_year, :integer, null: false)
      add(:cfp_month, :integer, null: false)
      add(:cfp_status, :text, null: false, default: "open")
      add(:cfp_closed_at, :utc_datetime)
      add(:cfp_closed_by, :uuid)
      add(:cfp_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:cfp_org_id, :uuid, null: false)
      add(:cfp_inserted_at, :utc_datetime, null: false)
      add(:cfp_updated_at, :utc_datetime, null: false)
    end

    create(index(:cfp_fiscal_period, [:cfp_org_id]))
    create(unique_index(:cfp_fiscal_period, [:cfp_org_id, :cfp_year, :cfp_month]))

    create(
      constraint(:cfp_fiscal_period, :cfp_status_valid,
        check: "cfp_status IN ('open', 'soft_closed', 'closed')"
      )
    )

    create(
      constraint(:cfp_fiscal_period, :cfp_month_valid,
        check: "cfp_month BETWEEN 1 AND 12 AND cfp_year BETWEEN 2000 AND 2999"
      )
    )

    create table(:clr_close_run, primary_key: false) do
      add(:clr_status, :text, null: false, default: "in_progress")
      add(:clr_phases, {:array, :map}, null: false, default: fragment("ARRAY[]::jsonb[]"))
      add(:clr_started_at, :utc_datetime)
      add(:clr_completed_at, :utc_datetime)
      add(:clr_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:clr_org_id, :uuid, null: false)
      add(:clr_inserted_at, :utc_datetime, null: false)
      add(:clr_updated_at, :utc_datetime, null: false)

      add(
        :clr_period_id,
        references(:cfp_fiscal_period,
          column: :cfp_id,
          name: "clr_close_run_clr_period_id_fkey",
          type: :uuid
        ),
        null: false
      )
    end

    create(index(:clr_close_run, [:clr_org_id]))
    create(index(:clr_close_run, [:clr_period_id]))
    create(unique_index(:clr_close_run, [:clr_org_id, :clr_period_id]))

    create(
      constraint(:clr_close_run, :clr_status_valid,
        check: "clr_status IN ('in_progress', 'completed')"
      )
    )

    catalog_sync(@resources)

    # --------------------------------------------------------------------
    # Belt: R10 at the database — a row that becomes POSTED while its date
    # falls inside a CLOSED period is refused. No marker bypass: unlike the
    # posted-immutability belt (which the sanctioned actions arm), nothing an
    # application can do should ever land a posting in a closed period, so this
    # trigger does not even look at `samen.finance_posting`.
    # --------------------------------------------------------------------
    execute """
    CREATE OR REPLACE FUNCTION sje_journal_entry_period_guard()
    RETURNS TRIGGER LANGUAGE plpgsql AS $$
    DECLARE
      period_status text;
    BEGIN
      IF NEW.sje_status IS DISTINCT FROM 'posted' THEN
        RETURN NEW;
      END IF;

      SELECT p.cfp_status INTO period_status
        FROM cfp_fiscal_period p
       WHERE p.cfp_org_id = NEW.sje_org_id
         AND p.cfp_year = EXTRACT(YEAR FROM NEW.sje_entry_date)::int
         AND p.cfp_month = EXTRACT(MONTH FROM NEW.sje_entry_date)::int;

      IF period_status = 'closed' THEN
        RAISE EXCEPTION 'sje_journal_entry: entry dated % falls in a CLOSED fiscal '
          'period for this org (R10) — a posted entry may not be dated inside a closed '
          'period. Post into an open period instead. Entry id: %',
          NEW.sje_entry_date, COALESCE(NEW.sje_id::text, '?');
      END IF;

      RETURN NEW;
    END;
    $$
    """, "DROP FUNCTION IF EXISTS sje_journal_entry_period_guard()"

    execute """
    CREATE TRIGGER sje_journal_entry_period_guard_tg
    BEFORE INSERT OR UPDATE ON sje_journal_entry
    FOR EACH ROW EXECUTE FUNCTION sje_journal_entry_period_guard()
    """, "DROP TRIGGER IF EXISTS sje_journal_entry_period_guard_tg ON sje_journal_entry"
  end

  def down do
    execute "DROP TRIGGER IF EXISTS sje_journal_entry_period_guard_tg ON sje_journal_entry"
    execute "DROP FUNCTION IF EXISTS sje_journal_entry_period_guard()"

    catalog_sync_down(@resources)

    drop(table(:clr_close_run))
    drop(table(:cfp_fiscal_period))
  end
end
