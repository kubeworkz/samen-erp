defmodule SamenCore.TestRepo.Migrations.SplitPayrollImportIdentity do
  @moduledoc """
  Keep conflict history when a later amendment imports the same payroll line set.

  The original unique index covered every status, so a conflict row from the
  old hard-stop path would block the replacement import even though the two
  rows describe different outcomes. The identity is now unique per status:
  one imported row and one conflict row may coexist; superseded rows are free
  to accumulate as the revision chain.
  """

  use Samen.Migration

  @identity [
    :pfs_org_id,
    :pfs_provider,
    :pfs_external_id,
    :pfs_line_set_hash,
    :pfs_entry_date
  ]

  def up do
    drop(index(:pfs_payroll_import, @identity, name: :pfs_payroll_import_unique))

    create(
      unique_index(:pfs_payroll_import, @identity,
        name: :pfs_payroll_import_imported_unique,
        where: "pfs_status = 'imported'"
      )
    )

    create(
      unique_index(:pfs_payroll_import, @identity,
        name: :pfs_payroll_import_conflict_unique,
        where: "pfs_status = 'conflict'"
      )
    )
  end

  def down do
    drop(index(:pfs_payroll_import, @identity, name: :pfs_payroll_import_imported_unique))

    drop(index(:pfs_payroll_import, @identity, name: :pfs_payroll_import_conflict_unique))

    create(unique_index(:pfs_payroll_import, @identity, name: :pfs_payroll_import_unique))
  end
end
