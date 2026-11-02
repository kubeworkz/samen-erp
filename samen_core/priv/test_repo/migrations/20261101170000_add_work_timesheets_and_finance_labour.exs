defmodule SamenCore.TestRepo.Migrations.AddWorkTimesheetsAndFinanceLabour do
  @moduledoc """
  WS-ACCT Unit 10.2 (ADR-054 D17) — timesheet capture and payroll allocation
  in the `samen_core` test fixture: Work timesheet `wts`, entry `tsw`, Finance
  allocation `sfl`, share `slf`.

    * `wts_timesheet` — one employee's capture window and its one-way
      draft → submitted → approved status.
    * `tsw_timesheet_entry` — one day's minutes against one cost object
      (`cob_cost_object`), same-org at Ash and FK'd here.
    * `sfl_labour_allocation` — a payroll period's declared total on one
      expense account, split by approved minutes; final once posted.
    * `slf_labour_allocation_share` — one cost object's approved minutes and
      derived cents; append-only evidence.

  DB belts (over the Ash-side braces):

    * `wts_period_valid`, `wts_status_valid`, `wts_submitted_complete` — the
      window and the lifecycle shape;
    * `wts_period_unique` — one sheet per {org, employee, period_start};
    * `wts_transition_guard` trigger — only draft → submitted → approved is
      allowed, the identity columns are immutable, and an approved sheet can
      never be updated again;
    * `tsw_minutes_positive`;
    * `tsw_parent_draft` trigger — an entry may only be INSERTed/UPDATEd/DELETEd
      while its sheet is a draft, and its day must fall inside the sheet's
      window. This is the belt under `Work.TimesheetEntryGuard`, and it is what
      keeps an approved hour total from moving after payroll consumed it;
    * `sfl_period_valid`, `sfl_axis_valid`, `sfl_status_valid`,
      `sfl_total_positive`, `sfl_posted_complete`;
    * `sfl_payroll_unique` — one allocation per {org, period, source account};
    * `sfl_posted_final` trigger — a posted allocation is never rewritten;
    * `slf_amount_positive`, `slf_target_unique`;
    * `slf_share_append_only` trigger — the split is never rewritten.

  Catalog rows via `catalog_sync/1` in the same transaction (ADR-004).
  """

  use Samen.Migration

  @resources [
    SamenCore.Support.WorkFixture.Timesheet,
    SamenCore.Support.WorkFixture.TimesheetEntry,
    SamenCore.Support.FinanceFixture.LabourAllocation,
    SamenCore.Support.FinanceFixture.LabourAllocationShare
  ]

  def up do
    create table(:wts_timesheet, primary_key: false) do
      add(:wts_employee_id, :uuid, null: false)
      add(:wts_period_start, :date, null: false)
      add(:wts_period_end, :date, null: false)
      add(:wts_status, :text, null: false, default: "draft")
      add(:wts_submitted_at, :utc_datetime)
      add(:wts_approved_at, :utc_datetime)

      add(:wts_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:wts_org_id, :uuid, null: false)
      add(:wts_inserted_at, :utc_datetime, null: false)
      add(:wts_updated_at, :utc_datetime, null: false)
    end

    create(index(:wts_timesheet, [:wts_org_id]))
    create(index(:wts_timesheet, [:wts_employee_id]))
    create(index(:wts_timesheet, [:wts_period_start, :wts_period_end]))

    create(
      unique_index(
        :wts_timesheet,
        [:wts_org_id, :wts_employee_id, :wts_period_start],
        name: :wts_period_unique
      )
    )

    create(
      constraint(:wts_timesheet, :wts_period_valid,
        check: "wts_period_end >= wts_period_start"
      )
    )

    create(
      constraint(:wts_timesheet, :wts_status_valid,
        check: "wts_status IN ('draft','submitted','approved')"
      )
    )

    create(
      constraint(:wts_timesheet, :wts_submitted_complete,
        check: """
        ((wts_status = 'draft' AND wts_submitted_at IS NULL AND wts_approved_at IS NULL) OR
         (wts_status = 'submitted' AND wts_submitted_at IS NOT NULL AND wts_approved_at IS NULL) OR
         (wts_status = 'approved' AND wts_submitted_at IS NOT NULL AND wts_approved_at IS NOT NULL))
        """
      )
    )

    execute(
      """
      CREATE FUNCTION wts_transition_guard() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        IF OLD.wts_status = 'approved' THEN
          RAISE EXCEPTION 'wts_timesheet: % is refused — an approved timesheet is final; a correction is a new capture, never a rewrite. Id: %', TG_OP, OLD.wts_id;
        END IF;

        IF NOT (
          (OLD.wts_status = 'draft' AND NEW.wts_status = 'submitted') OR
          (OLD.wts_status = 'submitted' AND NEW.wts_status = 'approved')
        ) THEN
          RAISE EXCEPTION 'wts_timesheet: transition % -> % is refused — the lifecycle is draft -> submitted -> approved. Id: %', OLD.wts_status, NEW.wts_status, OLD.wts_id;
        END IF;

        IF NEW.wts_employee_id IS DISTINCT FROM OLD.wts_employee_id OR
           NEW.wts_period_start IS DISTINCT FROM OLD.wts_period_start OR
           NEW.wts_period_end IS DISTINCT FROM OLD.wts_period_end OR
           NEW.wts_org_id IS DISTINCT FROM OLD.wts_org_id THEN
          RAISE EXCEPTION 'wts_timesheet: identity columns are immutable. Id: %', OLD.wts_id;
        END IF;

        RETURN NEW;
      END;
      $$;
      """,
      "DROP FUNCTION IF EXISTS wts_transition_guard()"
    )

    execute(
      """
      CREATE TRIGGER wts_transition_guard_tg
      BEFORE UPDATE ON wts_timesheet
      FOR EACH ROW EXECUTE FUNCTION wts_transition_guard()
      """,
      "DROP TRIGGER IF EXISTS wts_transition_guard_tg ON wts_timesheet"
    )

    create table(:tsw_timesheet_entry, primary_key: false) do
      add(:tsw_worked_on, :date, null: false)
      add(:tsw_minutes, :integer, null: false)
      add(:tsw_note, :text)

      add(
        :tsw_timesheet_id,
        references(:wts_timesheet,
          column: :wts_id,
          name: "tsw_entry_tsw_timesheet_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(
        :tsw_cost_object_id,
        references(:cob_cost_object,
          column: :cob_id,
          name: "tsw_entry_tsw_cost_object_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(:tsw_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:tsw_org_id, :uuid, null: false)
      add(:tsw_inserted_at, :utc_datetime, null: false)
      add(:tsw_updated_at, :utc_datetime, null: false)
    end

    create(index(:tsw_timesheet_entry, [:tsw_org_id]))
    create(index(:tsw_timesheet_entry, [:tsw_timesheet_id]))
    create(index(:tsw_timesheet_entry, [:tsw_cost_object_id]))
    create(index(:tsw_timesheet_entry, [:tsw_worked_on]))

    create(
      constraint(:tsw_timesheet_entry, :tsw_minutes_positive, check: "tsw_minutes > 0")
    )

    execute(
      """
      CREATE FUNCTION tsw_parent_draft() RETURNS trigger
      LANGUAGE plpgsql AS $$
      DECLARE
        parent_status text;
        parent_start date;
        parent_end date;
        parent_id uuid;
        day date;
      BEGIN
        parent_id := COALESCE(NEW.tsw_timesheet_id, OLD.tsw_timesheet_id);
        day := COALESCE(NEW.tsw_worked_on, OLD.tsw_worked_on);

        SELECT wts_status, wts_period_start, wts_period_end
          INTO parent_status, parent_start, parent_end
          FROM wts_timesheet
         WHERE wts_id = parent_id;

        IF parent_status IS DISTINCT FROM 'draft' THEN
          RAISE EXCEPTION 'tsw_timesheet_entry: % is refused — entries are writable only while the timesheet is a draft (parent is %). Id: %', TG_OP, parent_status, COALESCE(OLD.tsw_id, NEW.tsw_id);
        END IF;

        IF TG_OP <> 'DELETE' AND (day < parent_start OR day > parent_end) THEN
          RAISE EXCEPTION 'tsw_timesheet_entry: worked_on % falls outside the sheet window (%..%). Id: %', day, parent_start, parent_end, COALESCE(OLD.tsw_id, NEW.tsw_id);
        END IF;

        IF TG_OP = 'DELETE' THEN
          RETURN OLD;
        ELSE
          RETURN NEW;
        END IF;
      END;
      $$;
      """,
      "DROP FUNCTION IF EXISTS tsw_parent_draft()"
    )

    execute(
      """
      CREATE TRIGGER tsw_parent_draft_tg
      BEFORE INSERT OR UPDATE OR DELETE ON tsw_timesheet_entry
      FOR EACH ROW EXECUTE FUNCTION tsw_parent_draft()
      """,
      "DROP TRIGGER IF EXISTS tsw_parent_draft_tg ON tsw_timesheet_entry"
    )

    create table(:sfl_labour_allocation, primary_key: false) do
      add(:sfl_period_start, :date, null: false)
      add(:sfl_period_end, :date, null: false)
      add(:sfl_total_cents, :bigint, null: false)
      add(:sfl_axis, :text, null: false, default: "project")
      add(:sfl_status, :text, null: false, default: "draft")
      add(:sfl_posted_at, :utc_datetime)

      add(
        :sfl_source_account_id,
        references(:sac_account,
          column: :sac_id,
          name: "sfl_labour_sfl_source_account_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(
        :sfl_target_account_id,
        references(:sac_account,
          column: :sac_id,
          name: "sfl_labour_sfl_target_account_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(
        :sfl_entry_id,
        references(:sje_journal_entry,
          column: :sje_id,
          name: "sfl_labour_sfl_entry_id_fkey",
          type: :uuid
        )
      )

      add(:sfl_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:sfl_org_id, :uuid, null: false)
      add(:sfl_inserted_at, :utc_datetime, null: false)
      add(:sfl_updated_at, :utc_datetime, null: false)
    end

    create(index(:sfl_labour_allocation, [:sfl_org_id]))
    create(index(:sfl_labour_allocation, [:sfl_source_account_id]))
    create(index(:sfl_labour_allocation, [:sfl_target_account_id]))
    create(index(:sfl_labour_allocation, [:sfl_entry_id]))

    create(
      unique_index(
        :sfl_labour_allocation,
        [:sfl_org_id, :sfl_period_start, :sfl_period_end, :sfl_source_account_id],
        name: :sfl_payroll_unique,
        where: "sfl_status <> 'discarded'"
      )
    )

    create(
      constraint(:sfl_labour_allocation, :sfl_period_valid,
        check: "sfl_period_end >= sfl_period_start"
      )
    )

    create(
      constraint(:sfl_labour_allocation, :sfl_axis_valid,
        check: "sfl_axis IN ('project','lot','fund','cost_pool')"
      )
    )

    create(
      constraint(:sfl_labour_allocation, :sfl_status_valid,
        check: "sfl_status IN ('draft','posted','discarded')"
      )
    )

    create(
      constraint(:sfl_labour_allocation, :sfl_total_positive, check: "sfl_total_cents > 0")
    )

    create(
      constraint(:sfl_labour_allocation, :sfl_posted_complete,
        check: """
        ((sfl_status = 'posted' AND sfl_entry_id IS NOT NULL AND sfl_posted_at IS NOT NULL) OR
         (sfl_status IN ('draft','discarded') AND sfl_entry_id IS NULL AND sfl_posted_at IS NULL))
        """
      )
    )

    create table(:slf_labour_allocation_share, primary_key: false) do
      add(:slf_minutes, :integer, null: false)
      add(:slf_allocated_cents, :bigint, null: false)

      add(
        :slf_labour_allocation_id,
        references(:sfl_labour_allocation,
          column: :sfl_id,
          name: "slf_share_slf_labour_allocation_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(
        :slf_cost_object_id,
        references(:cob_cost_object,
          column: :cob_id,
          name: "slf_share_slf_cost_object_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(:slf_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:slf_org_id, :uuid, null: false)
      add(:slf_inserted_at, :utc_datetime, null: false)
      add(:slf_updated_at, :utc_datetime, null: false)
    end

    create(index(:slf_labour_allocation_share, [:slf_org_id]))
    create(index(:slf_labour_allocation_share, [:slf_labour_allocation_id]))
    create(index(:slf_labour_allocation_share, [:slf_cost_object_id]))

    create(
      unique_index(
        :slf_labour_allocation_share,
        [:slf_org_id, :slf_labour_allocation_id, :slf_cost_object_id],
        name: :slf_target_unique
      )
    )

    create(
      constraint(:slf_labour_allocation_share, :slf_amount_positive,
        check: "slf_minutes > 0 AND slf_allocated_cents > 0"
      )
    )

    execute(
      """
      CREATE FUNCTION sfl_allocation_posted_final() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        IF OLD.sfl_status = 'posted' THEN
          RAISE EXCEPTION 'sfl_labour_allocation: % is refused — a posted allocation is final; a correction is a reversing entry, never a rewrite. Id: %', TG_OP, OLD.sfl_id;
        END IF;

        IF OLD.sfl_status = 'discarded' THEN
          RAISE EXCEPTION 'sfl_labour_allocation: % is refused — a discarded proposal is final; re-draft instead of reviving it. Id: %', TG_OP, OLD.sfl_id;
        END IF;

        IF NOT (
          (OLD.sfl_status = 'draft' AND NEW.sfl_status = 'posted') OR
          (OLD.sfl_status = 'draft' AND NEW.sfl_status = 'discarded')
        ) THEN
          RAISE EXCEPTION 'sfl_labour_allocation: transition % -> % is refused — the only moves are draft -> posted and draft -> discarded. Id: %', OLD.sfl_status, NEW.sfl_status, OLD.sfl_id;
        END IF;

        RETURN NEW;
      END;
      $$;
      """,
      "DROP FUNCTION IF EXISTS sfl_allocation_posted_final()"
    )

    execute(
      """
      CREATE TRIGGER sfl_allocation_posted_final_tg
      BEFORE UPDATE ON sfl_labour_allocation
      FOR EACH ROW EXECUTE FUNCTION sfl_allocation_posted_final()
      """,
      "DROP TRIGGER IF EXISTS sfl_allocation_posted_final_tg ON sfl_labour_allocation"
    )

    execute(
      """
      CREATE FUNCTION slf_share_append_only() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        RAISE EXCEPTION 'slf_labour_allocation_share: % is refused — a labour allocation share is an append-only fact. Share id: %', TG_OP, OLD.slf_id;
      END;
      $$;
      """,
      "DROP FUNCTION IF EXISTS slf_share_append_only()"
    )

    execute(
      """
      CREATE TRIGGER slf_share_append_only_tg
      BEFORE UPDATE OR DELETE ON slf_labour_allocation_share
      FOR EACH ROW EXECUTE FUNCTION slf_share_append_only()
      """,
      "DROP TRIGGER IF EXISTS slf_share_append_only_tg ON slf_labour_allocation_share"
    )

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    execute("DROP TRIGGER IF EXISTS slf_share_append_only_tg ON slf_labour_allocation_share")
    execute("DROP FUNCTION IF EXISTS slf_share_append_only()")
    execute("DROP TRIGGER IF EXISTS sfl_allocation_posted_final_tg ON sfl_labour_allocation")
    execute("DROP FUNCTION IF EXISTS sfl_allocation_posted_final()")
    execute("DROP TRIGGER IF EXISTS tsw_parent_draft_tg ON tsw_timesheet_entry")
    execute("DROP FUNCTION IF EXISTS tsw_parent_draft()")
    execute("DROP TRIGGER IF EXISTS wts_transition_guard_tg ON wts_timesheet")
    execute("DROP FUNCTION IF EXISTS wts_transition_guard()")

    drop(table(:slf_labour_allocation_share))
    drop(table(:sfl_labour_allocation))
    drop(table(:tsw_timesheet_entry))
    drop(table(:wts_timesheet))
  end
end
