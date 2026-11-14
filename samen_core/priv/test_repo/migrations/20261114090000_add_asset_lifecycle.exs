defmodule SamenCore.TestRepo.Migrations.AddAssetLifecycle do
  @moduledoc """
  WS-ACCT Phase 8 extension (ADR-054 D9): asset disposal accounting, transfers
  and construction-in-progress on the `samen_core` fixture.

    * `in_service_on` — the schedule start. Existing active rows are backfilled
      from `acquired_on`, so every old asset keeps its exact schedule.
    * disposal facts + entry anchors — the disposal action posts the standard
      proceeds/accumulated/cost/gain-loss entry and records what it posted.
    * `transfer_history` — dated from/to cost-object records; future
      depreciation follows the current dimension.
    * status gains `under_construction`: a CIP has no schedule until
      `:place_in_service` posts its reclassification.
  """

  use Samen.Migration

  @resources [SamenCore.Support.FinanceFixture.Asset]

  @new_fields [
    :in_service_on,
    :disposal_proceeds_cents,
    :disposal_gain_loss_cents,
    :disposal_entry_id,
    :in_service_entry_id,
    :transfer_history
  ]

  def up do
    alter table(:fsf_asset) do
      add(:fsf_in_service_on, :date)
      add(:fsf_disposal_proceeds_cents, :bigint)
      add(:fsf_disposal_gain_loss_cents, :bigint)
      add(:fsf_disposal_entry_id, :uuid)
      add(:fsf_in_service_entry_id, :uuid)

      add(:fsf_transfer_history, {:array, :map},
        null: false,
        default: fragment("ARRAY[]::jsonb[]")
      )
    end

    execute("UPDATE fsf_asset SET fsf_in_service_on = fsf_acquired_on")

    execute("ALTER TABLE fsf_asset DROP CONSTRAINT fsf_status_valid")
    execute("ALTER TABLE fsf_asset DROP CONSTRAINT fsf_disposal_valid")

    create(
      constraint(:fsf_asset, :fsf_status_valid,
        check: "fsf_status IN ('active','under_construction','disposed')"
      )
    )

    create(
      constraint(:fsf_asset, :fsf_disposal_valid,
        check: """
        ((fsf_status = 'disposed' AND fsf_disposed_on IS NOT NULL) OR
         (fsf_status <> 'disposed' AND fsf_disposed_on IS NULL)) AND
        (fsf_in_service_on IS NULL OR fsf_in_service_on >= fsf_acquired_on) AND
        (fsf_status <> 'active' OR fsf_in_service_on IS NOT NULL) AND
        (fsf_status <> 'under_construction' OR fsf_in_service_on IS NULL) AND
        (fsf_status <> 'disposed' OR
          (fsf_disposal_proceeds_cents IS NOT NULL AND fsf_disposal_gain_loss_cents IS NOT NULL)) AND
        (fsf_status = 'disposed' OR
          (fsf_disposal_proceeds_cents IS NULL AND fsf_disposal_gain_loss_cents IS NULL AND
           fsf_disposal_entry_id IS NULL))
        """
      )
    )

    create(
      constraint(:fsf_asset, :fsf_disposal_proceeds_non_negative,
        check: "fsf_disposal_proceeds_cents IS NULL OR fsf_disposal_proceeds_cents >= 0"
      )
    )

    catalog_sync(@resources, only: @new_fields)
  end

  def down do
    catalog_sync_down(@resources, only: @new_fields)

    execute("ALTER TABLE fsf_asset DROP CONSTRAINT fsf_status_valid")
    execute("ALTER TABLE fsf_asset DROP CONSTRAINT fsf_disposal_valid")
    execute("ALTER TABLE fsf_asset DROP CONSTRAINT fsf_disposal_proceeds_non_negative")

    execute("UPDATE fsf_asset SET fsf_status = 'active' WHERE fsf_status = 'under_construction'")

    alter table(:fsf_asset) do
      remove(:fsf_in_service_on)
      remove(:fsf_disposal_proceeds_cents)
      remove(:fsf_disposal_gain_loss_cents)
      remove(:fsf_disposal_entry_id)
      remove(:fsf_in_service_entry_id)
      remove(:fsf_transfer_history)
    end

    create(
      constraint(:fsf_asset, :fsf_status_valid, check: "fsf_status IN ('active','disposed')")
    )

    create(
      constraint(:fsf_asset, :fsf_disposal_valid,
        check: """
        ((fsf_status = 'disposed' AND fsf_disposed_on IS NOT NULL) OR
         (fsf_status = 'active' AND fsf_disposed_on IS NULL)) AND
        (fsf_disposed_on IS NULL OR fsf_disposed_on >= fsf_acquired_on)
        """
      )
    )
  end
end
