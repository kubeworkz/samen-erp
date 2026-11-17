defmodule Samen.WebTest.Repo.Migrations.AddErpPayrollImportHold do
  @moduledoc """
  The close's named-exception hold on an imported payroll register.

  `exception`, `held_at` and `held_by` are set only by `PayrollImport.:hold`;
  the linked journal entry is untouched. The close precondition accepts the
  hold only when all three agree, so an unattributed or blank exception cannot
  silently excuse payroll from a signed close.
  """

  use Samen.Migration

  @resources [Samen.WebTest.Erp.PayrollImport]

  def change do
    alter table(:epw_payroll_import) do
      add(:epw_exception, :text)
      add(:epw_held_at, :utc_datetime)
      add(:epw_held_by, :text)
    end

    catalog_sync(@resources, only: [:exception, :held_at, :held_by])
  end
end
