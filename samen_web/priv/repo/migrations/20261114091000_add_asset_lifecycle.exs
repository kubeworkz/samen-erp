defmodule Samen.WebTest.Repo.Migrations.AddAssetLifecycle do
  @moduledoc """
  WS-ACCT Phase 8 extension (ADR-054 D9): the asset lifecycle columns on the
  `samen_web` test host (`Samen.WebTest.Erp`, asset `fas`). Same shape and
  constraints as the `samen_core` fixture: CIP status, in-service start,
  disposal facts, and the transfer history.
  """

  use Samen.Migration

  @resources [Samen.WebTest.Erp.Asset]

  @new_fields [
    :in_service_on,
    :disposal_proceeds_cents,
    :disposal_gain_loss_cents,
    :disposal_entry_id,
    :in_service_entry_id,
    :transfer_history
  ]

  def up do
    alter table(:fas_asset) do
      add(:fas_in_service_on, :date)
      add(:fas_disposal_proceeds_cents, :bigint)
      add(:fas_disposal_gain_loss_cents, :bigint)
      add(:fas_disposal_entry_id, :uuid)
      add(:fas_in_service_entry_id, :uuid)

      add(:fas_transfer_history, {:array, :map},
        null: false,
        default: fragment("ARRAY[]::jsonb[]")
      )
    end

    execute("UPDATE fas_asset SET fas_in_service_on = fas_acquired_on")

    execute("ALTER TABLE fas_asset DROP CONSTRAINT fas_status_valid")
    execute("ALTER TABLE fas_asset DROP CONSTRAINT fas_disposal_valid")

    create(
      constraint(:fas_asset, :fas_status_valid,
        check: "fas_status IN ('active','under_construction','disposed')"
      )
    )

    create(
      constraint(:fas_asset, :fas_disposal_valid,
        check: """
        ((fas_status = 'disposed' AND fas_disposed_on IS NOT NULL) OR
         (fas_status <> 'disposed' AND fas_disposed_on IS NULL)) AND
        (fas_in_service_on IS NULL OR fas_in_service_on >= fas_acquired_on) AND
        (fas_status <> 'active' OR fas_in_service_on IS NOT NULL) AND
        (fas_status <> 'under_construction' OR fas_in_service_on IS NULL) AND
        (fas_status <> 'disposed' OR
          (fas_disposal_proceeds_cents IS NOT NULL AND fas_disposal_gain_loss_cents IS NOT NULL)) AND
        (fas_status = 'disposed' OR
          (fas_disposal_proceeds_cents IS NULL AND fas_disposal_gain_loss_cents IS NULL AND
           fas_disposal_entry_id IS NULL))
        """
      )
    )

    create(
      constraint(:fas_asset, :fas_disposal_proceeds_non_negative,
        check: "fas_disposal_proceeds_cents IS NULL OR fas_disposal_proceeds_cents >= 0"
      )
    )

    catalog_sync(@resources, only: @new_fields)
  end

  def down do
    catalog_sync_down(@resources, only: @new_fields)

    execute("ALTER TABLE fas_asset DROP CONSTRAINT fas_status_valid")
    execute("ALTER TABLE fas_asset DROP CONSTRAINT fas_disposal_valid")
    execute("ALTER TABLE fas_asset DROP CONSTRAINT fas_disposal_proceeds_non_negative")

    execute("UPDATE fas_asset SET fas_status = 'active' WHERE fas_status = 'under_construction'")

    alter table(:fas_asset) do
      remove(:fas_in_service_on)
      remove(:fas_disposal_proceeds_cents)
      remove(:fas_disposal_gain_loss_cents)
      remove(:fas_disposal_entry_id)
      remove(:fas_in_service_entry_id)
      remove(:fas_transfer_history)
    end

    create(
      constraint(:fas_asset, :fas_status_valid, check: "fas_status IN ('active','disposed')")
    )

    create(
      constraint(:fas_asset, :fas_disposal_valid,
        check: """
        ((fas_status = 'disposed' AND fas_disposed_on IS NOT NULL) OR
         (fas_status = 'active' AND fas_disposed_on IS NULL)) AND
        (fas_disposed_on IS NULL OR fas_disposed_on >= fas_acquired_on)
        """
      )
    )
  end
end
