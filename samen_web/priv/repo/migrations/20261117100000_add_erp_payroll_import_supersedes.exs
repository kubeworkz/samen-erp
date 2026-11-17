defmodule Samen.WebTest.Repo.Migrations.AddErpPayrollImportSupersedes do
  @moduledoc """
  The revision link for amended payroll registers on the `samen_web` test host.

  A replacement `PayrollImport` points at the prior import it supersedes. The
  original row is retained and its status becomes `:superseded`; the external
  provider id and the linked original journal entry are never rewritten. The
  posted entry itself is voided through the journal's governed reversal path,
  so posted facts remain immutable.
  """

  use Samen.Migration

  @resources [Samen.WebTest.Erp.PayrollImport]

  def up do
    drop(constraint(:epw_payroll_import, :epw_status_valid))

    create(
      constraint(:epw_payroll_import, :epw_status_valid,
        check: "epw_status IN ('imported','conflict','superseded')"
      )
    )

    alter table(:epw_payroll_import) do
      add(
        :epw_supersedes_id,
        references(:epw_payroll_import,
          column: :epw_id,
          name: "epw_payroll_import_epw_supersedes_id_fkey",
          type: :uuid
        )
      )
    end

    create(index(:epw_payroll_import, [:epw_supersedes_id]))

    catalog_sync(@resources, only: [:supersedes_id])
  end

  def down do
    catalog_sync_down(@resources, only: [:supersedes_id])

    drop(constraint(:epw_payroll_import, :epw_status_valid))

    create(
      constraint(:epw_payroll_import, :epw_status_valid,
        check: "epw_status IN ('imported','conflict')"
      )
    )

    drop(constraint(:epw_payroll_import, "epw_payroll_import_epw_supersedes_id_fkey"))

    drop(index(:epw_payroll_import, [:epw_supersedes_id]))

    alter table(:epw_payroll_import) do
      remove(:epw_supersedes_id)
    end
  end
end
