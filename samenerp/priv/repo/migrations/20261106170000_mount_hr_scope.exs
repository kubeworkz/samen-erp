defmodule Samenerp.Repo.Migrations.MountHrScope do
  @moduledoc """
  Tables + belt for the HR scope on the Kubeworkz host (WS-ACCT Phase 16),
  the same employee/ledger/leave shape the HR scope fixture proves.

  Tables: `she_employee`, `seh_employment_event`, `shl_leave_request`
  (every column `<abbrev>_<name>`; the scalar-PII column keeps the
  `pii_<abbrev>_dob` form per the scope-authoring guide §5).

  The belt (defense in depth over the Ash guards):

    * `she_employee` — unique {org, employee_number}; the four vault-routed
      columns live as token composites (`:map`) / `pii_she_dob` (`:date`) —
      plaintext has no column to land in.
    * `seh_employment_event` — APPEND-ONLY: UPDATE/DELETE refused outright
      (the StockLedger discipline); HR current state is DERIVED (latest
      event per employee), never a stored column.
    * `shl_leave_request` — the state machine at the DB: born `pending`;
      terminal states (`approved`/`rejected`/`cancelled`) are frozen; the
      end_date >= start_date ordering is a CHECK.

  Catalog rows come from `catalog_sync/1` (the E1 helper), so
  `mix samen.verify.catalog_parity` sees the host tables fully catalogued.
  """

  use Samen.Migration

  @resources [
    Samenerp.Hr.Employee,
    Samenerp.Hr.EmploymentEvent,
    Samenerp.Hr.LeaveRequest
  ]

  def up do
    # ── Employee — the 🔒 employment record (the scope's ONLY PII carrier) ──
    create table(:she_employee, primary_key: false) do
      add(:she_employee_number, :text, null: false)
      add(:she_hired_at, :date, null: false)
      add(:she_terminated_at, :date)
      add(:she_employment_type, :text, null: false, default: "full_time")
      add(:she_manager_id, :uuid)
      add(:she_user_id, :uuid)

      # Vault tokens (plaintext nowhere — INV-1). Composite PII still lands in a
      # TEXT column holding the opaque vt_* token; jsonb would mean the column is
      # not a token carrier.
      add(:she_full_name, :text)
      add(:she_work_emails, :text)
      add(:she_work_phones, :text)

      # Scalar PII keeps the pii_ prefixed column (pii_<abbrev>_dob); at rest
      # the column holds the vault TOKEN (vt_*) — :text, per the sx*/sdd*
      # fixture precedent (the Ash attribute stays :date; the vault swap owns
      # the column bytes).
      add(:pii_she_dob, :text)

      add(:she_archived_at, :utc_datetime_usec)
      add(:she_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:she_org_id, :uuid, null: false)
      add(:she_inserted_at, :utc_datetime, null: false)
      add(:she_updated_at, :utc_datetime, null: false)
    end

    create(index(:she_employee, [:she_org_id]))
    create(index(:she_employee, [:she_org_id, :she_employee_number], unique: true))
    create(index(:she_employee, [:she_manager_id]))

    execute(
      """
      ALTER TABLE she_employee
        ADD CONSTRAINT she_employment_type_valid CHECK (she_employment_type IN
          ('full_time','part_time','contract','intern'))
      """,
      "ALTER TABLE she_employee DROP CONSTRAINT she_employment_type_valid"
    )

    # ── EmploymentEvent — the append-only employment ledger ────────────────
    create table(:seh_employment_event, primary_key: false) do
      add(:seh_kind, :text, null: false)
      add(:seh_effective_at, :utc_datetime, null: false)
      add(:seh_payload, :map, null: false, default: "{}")
      add(:seh_note, :text)
      add(:seh_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:seh_org_id, :uuid, null: false)
      add(:seh_inserted_at, :utc_datetime, null: false)
      add(:seh_updated_at, :utc_datetime, null: false)

      add(
        :seh_employee_id,
        references(:she_employee,
          column: :she_id,
          name: "seh_employment_event_seh_employee_id_fkey",
          type: :uuid
        )
      )
    end

    create(index(:seh_employment_event, [:seh_org_id]))
    create(index(:seh_employment_event, [:seh_employee_id]))
    create(index(:seh_employment_event, [:seh_employee_id, :seh_effective_at]))

    execute(
      """
      ALTER TABLE seh_employment_event
        ADD CONSTRAINT seh_kind_valid CHECK (seh_kind IN
          ('hired','comp_changed','promoted','transferred','on_leave','returned','terminated'))
      """,
      "ALTER TABLE seh_employment_event DROP CONSTRAINT seh_kind_valid"
    )

    # Append-only: employment facts are facts (the StockLedger discipline) —
    # UPDATE/DELETE refused outright; "current state" is derived by reading.
    execute(
      """
      CREATE FUNCTION seh_employment_event_enforce_append_only() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        RAISE EXCEPTION 'seh_employment_event: % is refused — the employment ledger is '
          'append-only (current state is derived from events; row: %)',
          TG_OP, COALESCE(OLD.seh_id::text, NEW.seh_id::text, 'n/a');
      END;
      $$
      """,
      "DROP FUNCTION IF EXISTS seh_employment_event_enforce_append_only()"
    )

    execute(
      """
      CREATE TRIGGER seh_employment_event_append_only_tg
      BEFORE UPDATE OR DELETE ON seh_employment_event
      FOR EACH ROW EXECUTE FUNCTION seh_employment_event_enforce_append_only()
      """,
      "DROP TRIGGER IF EXISTS seh_employment_event_append_only_tg ON seh_employment_event"
    )

    # ── LeaveRequest — the ADR-040 gated time-off document ─────────────────
    create table(:shl_leave_request, primary_key: false) do
      add(:shl_kind, :text, null: false)
      add(:shl_start_date, :date, null: false)
      add(:shl_end_date, :date, null: false)
      add(:shl_status, :text, null: false, default: "pending")
      add(:shl_decided_at, :utc_datetime)
      add(:shl_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:shl_org_id, :uuid, null: false)
      add(:shl_inserted_at, :utc_datetime, null: false)
      add(:shl_updated_at, :utc_datetime, null: false)

      add(
        :shl_employee_id,
        references(:she_employee,
          column: :she_id,
          name: "shl_leave_request_shl_employee_id_fkey",
          type: :uuid
        )
      )
    end

    create(index(:shl_leave_request, [:shl_org_id]))

    create(
      index(:shl_leave_request, [:shl_org_id, :shl_employee_id, :shl_start_date], unique: true)
    )

    create(index(:shl_leave_request, [:shl_employee_id]))

    execute(
      """
      ALTER TABLE shl_leave_request
        ADD CONSTRAINT shl_kind_valid CHECK (shl_kind IN ('vacation','sick','unpaid','other'))
      """,
      "ALTER TABLE shl_leave_request DROP CONSTRAINT shl_kind_valid"
    )

    execute(
      """
      ALTER TABLE shl_leave_request
        ADD CONSTRAINT shl_status_valid CHECK (shl_status IN
          ('pending','approved','rejected','cancelled'))
      """,
      "ALTER TABLE shl_leave_request DROP CONSTRAINT shl_status_valid"
    )

    execute(
      """
      ALTER TABLE shl_leave_request
        ADD CONSTRAINT shl_date_order CHECK (shl_end_date >= shl_start_date)
      """,
      "ALTER TABLE shl_leave_request DROP CONSTRAINT shl_date_order"
    )

    # The leave state machine at the DB (LeaveState's raw-SQL twin): born a
    # pending; a terminal state (approved/rejected/cancelled) is frozen — the
    # governance lives at the ADR-040 approvals layer, the DB owns only the
    # transition legality.
    execute(
      """
      CREATE FUNCTION shl_leave_request_enforce_state() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF TG_OP = 'INSERT' THEN
          IF NEW.shl_status IS DISTINCT FROM 'pending' THEN
            RAISE EXCEPTION 'shl_leave_request: a leave request is born pending (got %) '
              '(request: %)',
              NEW.shl_status, NEW.shl_id;
          END IF;

          RETURN NEW;
        END IF;

        IF NEW.shl_status = OLD.shl_status THEN
          RETURN NEW;
        END IF;

        IF OLD.shl_status = 'pending' AND
           NEW.shl_status IN ('approved', 'rejected', 'cancelled') THEN
          RETURN NEW;
        END IF;

        RAISE EXCEPTION 'shl_leave_request: illegal % → % transition — a decided request '
          'is a fact (request: %)',
          OLD.shl_status, NEW.shl_status, OLD.shl_id;
      END;
      $$
      """,
      "DROP FUNCTION IF EXISTS shl_leave_request_enforce_state()"
    )

    execute(
      """
      CREATE TRIGGER shl_leave_request_enforce_state_tg
      BEFORE INSERT OR UPDATE ON shl_leave_request
      FOR EACH ROW EXECUTE FUNCTION shl_leave_request_enforce_state()
      """,
      "DROP TRIGGER IF EXISTS shl_leave_request_enforce_state_tg ON shl_leave_request"
    )

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    execute("DROP TRIGGER IF EXISTS shl_leave_request_enforce_state_tg ON shl_leave_request")
    execute("DROP FUNCTION IF EXISTS shl_leave_request_enforce_state()")
    drop(table(:shl_leave_request))
    execute("DROP TRIGGER IF EXISTS seh_employment_event_append_only_tg ON seh_employment_event")
    execute("DROP FUNCTION IF EXISTS seh_employment_event_enforce_append_only()")
    drop(table(:seh_employment_event))
    drop(table(:she_employee))
  end
end
