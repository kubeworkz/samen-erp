defmodule Samenerp.Repo.Migrations.AddCollectionCadence do
  @moduledoc """
  Per-org scheduled AR collection cadence on the Kubeworkz books. Mirrors the
  Finance fixture; a missing row uses the kernel defaults.
  """

  use Samen.Migration

  @resources [Samenerp.Erp.CollectionCadence]

  def up do
    create table(:ecq_collection_cadence, primary_key: false) do
      add(:ecq_org_id, :uuid, null: false)
      add(:ecq_notice_enabled, :boolean, null: false, default: true)
      add(:ecq_final_notice_enabled, :boolean, null: false, default: true)
      add(:ecq_collections_enabled, :boolean, null: false, default: true)
      add(:ecq_notice_days, :integer, null: false, default: 14)
      add(:ecq_final_notice_days, :integer, null: false, default: 21)
      add(:ecq_collections_days, :integer, null: false, default: 30)

      add(:ecq_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:ecq_inserted_at, :utc_datetime, null: false)
      add(:ecq_updated_at, :utc_datetime, null: false)
    end

    create(
      unique_index(:ecq_collection_cadence, [:ecq_org_id], name: :ecq_collection_cadence_org_idx)
    )

    create(
      constraint(:ecq_collection_cadence, :ecq_collection_cadence_days_valid,
        check:
          "ecq_notice_days BETWEEN 1 AND 365 AND ecq_final_notice_days BETWEEN 1 AND 365 AND " <>
            "ecq_collections_days BETWEEN 1 AND 365"
      )
    )

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)
    drop(constraint(:ecq_collection_cadence, :ecq_collection_cadence_days_valid))
    drop(table(:ecq_collection_cadence))
  end
end
