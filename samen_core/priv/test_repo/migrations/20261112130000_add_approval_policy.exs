defmodule SamenCore.TestRepo.Migrations.AddApprovalPolicy do
  @moduledoc """
  Generic approval policy plus the approval-chain snapshot for the finance fixture.

  AP is the first consumer; the policy key is stable (`"ap_invoice:approve"`), so
  the table can later serve other gated actions without a schema change.
  """

  use Samen.Migration

  @resources [SamenCore.Support.FinanceFixture.ApprovalPolicy]

  def up do
    create table(:fps_approval_policy, primary_key: false) do
      add(:fps_org_id, :uuid, null: false)
      add(:fps_kind, :text, null: false)
      add(:fps_threshold_cents, :bigint, null: false, default: 0)
      add(:fps_auto_approve_below, :boolean, null: false, default: false)
      add(:fps_steps, {:array, :map}, null: false, default: fragment("ARRAY[]::jsonb[]"))
      add(:fps_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:fps_inserted_at, :utc_datetime, null: false)
      add(:fps_updated_at, :utc_datetime, null: false)
    end

    create(
      unique_index(:fps_approval_policy, [:fps_org_id, :fps_kind],
        name: :fps_approval_policy_org_kind_idx
      )
    )

    execute(
      """
      ALTER TABLE fps_approval_policy
        ADD CONSTRAINT fps_threshold_non_negative CHECK (fps_threshold_cents >= 0)
      """,
      "ALTER TABLE fps_approval_policy DROP CONSTRAINT fps_threshold_non_negative"
    )

    alter table(:apv_approval) do
      add(:apv_steps, {:array, :map}, null: false, default: fragment("ARRAY[]::jsonb[]"))
    end

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    alter table(:apv_approval) do
      remove(:apv_steps)
    end

    drop(constraint(:fps_approval_policy, :fps_threshold_non_negative))
    drop(table(:fps_approval_policy))
  end
end
