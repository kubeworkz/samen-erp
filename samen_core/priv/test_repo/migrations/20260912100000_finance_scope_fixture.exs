defmodule SamenCore.TestRepo.Migrations.FinanceScopeFixture do
  @moduledoc """
  Tables + DB belts for the Finance scope (WS-ERP E1; ADR-049 §2):
  `sac_account` + `sje_journal_entry` + `sjl_journal_line`, mounted in
  `samen_core` tests via `test/support/finance_fixture.ex`.  DB belts (belt over the Ash-side braces):

    * `sje_status_valid` + `sjl_amounts_positive` CHECKs — status enum and
      unsigned cents.
    * `sjl_journal_line_sjl_entry_id_fkey` + `..._sjl_account_id_fkey` — a line
      cannot outlive its entry (no orphans) and always names a real account.
    * `sje_journal_entry_posted_immutable_tg` — the posted-entry belt:
      a non-draft INSERT is refused unless the transaction-local
      `samen.finance_posting` marker is set (only `PostGuard`-armed actions set
      it — `set_config(..., true)`, auto-cleared at tx end), so a raw-SQL
      posted row is structurally impossible while the reversal factory stays a
      real posting; UPDATE/DELETE of a non-draft row is refused unless the same
      marker is present (the ONLY sanctioned non-draft rewrite is `:void`'s
      status flip — and the VoidGuard's in-tx back-link — both marker-armed).
    * `sjl_journal_line_append_only_tg` — the append-only line belt: UPDATE is
      refused outright; DELETE is permitted only while the line's ENTRY is a
      draft (the draft-replacement path in `Samen.Scopes.Finance.EntryLines`);
      INSERT is refused unless the line's entry is a draft OR the
      `samen.finance_posting` marker is set (a posted entry's line set is
      frozen — the ONLY sanctioned insert into one is the reversal cascade).

  Catalog rows are written by `catalog_sync/1` in the SAME transaction (ADR-004).
  """
  use Samen.Migration

  @resources [
    SamenCore.Support.FinanceFixture.Account,
    SamenCore.Support.FinanceFixture.JournalEntry,
    SamenCore.Support.FinanceFixture.JournalLine,
    # WS-ERP E8: the budget plan (per-account, per-period planned amounts).
    SamenCore.Support.FinanceFixture.Budget,
    SamenCore.Support.FinanceFixture.BudgetLine
  ]

  def up do
    create table(:sac_account, primary_key: false) do
      add(:sac_code, :text, null: false)
      add(:sac_name, :text, null: false)
      add(:sac_kind, :text, null: false)
      add(:sac_normal_side, :text, null: false)
      add(:sac_currency, :text, null: false, default: "USD")
      add(:sac_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:sac_org_id, :uuid, null: false)
      add(:sac_inserted_at, :utc_datetime, null: false)
      add(:sac_updated_at, :utc_datetime, null: false)
      add(:sac_archived_at, :utc_datetime_usec)

      add(
        :sac_parent_id,
        references(:sac_account, column: :sac_id, name: "sac_account_sac_parent_id_fkey", type: :uuid)
      )
    end

    create(index(:sac_account, [:sac_org_id]))
    create(index(:sac_account, [:sac_parent_id]))
    create(index(:sac_account, [:sac_org_id, :sac_code], unique: true))

    create table(:sje_journal_entry, primary_key: false) do
      add(:sje_entry_date, :date, null: false)
      add(:sje_memo, :text)
      add(:sje_status, :text, null: false, default: "draft")
      add(:sje_source_key, :text)
      add(:sje_source_id, :uuid)
      add(:sje_posted_at, :utc_datetime)
      add(:sje_voided_entry_id, :uuid)
      add(:sje_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:sje_org_id, :uuid, null: false)
      add(:sje_inserted_at, :utc_datetime, null: false)
      add(:sje_updated_at, :utc_datetime, null: false)
      add(:sje_archived_at, :utc_datetime_usec)
    end

    create(index(:sje_journal_entry, [:sje_org_id]))
    create(index(:sje_journal_entry, [:sje_source_key, :sje_source_id]))

    create(
      constraint(:sje_journal_entry, :sje_status_valid,
        check: "sje_status IN ('draft', 'posted', 'void')"
      )
    )

    create table(:sjl_journal_line, primary_key: false) do
      add(:sjl_debit_cents, :bigint, null: false, default: 0)
      add(:sjl_credit_cents, :bigint, null: false, default: 0)
      add(:sjl_memo, :text)
      add(:sjl_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:sjl_org_id, :uuid, null: false)
      add(:sjl_inserted_at, :utc_datetime, null: false)
      add(:sjl_updated_at, :utc_datetime, null: false)

      add(
        :sjl_entry_id,
        references(:sje_journal_entry,
          column: :sje_id,
          name: "sjl_journal_line_sjl_entry_id_fkey",
          type: :uuid
        )
      )

      add(
        :sjl_account_id,
        references(:sac_account,
          column: :sac_id,
          name: "sjl_journal_line_sjl_account_id_fkey",
          type: :uuid
        )
      )
    end

    create(index(:sjl_journal_line, [:sjl_org_id]))
    create(index(:sjl_journal_line, [:sjl_entry_id]))
    create(index(:sjl_journal_line, [:sjl_account_id]))

    create(
      constraint(:sjl_journal_line, :sjl_amounts_positive,
        check: "sjl_debit_cents >= 0 AND sjl_credit_cents >= 0"
      )
    )

    # -----------------------------------------------------------------------
    # Belt 1: posted-entry immutability (UPDATE/DELETE refused; non-draft
    # INSERT refused without the PostGuard transaction-local marker).
    # -----------------------------------------------------------------------
    execute """
    CREATE OR REPLACE FUNCTION sje_journal_entry_enforce_posted_immutability()
    RETURNS TRIGGER LANGUAGE plpgsql AS $$
    DECLARE
      armed boolean;
    BEGIN
      -- COALESCE: an unset GUC returns NULL (missing_ok), and NULL = 'on' is
      -- NULL — without the coalesce, NOT armed is NULL and the IF never fires
      -- (the belt would refuse NOTHING; the red-paths prove it must).
      armed := COALESCE(current_setting('samen.finance_posting', true), 'off') = 'on';

      IF TG_OP = 'INSERT' THEN
        IF NEW.sje_status IS NOT NULL AND NEW.sje_status <> 'draft' AND NOT armed THEN
          RAISE EXCEPTION 'sje_journal_entry: a non-draft INSERT requires the PostGuard '
            'transaction-local marker (samen.finance_posting) — refused. status: %',
            NEW.sje_status;
        END IF;
      END IF;

      IF TG_OP = 'DELETE' THEN
        IF OLD.sje_status <> 'draft' AND NOT armed THEN
          RAISE EXCEPTION 'sje_journal_entry is append-only once posted: DELETE of a '
            'non-draft entry is not permitted (void instead). Entry id: %, status: %',
            COALESCE(OLD.sje_id::text, '?'), COALESCE(OLD.sje_status, '?');
        END IF;
      END IF;

      IF TG_OP = 'UPDATE' THEN
        -- Keyed on BOTH sides: the draft->posted TRANSITION carries the new
        -- state in NEW, so a raw-SQL two-step (insert a draft + UPDATE it to
        -- posted) cannot forge a posted entry without the marker — the
        -- PostGuard-armed actions are the ONLY route to a non-draft state.
        IF (OLD.sje_status <> 'draft' OR NEW.sje_status <> 'draft') AND NOT armed THEN
          RAISE EXCEPTION 'sje_journal_entry is append-only once posted: UPDATE of a '
            'non-draft entry, or a transition onto one, is not permitted without the '
            'PostGuard transaction-local marker (samen.finance_posting). Entry id: %, '
            'old status: %, new status: %',
            COALESCE(OLD.sje_id::text, '?'), COALESCE(OLD.sje_status, '?'),
            COALESCE(NEW.sje_status, '?');
        END IF;
      END IF;

      RETURN COALESCE(NEW, OLD);
    END;
    $$
    """, "DROP FUNCTION IF EXISTS sje_journal_entry_enforce_posted_immutability()"

    execute """
    CREATE TRIGGER sje_journal_entry_posted_immutable_tg
    BEFORE INSERT OR UPDATE OR DELETE ON sje_journal_entry
    FOR EACH ROW EXECUTE FUNCTION sje_journal_entry_enforce_posted_immutability()
    """, "DROP TRIGGER IF EXISTS sje_journal_entry_posted_immutable_tg ON sje_journal_entry"

    # -----------------------------------------------------------------------
    # Belt 2: the line table is append-only, except a DELETE whose every
    # affected row's ENTRY is still a draft (the draft-replacement path).
    # -----------------------------------------------------------------------
    execute """
    CREATE OR REPLACE FUNCTION sjl_journal_line_enforce_append_only()
    RETURNS TRIGGER LANGUAGE plpgsql AS $$
    DECLARE
      armed boolean;
      entry_status text;
      draft_entries integer;
    BEGIN
      -- COALESCE: same unset-GUC NULL-trap as the entry trigger above.
      armed := COALESCE(current_setting('samen.finance_posting', true), 'off') = 'on';

      IF TG_OP = 'UPDATE' THEN
        RAISE EXCEPTION 'sjl_journal_line is append-only: UPDATE is not permitted. '
          'Line id: %', COALESCE(OLD.sjl_id::text, '?');
      END IF;

      IF TG_OP = 'DELETE' THEN
        SELECT count(*) INTO draft_entries FROM sje_journal_entry e
        WHERE e.sje_id = OLD.sjl_entry_id AND e.sje_status = 'draft';

        IF draft_entries = 0 THEN
          RAISE EXCEPTION 'sjl_journal_line is append-only: DELETE is permitted only '
            'while the line''s entry is a draft. Line id: %',
            COALESCE(OLD.sjl_id::text, '?');
        END IF;
      END IF;

      IF TG_OP = 'INSERT' THEN
        SELECT e.sje_status INTO entry_status FROM sje_journal_entry e
        WHERE e.sje_id = NEW.sjl_entry_id;

        IF entry_status IS DISTINCT FROM 'draft' AND NOT armed THEN
          RAISE EXCEPTION 'sjl_journal_line: INSERT into a non-draft entry requires the '
            'PostGuard transaction-local marker (samen.finance_posting) — a posted '
            'entry''s line set is frozen. Entry id: %, status: %',
            COALESCE(NEW.sjl_entry_id::text, '?'), COALESCE(entry_status, '?');
        END IF;
      END IF;

      RETURN COALESCE(NEW, OLD);
    END;
    $$
    """, "DROP FUNCTION IF EXISTS sjl_journal_line_enforce_append_only()"

    execute """
    CREATE TRIGGER sjl_journal_line_append_only_tg
    BEFORE INSERT OR UPDATE OR DELETE ON sjl_journal_line
    FOR EACH ROW EXECUTE FUNCTION sjl_journal_line_enforce_append_only()
    """, "DROP TRIGGER IF EXISTS sjl_journal_line_append_only_tg ON sjl_journal_line"

    # ── Budget — the plan header (WS-ERP E8; design §2.1) ──────────────────
    create table(:sbg_budget, primary_key: false) do
      add(:sbg_name, :text, null: false)
      add(:sbg_period, :integer, null: false)
      add(:sbg_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:sbg_org_id, :uuid, null: false)
      add(:sbg_inserted_at, :utc_datetime, null: false)
      add(:sbg_updated_at, :utc_datetime, null: false)
      add(:sbg_archived_at, :utc_datetime_usec)
    end

    create(index(:sbg_budget, [:sbg_org_id]))
    create(index(:sbg_budget, [:sbg_org_id, :sbg_name, :sbg_period], unique: true))

    execute """
    ALTER TABLE sbg_budget
      ADD CONSTRAINT sbg_period_valid CHECK (sbg_period BETWEEN 2000 AND 2999)
    """,
    "ALTER TABLE sbg_budget DROP CONSTRAINT sbg_period_valid"

    # ── BudgetLine — one account's planned amount ──────────────────────────
    create table(:sbj_budget_line, primary_key: false) do
      add(:sbj_planned_cents, :bigint, null: false)
      add(:sbj_memo, :text)
      add(:sbj_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:sbj_org_id, :uuid, null: false)
      add(:sbj_inserted_at, :utc_datetime, null: false)
      add(:sbj_updated_at, :utc_datetime, null: false)

      add(
        :sbj_budget_id,
        references(:sbg_budget,
          column: :sbg_id,
          name: "sbj_budget_line_sbj_budget_id_fkey",
          type: :uuid
        )
      )

      add(
        :sbj_account_id,
        references(:sac_account,
          column: :sac_id,
          name: "sbj_budget_line_sbj_account_id_fkey",
          type: :uuid
        )
      )
    end

    create(index(:sbj_budget_line, [:sbj_org_id]))
    create(index(:sbj_budget_line, [:sbj_budget_id]))
    create(index(:sbj_budget_line, [:sbj_account_id]))
    create(
      index(:sbj_budget_line, [:sbj_org_id, :sbj_budget_id, :sbj_account_id], unique: true)
    )

    execute """
    ALTER TABLE sbj_budget_line
      ADD CONSTRAINT sbj_planned_non_negative CHECK (sbj_planned_cents >= 0)
    """,
    "ALTER TABLE sbj_budget_line DROP CONSTRAINT sbj_planned_non_negative"

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    drop(table(:sbj_budget_line))
    execute "ALTER TABLE sbj_budget_line DROP CONSTRAINT IF EXISTS sbj_planned_non_negative"
    drop(table(:sbg_budget))
    execute "ALTER TABLE sbg_budget DROP CONSTRAINT IF EXISTS sbg_period_valid"
    execute "DROP TRIGGER IF EXISTS sjl_journal_line_append_only_tg ON sjl_journal_line"
    execute "DROP FUNCTION IF EXISTS sjl_journal_line_enforce_append_only()"
    execute "DROP TRIGGER IF EXISTS sje_journal_entry_posted_immutable_tg ON sje_journal_entry"
    execute "DROP FUNCTION IF EXISTS sje_journal_entry_enforce_posted_immutability()"
    drop(table(:sjl_journal_line))
    drop(table(:sje_journal_entry))
    drop(table(:sac_account))
  end
end
