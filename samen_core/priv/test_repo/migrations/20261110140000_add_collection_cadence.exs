defmodule SamenCore.TestRepo.Migrations.AddCollectionCadence do
  @moduledoc """
  Per-org scheduled AR collection cadence in the `samen_core` Finance fixture.
  A missing row means the kernel defaults, so existing orgs keep their behavior.
  """

  use Samen.Migration

  @resources [SamenCore.Support.FinanceFixture.CollectionCadence]

  def up do
    create table(:scq_collection_cadence, primary_key: false) do
      add(:scq_org_id, :uuid, null: false)
      add(:scq_notice_enabled, :boolean, null: false, default: true)
      add(:scq_final_notice_enabled, :boolean, null: false, default: true)
      add(:scq_collections_enabled, :boolean, null: false, default: true)
      add(:scq_notice_days, :integer, null: false, default: 14)
      add(:scq_final_notice_days, :integer, null: false, default: 21)
      add(:scq_collections_days, :integer, null: false, default: 30)

      add(:scq_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:scq_inserted_at, :utc_datetime, null: false)
      add(:scq_updated_at, :utc_datetime, null: false)
    end

    create(
      unique_index(:scq_collection_cadence, [:scq_org_id], name: :scq_collection_cadence_org_idx)
    )

    create(
      constraint(:scq_collection_cadence, :scq_collection_cadence_days_valid,
        check:
          "scq_notice_days BETWEEN 1 AND 365 AND scq_final_notice_days BETWEEN 1 AND 365 AND " <>
            "scq_collections_days BETWEEN 1 AND 365"
      )
    )

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)
    drop(constraint(:scq_collection_cadence, :scq_collection_cadence_days_valid))
    drop(table(:scq_collection_cadence))
  end
end
