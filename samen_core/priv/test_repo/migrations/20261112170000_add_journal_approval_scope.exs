defmodule SamenCore.TestRepo.Migrations.AddJournalApprovalScope do
  @moduledoc """
  Adds the optional account/period scope to the finance fixture's
  `JournalApprovalPolicy`. Empty arrays mean "all", preserving the original
  amount-only behavior for existing rows.
  """

  use Samen.Migration

  @resources [SamenCore.Support.FinanceFixture.JournalApprovalPolicy]

  def up do
    alter table(:jap_journal_approval_policy) do
      add(:jap_account_ids, {:array, :uuid}, null: false, default: [])
      add(:jap_period_keys, {:array, :text}, null: false, default: [])
    end

    catalog_sync(@resources, only: [:account_ids, :period_keys])
  end

  def down do
    catalog_sync_down(@resources, only: [:account_ids, :period_keys])

    alter table(:jap_journal_approval_policy) do
      remove(:jap_account_ids)
      remove(:jap_period_keys)
    end
  end
end
