defmodule SamenCore.TestRepo.Migrations.AddApCurrencyAndFx do
  @moduledoc """
  AP bill currency and functional-FX facts, plus the single currency of an AP
  payment run. Currency is nullable for legacy bills; the application resolves
  a blank value from `OrgFxSettings` and stamps the base facts at approval.
  """

  use Samen.Migration

  def up do
    alter table(:sap_ap_invoice) do
      add(:sap_currency, :text)
      add(:sap_base_currency, :text)
      add(:sap_base_total_cents, :bigint)
      add(:sap_exchange_rate, :text)
    end

    alter table(:prn_ap_payment_run) do
      add(:prn_currency, :text, null: false, default: "USD")
    end
  end

  def down do
    alter table(:prn_ap_payment_run) do
      remove(:prn_currency)
    end

    alter table(:sap_ap_invoice) do
      remove(:sap_exchange_rate)
      remove(:sap_base_total_cents)
      remove(:sap_base_currency)
      remove(:sap_currency)
    end
  end
end
