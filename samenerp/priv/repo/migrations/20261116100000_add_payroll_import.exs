defmodule Samenerp.Repo.Migrations.AddPayrollImport do
  @moduledoc """
  Durable payroll-register provenance on the Kubeworkz host: one row per
  normalized GL line set, linked to the host's draft `ecj_journal_entry`.

  The row holds only bounded GL-line facts — provider identity, line-set hash,
  total, entry date, import timestamp/importer and status. It deliberately has
  no pay, tax, hours, rate or employee columns.
  """

  use Samen.Migration

  @resources [Samenerp.Erp.PayrollImport]

  def up do
    create table(:esp_payroll_import, primary_key: false) do
      add(:esp_provider, :text, null: false)
      add(:esp_external_id, :text, null: false)
      add(:esp_line_set_hash, :text, null: false)
      add(:esp_total_cents, :bigint, null: false)
      add(:esp_entry_date, :date, null: false)
      add(:esp_imported_at, :utc_datetime, null: false)
      add(:esp_imported_by, :text)
      add(:esp_status, :text, null: false, default: "imported")
      add(:esp_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:esp_org_id, :uuid, null: false)
      add(:esp_inserted_at, :utc_datetime, null: false)
      add(:esp_updated_at, :utc_datetime, null: false)

      add(
        :esp_entry_id,
        references(:ecj_journal_entry,
          column: :ecj_id,
          name: "esp_payroll_import_esp_entry_id_fkey",
          type: :uuid
        ),
        null: false
      )
    end

    create(index(:esp_payroll_import, [:esp_org_id]))
    create(index(:esp_payroll_import, [:esp_entry_id]))

    create(
      unique_index(
        :esp_payroll_import,
        [
          :esp_org_id,
          :esp_provider,
          :esp_external_id,
          :esp_line_set_hash,
          :esp_entry_date
        ],
        name: :esp_payroll_import_unique
      )
    )

    create(
      constraint(:esp_payroll_import, :esp_status_valid,
        check: "esp_status IN ('imported','conflict')"
      )
    )

    create(constraint(:esp_payroll_import, :esp_total_positive, check: "esp_total_cents > 0"))

    create(
      constraint(:esp_payroll_import, :esp_hash_shape, check: "length(esp_line_set_hash) = 64")
    )

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    execute("ALTER TABLE esp_payroll_import DROP CONSTRAINT IF EXISTS esp_hash_shape")
    execute("ALTER TABLE esp_payroll_import DROP CONSTRAINT IF EXISTS esp_total_positive")
    execute("ALTER TABLE esp_payroll_import DROP CONSTRAINT IF EXISTS esp_status_valid")
    drop(table(:esp_payroll_import))
  end
end
