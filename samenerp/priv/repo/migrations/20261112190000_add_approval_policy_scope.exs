defmodule Samenerp.Repo.Migrations.AddApprovalPolicyScope do
  @moduledoc """
  Adds optional account and period scope to the ERP host's generic
  `ApprovalPolicy`. Empty scopes preserve the unscoped policy behavior.
  """

  use Samen.Migration

  @resources [Samenerp.Erp.ApprovalPolicy]

  def up do
    alter table(:eap_approval_policy) do
      add(:eap_account_ids, {:array, :uuid}, null: false, default: [])
      add(:eap_period_keys, {:array, :text}, null: false, default: [])
    end

    catalog_sync(@resources, only: [:account_ids, :period_keys])
  end

  def down do
    catalog_sync_down(@resources, only: [:account_ids, :period_keys])

    alter table(:eap_approval_policy) do
      remove(:eap_account_ids)
      remove(:eap_period_keys)
    end
  end
end
