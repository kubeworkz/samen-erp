defmodule Samen.WebTest.Repo.Migrations.AddFinancePostingAccounts do
  @moduledoc """
  The web test host's `Samen.WebTest.Erp.PostingAccount` resource was listed in
  the ERP mount migration but its table was never created (the historical
  migration deliberately subset the surfaces' tables). The Phase 13 board pack
  reads the `:cash` posting map, so the table is now part of the exercised
  schema. The columns mirror the Finance fixture's `fav_posting_account`.
  """

  use Samen.Migration

  def up do
    create table(:fpa_posting_account, primary_key: false) do
      add(:fpa_key, :text, null: false)
      add(:fpa_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:fpa_org_id, :uuid, null: false)
      add(:fpa_inserted_at, :utc_datetime, null: false)
      add(:fpa_updated_at, :utc_datetime, null: false)

      add(
        :fpa_account_id,
        references(:fca_account,
          column: :fca_id,
          name: "fpa_posting_account_fpa_account_id_fkey",
          type: :uuid
        ),
        null: false
      )
    end

    create(index(:fpa_posting_account, [:fpa_org_id]))
    create(index(:fpa_posting_account, [:fpa_account_id]))
    create(index(:fpa_posting_account, [:fpa_org_id, :fpa_key], unique: true))
  end

  def down do
    drop(table(:fpa_posting_account))
  end
end
