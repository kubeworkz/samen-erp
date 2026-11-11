defmodule Samen.WebTest.Repo.Migrations.AddApprovalPolicy do
  @moduledoc """
  Generic approval policy for the web test host. AP is the first consumer.
  """

  use Samen.Migration

  @resources [Samen.WebTest.Erp.ApprovalPolicy]

  def up do
    create table(:wap_approval_policy, primary_key: false) do
      add(:wap_org_id, :uuid, null: false)
      add(:wap_kind, :text, null: false)
      add(:wap_threshold_cents, :bigint, null: false, default: 0)
      add(:wap_auto_approve_below, :boolean, null: false, default: false)
      add(:wap_steps, {:array, :map}, null: false, default: fragment("ARRAY[]::jsonb[]"))
      add(:wap_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:wap_inserted_at, :utc_datetime, null: false)
      add(:wap_updated_at, :utc_datetime, null: false)
    end

    create(
      unique_index(:wap_approval_policy, [:wap_org_id, :wap_kind],
        name: :wap_approval_policy_org_kind_idx
      )
    )

    execute(
      """
      ALTER TABLE wap_approval_policy
        ADD CONSTRAINT wap_threshold_non_negative CHECK (wap_threshold_cents >= 0)
      """,
      "ALTER TABLE wap_approval_policy DROP CONSTRAINT wap_threshold_non_negative"
    )

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    drop(constraint(:wap_approval_policy, :wap_threshold_non_negative))
    drop(table(:wap_approval_policy))
  end
end
