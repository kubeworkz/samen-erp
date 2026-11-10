defmodule SamenCore.TestRepo.Migrations.AllowMultiVendorApPaymentRuns do
  @moduledoc """
  A payment run may span vendors, so its header vendor is optional.

  Single-vendor runs keep the header vendor for convenient display and old
  snapshots; multi-vendor runs identify each vendor on the payment snapshot.
  """

  use Samen.Migration

  def up do
    execute("ALTER TABLE prn_ap_payment_run ALTER COLUMN prn_vendor_id DROP NOT NULL")
  end

  def down do
    execute("ALTER TABLE prn_ap_payment_run ALTER COLUMN prn_vendor_id SET NOT NULL")
  end
end
