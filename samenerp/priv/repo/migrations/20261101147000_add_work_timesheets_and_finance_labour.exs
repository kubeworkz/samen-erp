defmodule Samenerp.Repo.Migrations.AddWorkTimesheetsAndFinanceLabour do
  @moduledoc """
  WS-ACCT Unit 10.2 (ADR-054 D17) — timesheet capture and payroll allocation on
  the `samenerp` host: Work timesheet `tws`, entry `aaa`, Finance allocation
  `sel`, share `sle`. See
  `samen_core/priv/test_repo/migrations/20261101170000_add_work_timesheets_and_finance_labour.exs`
  for the full table/belt rationale; the shapes are identical across hosts
  (this host's cost objects are `eco_cost_object`, accounts `eca_account`,
  entries `ecj_journal_entry`).
  """

  use Samen.Migration

  @resources [
    Samenerp.Work.Timesheet,
    Samenerp.Work.TimesheetEntry,
    Samenerp.Erp.LabourAllocation,
    Samenerp.Erp.LabourAllocationShare
  ]

  def up do
    create table(:tws_timesheet, primary_key: false) do
      add(:tws_employee_id, :uuid, null: false)
      add(:tws_period_start, :date, null: false)
      add(:tws_period_end, :date, null: false)
      add(:tws_status, :text, null: false, default: "draft")
      add(:tws_submitted_at, :utc_datetime)
      add(:tws_approved_at, :utc_datetime)

      add(:tws_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:tws_org_id, :uuid, null: false)
      add(:tws_inserted_at, :utc_datetime, null: false)
      add(:tws_updated_at, :utc_datetime, null: false)
    end

    create(index(:tws_timesheet, [:tws_org_id]))
    create(index(:tws_timesheet, [:tws_employee_id]))
    create(index(:tws_timesheet, [:tws_period_start, :tws_period_end]))

    create(
      unique_index(
        :tws_timesheet,
        [:tws_org_id, :tws_employee_id, :tws_period_start],
        name: :tws_period_unique
      )
    )

    create(
      constraint(:tws_timesheet, :tws_period_valid,
        check: "tws_period_end >= tws_period_start"
      )
    )

    create(
      constraint(:tws_timesheet, :tws_status_valid,
        check: "tws_status IN ('draft','submitted','approved')"
      )
    )

    create(
      constraint(:tws_timesheet, :tws_submitted_complete,
        check: """
        ((tws_status = 'draft' AND tws_submitted_at IS NULL AND tws_approved_at IS NULL) OR
         (tws_status = 'submitted' AND tws_submitted_at IS NOT NULL AND tws_approved_at IS NULL) OR
         (tws_status = 'approved' AND tws_submitted_at IS NOT NULL AND tws_approved_at IS NOT NULL))
        """
      )
    )

    execute(
      """
      CREATE FUNCTION tws_transition_guard() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        IF OLD.tws_status = 'approved' THEN
          RAISE EXCEPTION 'tws_timesheet: % is refused — an approved timesheet is final; a correction is a new capture, never a rewrite. Id: %', TG_OP, OLD.tws_id;
        END IF;

        IF NOT (
          (OLD.tws_status = 'draft' AND NEW.tws_status = 'submitted') OR
          (OLD.tws_status = 'submitted' AND NEW.tws_status = 'approved')
        ) THEN
          RAISE EXCEPTION 'tws_timesheet: transition % -> % is refused — the lifecycle is draft -> submitted -> approved. Id: %', OLD.tws_status, NEW.tws_status, OLD.tws_id;
        END IF;

        IF NEW.tws_employee_id IS DISTINCT FROM OLD.tws_employee_id OR
           NEW.tws_period_start IS DISTINCT FROM OLD.tws_period_start OR
           NEW.tws_period_end IS DISTINCT FROM OLD.tws_period_end OR
           NEW.tws_org_id IS DISTINCT FROM OLD.tws_org_id THEN
          RAISE EXCEPTION 'tws_timesheet: identity columns are immutable. Id: %', OLD.tws_id;
        END IF;

        RETURN NEW;
      END;
      $$;
      """,
      "DROP FUNCTION IF EXISTS tws_transition_guard()"
    )

    execute(
      """
      CREATE TRIGGER tws_transition_guard_tg
      BEFORE UPDATE ON tws_timesheet
      FOR EACH ROW EXECUTE FUNCTION tws_transition_guard()
      """,
      "DROP TRIGGER IF EXISTS tws_transition_guard_tg ON tws_timesheet"
    )

    create table(:aaa_timesheet_entry, primary_key: false) do
      add(:aaa_worked_on, :date, null: false)
      add(:aaa_minutes, :integer, null: false)
      add(:aaa_note, :text)

      add(
        :aaa_timesheet_id,
        references(:tws_timesheet,
          column: :tws_id,
          name: "aaa_entry_aaa_timesheet_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(
        :aaa_cost_object_id,
        references(:eco_cost_object,
          column: :eco_id,
          name: "aaa_entry_aaa_cost_object_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(:aaa_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:aaa_org_id, :uuid, null: false)
      add(:aaa_inserted_at, :utc_datetime, null: false)
      add(:aaa_updated_at, :utc_datetime, null: false)
    end

    create(index(:aaa_timesheet_entry, [:aaa_org_id]))
    create(index(:aaa_timesheet_entry, [:aaa_timesheet_id]))
    create(index(:aaa_timesheet_entry, [:aaa_cost_object_id]))
    create(index(:aaa_timesheet_entry, [:aaa_worked_on]))

    create(
      constraint(:aaa_timesheet_entry, :aaa_minutes_positive, check: "aaa_minutes > 0")
    )

    execute(
      """
      CREATE FUNCTION aaa_parent_draft() RETURNS trigger
      LANGUAGE plpgsql AS $$
      DECLARE
        parent_status text;
        parent_start date;
        parent_end date;
        parent_id uuid;
        day date;
      BEGIN
        parent_id := COALESCE(NEW.aaa_timesheet_id, OLD.aaa_timesheet_id);
        day := COALESCE(NEW.aaa_worked_on, OLD.aaa_worked_on);

        SELECT tws_status, tws_period_start, tws_period_end
          INTO parent_status, parent_start, parent_end
          FROM tws_timesheet
         WHERE tws_id = parent_id;

        IF parent_status IS DISTINCT FROM 'draft' THEN
          RAISE EXCEPTION 'aaa_timesheet_entry: % is refused — entries are writable only while the timesheet is a draft (parent is %). Id: %', TG_OP, parent_status, COALESCE(OLD.aaa_id, NEW.aaa_id);
        END IF;

        IF TG_OP <> 'DELETE' AND (day < parent_start OR day > parent_end) THEN
          RAISE EXCEPTION 'aaa_timesheet_entry: worked_on % falls outside the sheet window (%..%). Id: %', day, parent_start, parent_end, COALESCE(OLD.aaa_id, NEW.aaa_id);
        END IF;

        IF TG_OP = 'DELETE' THEN
          RETURN OLD;
        ELSE
          RETURN NEW;
        END IF;
      END;
      $$;
      """,
      "DROP FUNCTION IF EXISTS aaa_parent_draft()"
    )

    execute(
      """
      CREATE TRIGGER aaa_parent_draft_tg
      BEFORE INSERT OR UPDATE OR DELETE ON aaa_timesheet_entry
      FOR EACH ROW EXECUTE FUNCTION aaa_parent_draft()
      """,
      "DROP TRIGGER IF EXISTS aaa_parent_draft_tg ON aaa_timesheet_entry"
    )

    create table(:sel_labour_allocation, primary_key: false) do
      add(:sel_period_start, :date, null: false)
      add(:sel_period_end, :date, null: false)
      add(:sel_total_cents, :bigint, null: false)
      add(:sel_axis, :text, null: false, default: "project")
      add(:sel_status, :text, null: false, default: "draft")
      add(:sel_posted_at, :utc_datetime)

      add(
        :sel_source_account_id,
        references(:eca_account,
          column: :eca_id,
          name: "sel_labour_sel_source_account_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(
        :sel_target_account_id,
        references(:eca_account,
          column: :eca_id,
          name: "sel_labour_sel_target_account_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(
        :sel_entry_id,
        references(:ecj_journal_entry,
          column: :ecj_id,
          name: "sel_labour_sel_entry_id_fkey",
          type: :uuid
        )
      )

      add(:sel_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:sel_org_id, :uuid, null: false)
      add(:sel_inserted_at, :utc_datetime, null: false)
      add(:sel_updated_at, :utc_datetime, null: false)
    end

    create(index(:sel_labour_allocation, [:sel_org_id]))
    create(index(:sel_labour_allocation, [:sel_source_account_id]))
    create(index(:sel_labour_allocation, [:sel_target_account_id]))
    create(index(:sel_labour_allocation, [:sel_entry_id]))

    create(
      unique_index(
        :sel_labour_allocation,
        [:sel_org_id, :sel_period_start, :sel_period_end, :sel_source_account_id],
        name: :sel_payroll_unique,
        where: "sel_status <> 'discarded'"
      )
    )

    create(
      constraint(:sel_labour_allocation, :sel_period_valid,
        check: "sel_period_end >= sel_period_start"
      )
    )

    create(
      constraint(:sel_labour_allocation, :sel_axis_valid,
        check: "sel_axis IN ('project','lot','fund','cost_pool')"
      )
    )

    create(
      constraint(:sel_labour_allocation, :sel_status_valid,
        check: "sel_status IN ('draft','posted','discarded')"
      )
    )

    create(
      constraint(:sel_labour_allocation, :sel_total_positive, check: "sel_total_cents > 0")
    )

    create(
      constraint(:sel_labour_allocation, :sel_posted_complete,
        check: """
        ((sel_status = 'posted' AND sel_entry_id IS NOT NULL AND sel_posted_at IS NOT NULL) OR
         (sel_status IN ('draft','discarded') AND sel_entry_id IS NULL AND sel_posted_at IS NULL))
        """
      )
    )

    create table(:sle_labour_allocation_share, primary_key: false) do
      add(:sle_minutes, :integer, null: false)
      add(:sle_allocated_cents, :bigint, null: false)

      add(
        :sle_labour_allocation_id,
        references(:sel_labour_allocation,
          column: :sel_id,
          name: "sle_share_sle_labour_allocation_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(
        :sle_cost_object_id,
        references(:eco_cost_object,
          column: :eco_id,
          name: "sle_share_sle_cost_object_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(:sle_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:sle_org_id, :uuid, null: false)
      add(:sle_inserted_at, :utc_datetime, null: false)
      add(:sle_updated_at, :utc_datetime, null: false)
    end

    create(index(:sle_labour_allocation_share, [:sle_org_id]))
    create(index(:sle_labour_allocation_share, [:sle_labour_allocation_id]))
    create(index(:sle_labour_allocation_share, [:sle_cost_object_id]))

    create(
      unique_index(
        :sle_labour_allocation_share,
        [:sle_org_id, :sle_labour_allocation_id, :sle_cost_object_id],
        name: :sle_target_unique
      )
    )

    create(
      constraint(:sle_labour_allocation_share, :sle_amount_positive,
        check: "sle_minutes > 0 AND sle_allocated_cents > 0"
      )
    )

    execute(
      """
      CREATE FUNCTION sel_allocation_posted_final() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        IF OLD.sel_status = 'posted' THEN
          RAISE EXCEPTION 'sel_labour_allocation: % is refused — a posted allocation is final; a correction is a reversing entry, never a rewrite. Id: %', TG_OP, OLD.sel_id;
        END IF;

        IF OLD.sel_status = 'discarded' THEN
          RAISE EXCEPTION 'sel_labour_allocation: % is refused — a discarded proposal is final; re-draft instead of reviving it. Id: %', TG_OP, OLD.sel_id;
        END IF;

        IF NOT (
          (OLD.sel_status = 'draft' AND NEW.sel_status = 'posted') OR
          (OLD.sel_status = 'draft' AND NEW.sel_status = 'discarded')
        ) THEN
          RAISE EXCEPTION 'sel_labour_allocation: transition % -> % is refused — the only moves are draft -> posted and draft -> discarded. Id: %', OLD.sel_status, NEW.sel_status, OLD.sel_id;
        END IF;

        RETURN NEW;
      END;
      $$;
      """,
      "DROP FUNCTION IF EXISTS sel_allocation_posted_final()"
    )

    execute(
      """
      CREATE TRIGGER sel_allocation_posted_final_tg
      BEFORE UPDATE ON sel_labour_allocation
      FOR EACH ROW EXECUTE FUNCTION sel_allocation_posted_final()
      """,
      "DROP TRIGGER IF EXISTS sel_allocation_posted_final_tg ON sel_labour_allocation"
    )

    execute(
      """
      CREATE FUNCTION sle_share_append_only() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        RAISE EXCEPTION 'sle_labour_allocation_share: % is refused — a labour allocation share is an append-only fact. Share id: %', TG_OP, OLD.sle_id;
      END;
      $$;
      """,
      "DROP FUNCTION IF EXISTS sle_share_append_only()"
    )

    execute(
      """
      CREATE TRIGGER sle_share_append_only_tg
      BEFORE UPDATE OR DELETE ON sle_labour_allocation_share
      FOR EACH ROW EXECUTE FUNCTION sle_share_append_only()
      """,
      "DROP TRIGGER IF EXISTS sle_share_append_only_tg ON sle_labour_allocation_share"
    )

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    execute("DROP TRIGGER IF EXISTS sle_share_append_only_tg ON sle_labour_allocation_share")
    execute("DROP FUNCTION IF EXISTS sle_share_append_only()")
    execute("DROP TRIGGER IF EXISTS sel_allocation_posted_final_tg ON sel_labour_allocation")
    execute("DROP FUNCTION IF EXISTS sel_allocation_posted_final()")
    execute("DROP TRIGGER IF EXISTS aaa_parent_draft_tg ON aaa_timesheet_entry")
    execute("DROP FUNCTION IF EXISTS aaa_parent_draft()")
    execute("DROP TRIGGER IF EXISTS tws_transition_guard_tg ON tws_timesheet")
    execute("DROP FUNCTION IF EXISTS tws_transition_guard()")

    drop(table(:sle_labour_allocation_share))
    drop(table(:sel_labour_allocation))
    drop(table(:aaa_timesheet_entry))
    drop(table(:tws_timesheet))
  end
end
