defmodule Samen.WebTest.Repo.Migrations.SplitErpPayrollImportIdentity do
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
    :epw_org_id,
    :epw_provider,
    :epw_external_id,
    :epw_line_set_hash,
    :epw_entry_date
  ]

  def up do
    drop(index(:epw_payroll_import, @identity, name: :epw_payroll_import_unique))

    create(
      unique_index(:epw_payroll_import, @identity,
        name: :epw_payroll_import_imported_unique,
        where: "epw_status = 'imported'"
      )
    )

    create(
      unique_index(:epw_payroll_import, @identity,
        name: :epw_payroll_import_conflict_unique,
        where: "epw_status = 'conflict'"
      )
    )
  end

  def down do
    drop(index(:epw_payroll_import, @identity, name: :epw_payroll_import_imported_unique))

    drop(index(:epw_payroll_import, @identity, name: :epw_payroll_import_conflict_unique))

    create(unique_index(:epw_payroll_import, @identity, name: :epw_payroll_import_unique))
  end
end
