defmodule Samenerp.Repo.Migrations.AddPayrollImportSupersedes do
  @moduledoc """
  The revision link for amended payroll registers.

  A replacement `PayrollImport` points at the prior import it supersedes. The
  original row is retained and its status becomes `:superseded`; the external
  provider id and the linked original journal entry are never rewritten. The
  posted entry itself is voided through the journal's governed reversal path,
  so posted facts remain immutable.
  """

  use Samen.Migration

  @resources [Samenerp.Erp.PayrollImport]

  def up do
    drop(constraint(:esp_payroll_import, :esp_status_valid))

    create(
      constraint(:esp_payroll_import, :esp_status_valid,
        check: "esp_status IN ('imported','conflict','superseded')"
      )
    )

    alter table(:esp_payroll_import) do
      add(
        :esp_supersedes_id,
        references(:esp_payroll_import,
          column: :esp_id,
          name: "esp_payroll_import_esp_supersedes_id_fkey",
          type: :uuid
        )
      )
    end

    create(index(:esp_payroll_import, [:esp_supersedes_id]))

    catalog_sync(@resources, only: [:supersedes_id])
  end

  def down do
    catalog_sync_down(@resources, only: [:supersedes_id])

    drop(constraint(:esp_payroll_import, :esp_status_valid))

    create(
      constraint(:esp_payroll_import, :esp_status_valid,
        check: "esp_status IN ('imported','conflict')"
      )
    )

    drop(constraint(:esp_payroll_import, "esp_payroll_import_esp_supersedes_id_fkey"))

    drop(index(:esp_payroll_import, [:esp_supersedes_id]))

    alter table(:esp_payroll_import) do
      remove(:esp_supersedes_id)
    end
  end
end
