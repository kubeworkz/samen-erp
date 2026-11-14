defmodule Samenerp.Repo.Migrations.AddAssetLifecycle do
  @moduledoc """
  WS-ACCT Phase 8 extension (ADR-054 D9): the asset lifecycle columns on the
  Kubeworkz books (`Samenerp.Erp`, asset `eas`). Same shape and constraints as
  the other hosts; the committed `schema.dict.json` is regenerated in the same
  change.
  """

  use Samen.Migration

  @resources [Samenerp.Erp.Asset]

  @new_fields [
    :in_service_on,
    :disposal_proceeds_cents,
    :disposal_gain_loss_cents,
    :disposal_entry_id,
    :in_service_entry_id,
    :transfer_history
  ]

  def up do
    alter table(:eas_asset) do
      add(:eas_in_service_on, :date)
      add(:eas_disposal_proceeds_cents, :bigint)
      add(:eas_disposal_gain_loss_cents, :bigint)
      add(:eas_disposal_entry_id, :uuid)
      add(:eas_in_service_entry_id, :uuid)

      add(:eas_transfer_history, {:array, :map},
        null: false,
        default: fragment("ARRAY[]::jsonb[]")
      )
    end

    execute("UPDATE eas_asset SET eas_in_service_on = eas_acquired_on")

    execute("ALTER TABLE eas_asset DROP CONSTRAINT eas_status_valid")
    execute("ALTER TABLE eas_asset DROP CONSTRAINT eas_disposal_valid")

    create(
      constraint(:eas_asset, :eas_status_valid,
        check: "eas_status IN ('active','under_construction','disposed')"
      )
    )

    create(
      constraint(:eas_asset, :eas_disposal_valid,
        check: """
        ((eas_status = 'disposed' AND eas_disposed_on IS NOT NULL) OR
         (eas_status <> 'disposed' AND eas_disposed_on IS NULL)) AND
        (eas_in_service_on IS NULL OR eas_in_service_on >= eas_acquired_on) AND
        (eas_status <> 'active' OR eas_in_service_on IS NOT NULL) AND
        (eas_status <> 'under_construction' OR eas_in_service_on IS NULL) AND
        (eas_status <> 'disposed' OR
          (eas_disposal_proceeds_cents IS NOT NULL AND eas_disposal_gain_loss_cents IS NOT NULL)) AND
        (eas_status = 'disposed' OR
          (eas_disposal_proceeds_cents IS NULL AND eas_disposal_gain_loss_cents IS NULL AND
           eas_disposal_entry_id IS NULL))
        """
      )
    )

    create(
      constraint(:eas_asset, :eas_disposal_proceeds_non_negative,
        check: "eas_disposal_proceeds_cents IS NULL OR eas_disposal_proceeds_cents >= 0"
      )
    )

    catalog_sync(@resources, only: @new_fields)
  end

  def down do
    catalog_sync_down(@resources, only: @new_fields)

    execute("ALTER TABLE eas_asset DROP CONSTRAINT eas_status_valid")
    execute("ALTER TABLE eas_asset DROP CONSTRAINT eas_disposal_valid")
    execute("ALTER TABLE eas_asset DROP CONSTRAINT eas_disposal_proceeds_non_negative")

    execute("UPDATE eas_asset SET eas_status = 'active' WHERE eas_status = 'under_construction'")

    alter table(:eas_asset) do
      remove(:eas_in_service_on)
      remove(:eas_disposal_proceeds_cents)
      remove(:eas_disposal_gain_loss_cents)
      remove(:eas_disposal_entry_id)
      remove(:eas_in_service_entry_id)
      remove(:eas_transfer_history)
    end

    create(
      constraint(:eas_asset, :eas_status_valid, check: "eas_status IN ('active','disposed')")
    )

    create(
      constraint(:eas_asset, :eas_disposal_valid,
        check: """
        ((eas_status = 'disposed' AND eas_disposed_on IS NOT NULL) OR
         (eas_status = 'active' AND eas_disposed_on IS NULL)) AND
        (eas_disposed_on IS NULL OR eas_disposed_on >= eas_acquired_on)
        """
      )
    )
  end
end
