defmodule Samen.WebTest.Repo.Migrations.AddApprovalPolicyScope do
  @moduledoc """
  Adds optional account and period scope to the web test host's generic
  `ApprovalPolicy`.
  """

  use Samen.Migration

  @resources [Samen.WebTest.Erp.ApprovalPolicy]

  def up do
    alter table(:wap_approval_policy) do
      add(:wap_account_ids, {:array, :uuid}, null: false, default: [])
      add(:wap_period_keys, {:array, :text}, null: false, default: [])
    end

    catalog_sync(@resources, only: [:account_ids, :period_keys])
  end

  def down do
    catalog_sync_down(@resources, only: [:account_ids, :period_keys])

    alter table(:wap_approval_policy) do
      remove(:wap_account_ids)
      remove(:wap_period_keys)
    end
  end
end
