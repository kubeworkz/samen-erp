defmodule Samen.WebTest.Repo.Migrations.MountHrScope do
  @moduledoc """
  Tables for the HR scope (WS-ERP E7; design §5): `whe_employee` +
  `whv_employment_event` + `whl_leave_request`, mounted in `samen_web` tests
  via `test/support/hr.ex`. Mirrors `20260729100000_mount_docs_scope.exs`.

  `pii_whe_dob` is the vault-routed scalar (token column, `:text` — the
  sx*/sdd* posture); the composites keep the bare `whe_` token-column form.

  Catalog rows are written by `catalog_sync/1` in the SAME transaction (ADR-004).
  """
  use Samen.Migration

  @resources [
    Samen.WebTest.Hr.Employee,
    Samen.WebTest.Hr.EmploymentEvent,
    Samen.WebTest.Hr.LeaveRequest
  ]

  def up do
    create table(:whe_employee, primary_key: false) do
      add(:whe_employee_number, :text, null: false)
      add(:whe_hired_at, :date, null: false)
      add(:whe_terminated_at, :date)
      add(:whe_employment_type, :text, null: false, default: "full_time")
      add(:whe_manager_id, :uuid)
      add(:whe_user_id, :uuid)

      # Vault token composites (plaintext nowhere — INV-1).
      add(:whe_full_name, :map)
      add(:whe_work_emails, :map)
      add(:whe_work_phones, :map)

      # Scalar PII keeps the pii_ prefixed column; at rest it holds the token.
      add(:pii_whe_dob, :text)

      add(:whe_archived_at, :utc_datetime_usec)
      add(:whe_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:whe_org_id, :uuid, null: false)
      add(:whe_inserted_at, :utc_datetime, null: false)
      add(:whe_updated_at, :utc_datetime, null: false)
    end

    create(index(:whe_employee, [:whe_org_id]))
    create(index(:whe_employee, [:whe_org_id, :whe_employee_number], unique: true))
    create(index(:whe_employee, [:whe_manager_id]))

    create table(:whv_employment_event, primary_key: false) do
      add(:whv_kind, :text, null: false)
      add(:whv_effective_at, :utc_datetime, null: false)
      add(:whv_payload, :map, null: false, default: "{}")
      add(:whv_note, :text)
      add(:whv_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:whv_org_id, :uuid, null: false)
      add(:whv_inserted_at, :utc_datetime, null: false)
      add(:whv_updated_at, :utc_datetime, null: false)

      add(
        :whv_employee_id,
        references(:whe_employee, column: :whe_id,
          name: "whv_employment_event_whv_employee_id_fkey",
          type: :uuid
        )
      )
    end

    create(index(:whv_employment_event, [:whv_org_id]))
    create(index(:whv_employment_event, [:whv_employee_id]))

    create table(:whl_leave_request, primary_key: false) do
      add(:whl_kind, :text, null: false)
      add(:whl_start_date, :date, null: false)
      add(:whl_end_date, :date, null: false)
      add(:whl_status, :text, null: false, default: "pending")
      add(:whl_decided_at, :utc_datetime)
      add(:whl_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:whl_org_id, :uuid, null: false)
      add(:whl_inserted_at, :utc_datetime, null: false)
      add(:whl_updated_at, :utc_datetime, null: false)

      add(
        :whl_employee_id,
        references(:whe_employee, column: :whe_id,
          name: "whl_leave_request_whl_employee_id_fkey",
          type: :uuid
        )
      )
    end

    create(index(:whl_leave_request, [:whl_org_id]))
    create(index(:whl_leave_request, [:whl_employee_id]))

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)
    drop(table(:whl_leave_request))
    drop(table(:whv_employment_event))
    drop(table(:whe_employee))
  end
end
