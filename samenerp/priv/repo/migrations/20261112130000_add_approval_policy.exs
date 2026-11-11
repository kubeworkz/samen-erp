defmodule Samenerp.Repo.Migrations.AddApprovalPolicy do
  @moduledoc """
  Generic approval policy plus the chain snapshot for the ERP host. AP is the
  first consumer; later gated actions use another `kind` row.
  """

  use Samen.Migration

  @resources [Samenerp.Erp.ApprovalPolicy]

  def up do
    create table(:eap_approval_policy, primary_key: false) do
      add(:eap_org_id, :uuid, null: false)
      add(:eap_kind, :text, null: false)
      add(:eap_threshold_cents, :bigint, null: false, default: 0)
      add(:eap_auto_approve_below, :boolean, null: false, default: false)
      add(:eap_steps, {:array, :map}, null: false, default: fragment("ARRAY[]::jsonb[]"))
      add(:eap_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:eap_inserted_at, :utc_datetime, null: false)
      add(:eap_updated_at, :utc_datetime, null: false)
    end

    create(
      unique_index(:eap_approval_policy, [:eap_org_id, :eap_kind],
        name: :eap_approval_policy_org_kind_idx
      )
    )

    execute(
      """
      ALTER TABLE eap_approval_policy
        ADD CONSTRAINT eap_threshold_non_negative CHECK (eap_threshold_cents >= 0)
      """,
      "ALTER TABLE eap_approval_policy DROP CONSTRAINT eap_threshold_non_negative"
    )

    alter table(:erz_approval) do
      add(:erz_steps, {:array, :map}, null: false, default: fragment("ARRAY[]::jsonb[]"))
    end

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    alter table(:erz_approval) do
      remove(:erz_steps)
    end

    drop(constraint(:eap_approval_policy, :eap_threshold_non_negative))
    drop(table(:eap_approval_policy))
  end
end
