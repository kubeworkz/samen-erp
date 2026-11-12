defmodule SamenCore.TestRepo.Migrations.AddApprovalPolicyScope do
  @moduledoc """
  Adds optional account and period scope to the finance fixture's generic
  `ApprovalPolicy`.
  """

  use Samen.Migration

  @resources [SamenCore.Support.FinanceFixture.ApprovalPolicy]

  def up do
    alter table(:fps_approval_policy) do
      add(:fps_account_ids, {:array, :uuid}, null: false, default: [])
      add(:fps_period_keys, {:array, :text}, null: false, default: [])
    end

    catalog_sync(@resources, only: [:account_ids, :period_keys])
  end

  def down do
    catalog_sync_down(@resources, only: [:account_ids, :period_keys])

    alter table(:fps_approval_policy) do
      remove(:fps_account_ids)
      remove(:fps_period_keys)
    end
  end
end
