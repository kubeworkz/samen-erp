defmodule Samen.WebTest.Repo.Migrations.AddCollectionCadence do
  @moduledoc """
  Per-org scheduled AR collection cadence on the `samen_web` test host.
  Mirrors the Finance fixture: absent rows keep the kernel defaults.
  """

  use Samen.Migration

  @resources [Samen.WebTest.Erp.CollectionCadence]

  def up do
    create table(:fcf_collection_cadence, primary_key: false) do
      add(:fcf_org_id, :uuid, null: false)
      add(:fcf_notice_enabled, :boolean, null: false, default: true)
      add(:fcf_final_notice_enabled, :boolean, null: false, default: true)
      add(:fcf_collections_enabled, :boolean, null: false, default: true)
      add(:fcf_notice_days, :integer, null: false, default: 14)
      add(:fcf_final_notice_days, :integer, null: false, default: 21)
      add(:fcf_collections_days, :integer, null: false, default: 30)

      add(:fcf_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:fcf_inserted_at, :utc_datetime, null: false)
      add(:fcf_updated_at, :utc_datetime, null: false)
    end

    create(
      unique_index(:fcf_collection_cadence, [:fcf_org_id], name: :fcf_collection_cadence_org_idx)
    )

    create(
      constraint(:fcf_collection_cadence, :fcf_collection_cadence_days_valid,
        check:
          "fcf_notice_days BETWEEN 1 AND 365 AND fcf_final_notice_days BETWEEN 1 AND 365 AND " <>
            "fcf_collections_days BETWEEN 1 AND 365"
      )
    )

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)
    drop(constraint(:fcf_collection_cadence, :fcf_collection_cadence_days_valid))
    drop(table(:fcf_collection_cadence))
  end
end
