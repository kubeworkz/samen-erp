defmodule Samen.WebTest.Repo.Migrations.AddErpPayrollImport do
  @moduledoc """
  The Finance scope's durable payroll-import record on the `samen_web` test
  host (`Samen.WebTest.Erp.PayrollImport`, abbrev `epw`). The default Finance
  mount materializes the resource; this migration gives it a real table so the
  host's catalog and read model are complete.
  """

  use Samen.Migration

  @resources [Samen.WebTest.Erp.PayrollImport]

  def up do
    create table(:epw_payroll_import, primary_key: false) do
      add(:epw_provider, :text, null: false)
      add(:epw_external_id, :text, null: false)
      add(:epw_line_set_hash, :text, null: false)
      add(:epw_total_cents, :bigint, null: false)
      add(:epw_entry_date, :date, null: false)
      add(:epw_imported_at, :utc_datetime, null: false)
      add(:epw_imported_by, :text)
      add(:epw_status, :text, null: false, default: "imported")
      add(:epw_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:epw_org_id, :uuid, null: false)
      add(:epw_inserted_at, :utc_datetime, null: false)
      add(:epw_updated_at, :utc_datetime, null: false)

      add(
        :epw_entry_id,
        references(:fje_journal_entry,
          column: :fje_id,
          name: "epw_payroll_import_epw_entry_id_fkey",
          type: :uuid
        ),
        null: false
      )
    end

    create(index(:epw_payroll_import, [:epw_org_id]))
    create(index(:epw_payroll_import, [:epw_entry_id]))

    create(
      unique_index(
        :epw_payroll_import,
        [
          :epw_org_id,
          :epw_provider,
          :epw_external_id,
          :epw_line_set_hash,
          :epw_entry_date
        ],
        name: :epw_payroll_import_unique
      )
    )

    create(
      constraint(:epw_payroll_import, :epw_status_valid,
        check: "epw_status IN ('imported','conflict')"
      )
    )

    create(constraint(:epw_payroll_import, :epw_total_positive, check: "epw_total_cents > 0"))

    create(
      constraint(:epw_payroll_import, :epw_hash_shape, check: "length(epw_line_set_hash) = 64")
    )

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    execute("ALTER TABLE epw_payroll_import DROP CONSTRAINT IF EXISTS epw_hash_shape")
    execute("ALTER TABLE epw_payroll_import DROP CONSTRAINT IF EXISTS epw_total_positive")
    execute("ALTER TABLE epw_payroll_import DROP CONSTRAINT IF EXISTS epw_status_valid")
    drop(table(:epw_payroll_import))
  end
end
