defmodule SamenCore.TestRepo.Migrations.HrScopeFixture do
  @moduledoc """
  Tables + belt for the HR scope fixture (WS-ERP E7; design §5), mounted by
  `test/support/hr_fixture.ex` — the Finance/Inventory fixture shape.

  Tables: `hem_employee`, `hev_employment_event`, `hlv_leave_request`
  (every column `<abbrev>_<name>`; the scalar-PII column keeps the
  `pii_<abbrev>_dob` form per the scope-authoring guide §5).

  The belt (defense in depth over the Ash guards):

    * `hem_employee` — unique {org, employee_number}; the four vault-routed
      columns live as token composites (`:map`) / `pii_hem_dob` (`:date`) —
      plaintext has no column to land in.
    * `hev_employment_event` — APPEND-ONLY: UPDATE/DELETE refused outright
      (the StockLedger discipline); HR current state is DERIVED (latest
      event per employee), never a stored column.
    * `hlv_leave_request` — the state machine at the DB: born `pending`;
      terminal states (`approved`/`rejected`/`cancelled`) are frozen; the
      end_date >= start_date ordering is a CHECK.

  Catalog rows come from `catalog_sync/1` (the E1 helper), so
  `mix samen.verify.catalog_parity` sees the fixture tables fully
  catalogued.
  """

  use Samen.Migration

  @resources [
    SamenCore.Support.HrFixture.Employee,
    SamenCore.Support.HrFixture.EmploymentEvent,
    SamenCore.Support.HrFixture.LeaveRequest
  ]

  def up do
    # ── Employee — the 🔒 employment record (the scope's ONLY PII carrier) ──
    create table(:hem_employee, primary_key: false) do
      add(:hem_employee_number, :text, null: false)
      add(:hem_hired_at, :date, null: false)
      add(:hem_terminated_at, :date)
      add(:hem_employment_type, :text, null: false, default: "full_time")
      add(:hem_manager_id, :uuid)
      add(:hem_user_id, :uuid)

      # Vault token composites (plaintext nowhere — INV-1).
      add(:hem_full_name, :map)
      add(:hem_work_emails, :map)
      add(:hem_work_phones, :map)

      # Scalar PII keeps the pii_ prefixed column (pii_<abbrev>_dob); at rest
      # the column holds the vault TOKEN (vt_*) — :text, per the sx*/sdd*
      # fixture precedent (the Ash attribute stays :date; the vault swap owns
      # the column bytes).
      add(:pii_hem_dob, :text)

      add(:hem_archived_at, :utc_datetime_usec)
      add(:hem_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:hem_org_id, :uuid, null: false)
      add(:hem_inserted_at, :utc_datetime, null: false)
      add(:hem_updated_at, :utc_datetime, null: false)
    end

    create(index(:hem_employee, [:hem_org_id]))
    create(index(:hem_employee, [:hem_org_id, :hem_employee_number], unique: true))
    create(index(:hem_employee, [:hem_manager_id]))

    execute """
            ALTER TABLE hem_employee
              ADD CONSTRAINT hem_employment_type_valid CHECK (hem_employment_type IN
                ('full_time','part_time','contract','intern'))
            """,
            "ALTER TABLE hem_employee DROP CONSTRAINT hem_employment_type_valid"

    # ── EmploymentEvent — the append-only employment ledger ────────────────
    create table(:hev_employment_event, primary_key: false) do
      add(:hev_kind, :text, null: false)
      add(:hev_effective_at, :utc_datetime, null: false)
      add(:hev_payload, :map, null: false, default: "{}")
      add(:hev_note, :text)
      add(:hev_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:hev_org_id, :uuid, null: false)
      add(:hev_inserted_at, :utc_datetime, null: false)
      add(:hev_updated_at, :utc_datetime, null: false)

      add(
        :hev_employee_id,
        references(:hem_employee, column: :hem_id,
          name: "hev_employment_event_hev_employee_id_fkey",
          type: :uuid
        )
      )
    end

    create(index(:hev_employment_event, [:hev_org_id]))
    create(index(:hev_employment_event, [:hev_employee_id]))
    create(index(:hev_employment_event, [:hev_employee_id, :hev_effective_at]))

    execute """
            ALTER TABLE hev_employment_event
              ADD CONSTRAINT hev_kind_valid CHECK (hev_kind IN
                ('hired','comp_changed','promoted','transferred','on_leave','returned','terminated'))
            """,
            "ALTER TABLE hev_employment_event DROP CONSTRAINT hev_kind_valid"

    # Append-only: employment facts are facts (the StockLedger discipline) —
    # UPDATE/DELETE refused outright; "current state" is derived by reading.
    execute """
            CREATE FUNCTION hev_employment_event_enforce_append_only() RETURNS trigger LANGUAGE plpgsql AS $$
            BEGIN
              RAISE EXCEPTION 'hev_employment_event: % is refused — the employment ledger is '
                'append-only (current state is derived from events; row: %)',
                TG_OP, COALESCE(OLD.hev_id::text, NEW.hev_id::text, 'n/a');
            END;
            $$
            """,
            "DROP FUNCTION IF EXISTS hev_employment_event_enforce_append_only()"

    execute """
            CREATE TRIGGER hev_employment_event_append_only_tg
            BEFORE UPDATE OR DELETE ON hev_employment_event
            FOR EACH ROW EXECUTE FUNCTION hev_employment_event_enforce_append_only()
            """,
            "DROP TRIGGER IF EXISTS hev_employment_event_append_only_tg ON hev_employment_event"

    # ── LeaveRequest — the ADR-040 gated time-off document ─────────────────
    create table(:hlv_leave_request, primary_key: false) do
      add(:hlv_kind, :text, null: false)
      add(:hlv_start_date, :date, null: false)
      add(:hlv_end_date, :date, null: false)
      add(:hlv_status, :text, null: false, default: "pending")
      add(:hlv_decided_at, :utc_datetime)
      add(:hlv_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:hlv_org_id, :uuid, null: false)
      add(:hlv_inserted_at, :utc_datetime, null: false)
      add(:hlv_updated_at, :utc_datetime, null: false)

      add(
        :hlv_employee_id,
        references(:hem_employee, column: :hem_id,
          name: "hlv_leave_request_hlv_employee_id_fkey",
          type: :uuid
        )
      )
    end

    create(index(:hlv_leave_request, [:hlv_org_id]))
    create(index(:hlv_leave_request, [:hlv_org_id, :hlv_employee_id, :hlv_start_date], unique: true))
    create(index(:hlv_leave_request, [:hlv_employee_id]))

    execute """
            ALTER TABLE hlv_leave_request
              ADD CONSTRAINT hlv_kind_valid CHECK (hlv_kind IN ('vacation','sick','unpaid','other'))
            """,
            "ALTER TABLE hlv_leave_request DROP CONSTRAINT hlv_kind_valid"

    execute """
            ALTER TABLE hlv_leave_request
              ADD CONSTRAINT hlv_status_valid CHECK (hlv_status IN
                ('pending','approved','rejected','cancelled'))
            """,
            "ALTER TABLE hlv_leave_request DROP CONSTRAINT hlv_status_valid"

    execute """
            ALTER TABLE hlv_leave_request
              ADD CONSTRAINT hlv_date_order CHECK (hlv_end_date >= hlv_start_date)
            """,
            "ALTER TABLE hlv_leave_request DROP CONSTRAINT hlv_date_order"

    # The leave state machine at the DB (LeaveState's raw-SQL twin): born a
    # pending; a terminal state (approved/rejected/cancelled) is frozen — the
    # governance lives at the ADR-040 approvals layer, the DB owns only the
    # transition legality.
    execute """
            CREATE FUNCTION hlv_leave_request_enforce_state() RETURNS trigger LANGUAGE plpgsql AS $$
            BEGIN
              IF TG_OP = 'INSERT' THEN
                IF NEW.hlv_status IS DISTINCT FROM 'pending' THEN
                  RAISE EXCEPTION 'hlv_leave_request: a leave request is born pending (got %) '
                    '(request: %)',
                    NEW.hlv_status, NEW.hlv_id;
                END IF;

                RETURN NEW;
              END IF;

              IF NEW.hlv_status = OLD.hlv_status THEN
                RETURN NEW;
              END IF;

              IF OLD.hlv_status = 'pending' AND
                 NEW.hlv_status IN ('approved', 'rejected', 'cancelled') THEN
                RETURN NEW;
              END IF;

              RAISE EXCEPTION 'hlv_leave_request: illegal % → % transition — a decided request '
                'is a fact (request: %)',
                OLD.hlv_status, NEW.hlv_status, OLD.hlv_id;
            END;
            $$
            """,
            "DROP FUNCTION IF EXISTS hlv_leave_request_enforce_state()"

    execute """
            CREATE TRIGGER hlv_leave_request_enforce_state_tg
            BEFORE INSERT OR UPDATE ON hlv_leave_request
            FOR EACH ROW EXECUTE FUNCTION hlv_leave_request_enforce_state()
            """,
            "DROP TRIGGER IF EXISTS hlv_leave_request_enforce_state_tg ON hlv_leave_request"

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    drop(table(:hlv_leave_request))
    execute "DROP TRIGGER IF EXISTS hlv_leave_request_enforce_state_tg ON hlv_leave_request"
    execute "DROP FUNCTION IF EXISTS hlv_leave_request_enforce_state()"
    drop(table(:hev_employment_event))
    execute "DROP TRIGGER IF EXISTS hev_employment_event_append_only_tg ON hev_employment_event"
    execute "DROP FUNCTION IF EXISTS hev_employment_event_enforce_append_only()"
    drop(table(:hem_employee))
  end
end
