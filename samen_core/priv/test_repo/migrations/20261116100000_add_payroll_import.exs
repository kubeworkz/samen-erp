defmodule SamenCore.TestRepo.Migrations.AddPayrollImport do
  @moduledoc """
  Durable payroll-register provenance for the core fixture: one row per
  normalized GL line set, linked to the host's draft journal entry.

  The row holds only bounded GL-line facts — provider identity, line-set hash,
  total, entry date, import timestamp/importer and status. It deliberately has
  no pay, tax, hours, rate or employee columns.
  """

  use Samen.Migration

  @resources [SamenCore.Support.FinanceFixture.PayrollImport]

  def up do
    create table(:pfs_payroll_import, primary_key: false) do
      add(:pfs_provider, :text, null: false)
      add(:pfs_external_id, :text, null: false)
      add(:pfs_line_set_hash, :text, null: false)
      add(:pfs_total_cents, :bigint, null: false)
      add(:pfs_entry_date, :date, null: false)
      add(:pfs_imported_at, :utc_datetime, null: false)
      add(:pfs_imported_by, :text)
      add(:pfs_status, :text, null: false, default: "imported")
      add(:pfs_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:pfs_org_id, :uuid, null: false)
      add(:pfs_inserted_at, :utc_datetime, null: false)
      add(:pfs_updated_at, :utc_datetime, null: false)

      add(
        :pfs_entry_id,
        references(:sje_journal_entry,
          column: :sje_id,
          name: "pfs_payroll_import_pfs_entry_id_fkey",
          type: :uuid
        ),
        null: false
      )
    end

    create(index(:pfs_payroll_import, [:pfs_org_id]))
    create(index(:pfs_payroll_import, [:pfs_entry_id]))

    create(
      unique_index(
        :pfs_payroll_import,
        [
          :pfs_org_id,
          :pfs_provider,
          :pfs_external_id,
          :pfs_line_set_hash,
          :pfs_entry_date
        ],
        name: :pfs_payroll_import_unique
      )
    )

    create(
      constraint(:pfs_payroll_import, :pfs_status_valid,
        check: "pfs_status IN ('imported','conflict')"
      )
    )

    create(constraint(:pfs_payroll_import, :pfs_total_positive, check: "pfs_total_cents > 0"))

    create(
      constraint(:pfs_payroll_import, :pfs_hash_shape, check: "length(pfs_line_set_hash) = 64")
    )

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    execute("ALTER TABLE pfs_payroll_import DROP CONSTRAINT IF EXISTS pfs_hash_shape")
    execute("ALTER TABLE pfs_payroll_import DROP CONSTRAINT IF EXISTS pfs_total_positive")
    execute("ALTER TABLE pfs_payroll_import DROP CONSTRAINT IF EXISTS pfs_status_valid")
    drop(table(:pfs_payroll_import))
  end
end
