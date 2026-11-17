defmodule SamenCore.TestRepo.Migrations.AddPayrollImportSupersedes do
  @moduledoc """
  The revision link for amended payroll registers.

  A replacement `PayrollImport` points at the prior import it supersedes. The
  original row is retained and its status becomes `:superseded`; the external
  provider id and the linked original journal entry are never rewritten. The
  posted entry itself is voided through the journal's governed reversal path,
  so posted facts remain immutable.
  """

  use Samen.Migration

  @resources [SamenCore.Support.FinanceFixture.PayrollImport]

  def up do
    drop(constraint(:pfs_payroll_import, :pfs_status_valid))

    create(
      constraint(:pfs_payroll_import, :pfs_status_valid,
        check: "pfs_status IN ('imported','conflict','superseded')"
      )
    )

    alter table(:pfs_payroll_import) do
      add(
        :pfs_supersedes_id,
        references(:pfs_payroll_import,
          column: :pfs_id,
          name: "pfs_payroll_import_pfs_supersedes_id_fkey",
          type: :uuid
        )
      )
    end

    create(index(:pfs_payroll_import, [:pfs_supersedes_id]))

    catalog_sync(@resources, only: [:supersedes_id])
  end

  def down do
    catalog_sync_down(@resources, only: [:supersedes_id])

    drop(constraint(:pfs_payroll_import, :pfs_status_valid))

    create(
      constraint(:pfs_payroll_import, :pfs_status_valid,
        check: "pfs_status IN ('imported','conflict')"
      )
    )

    drop(constraint(:pfs_payroll_import, "pfs_payroll_import_pfs_supersedes_id_fkey"))

    drop(index(:pfs_payroll_import, [:pfs_supersedes_id]))

    alter table(:pfs_payroll_import) do
      remove(:pfs_supersedes_id)
    end
  end
end
