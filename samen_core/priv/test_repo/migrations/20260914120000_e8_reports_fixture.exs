defmodule SamenCore.TestRepo.Migrations.E8ReportsFixture do
  @moduledoc """
  Tables for the WS-ERP E8 BI/reports suite (design §6.2):

    * `ser_trial_balance` — the trial-balance ROLLUP (per-account posted
      sums; materialized by `Samen.Rollup.refresh/2` from the GL fixture
      tables — the `:domain` ADR-018 source shape).
    * `spw_wip_stock` — the stock/WIP rollup (per-(org, item, warehouse)
      on-hand + value from the stock ledger).
    * `shc_headcount_by_org` — the headcount rollup (per-org derived
      employment facts; counts events, never persons — the erasure story:
      the vault shreds, the count survives).
    * `sea_portfolio_by_industry` — the cross-tenant portfolio PROJECTION
      backing `Samen.E8Aggregate.PortfolioByIndustry` (every column a
      bounded bucket/count; the k-anon floor suppresses a cohort under
      floor).

  The rollup tables carry manual `tam_table`/`fld_field` rows in the kernel
  `20260705090000_rollup.exs` shape (the rollup registry is not
  `:ash_domains`-discoverable). Their PHYSICAL columns are the prefixed
  `<abbrev>_<name>` forms — the same convention every fixture table keeps,
  and the exact identifiers the specs' rebuild SQL and the catalog rows use.
  `sea_` backs a real Ash resource, so it is catalogued via `catalog_sync/1`
  (the E1 helper) — the same posture as every E1–E7 fixture migration.
  """

  use Samen.Migration

  alias Samen.E8Aggregate.PortfolioByIndustry

  # {table, resource, fields} — fields are {physical, logical, catalog type};
  # the FIRST field is the PK (DB-defaulted), refreshed_at is DB-defaulted.
  @rollup_tables [
    {"ser_trial_balance", "Samen.E8Rollups.TrialBalance",
     [
       {"ser_id", "id", "UUID"},
       {"ser_org_id", "org_id", "UUID"},
       {"ser_account_id", "account_id", "UUID"},
       {"ser_account_code", "account_code", "String"},
       {"ser_debit_cents", "debit_cents", "Integer"},
       {"ser_credit_cents", "credit_cents", "Integer"},
       {"ser_balance_cents", "balance_cents", "Integer"},
       {"ser_refreshed_at", "refreshed_at", "UTCDatetime"}
     ]},
    {"spw_wip_stock", "Samen.E8Rollups.WipStock",
     [
       {"spw_id", "id", "UUID"},
       {"spw_org_id", "org_id", "UUID"},
       {"spw_item_id", "item_id", "UUID"},
       {"spw_warehouse_id", "warehouse_id", "UUID"},
       {"spw_on_hand", "on_hand", "Integer"},
       {"spw_value_cents", "value_cents", "Integer"},
       {"spw_refreshed_at", "refreshed_at", "UTCDatetime"}
     ]},
    {"shc_headcount_by_org", "Samen.E8Rollups.Headcount",
     [
       {"shc_id", "id", "UUID"},
       {"shc_org_id", "org_id", "UUID"},
       {"shc_headcount", "headcount", "Integer"},
       {"shc_hires", "hires", "Integer"},
       {"shc_terminations", "terminations", "Integer"},
       {"shc_refreshed_at", "refreshed_at", "UTCDatetime"}
     ]}
  ]

  @pg_types %{
    "UUID" => "UUID",
    "String" => "TEXT",
    "Integer" => "BIGINT DEFAULT 0",
    "UTCDatetime" => "TIMESTAMPTZ"
  }

  def up do
    for {table, resource, fields} <- @rollup_tables do
      create_rollup_table(table, fields)

      execute "INSERT INTO tam_table (tam_table_name, tam_resource) VALUES ('#{table}', '#{resource}')
               ON CONFLICT (tam_table_name) DO NOTHING",
              "DELETE FROM tam_table WHERE tam_table_name = '#{table}'"

      fld_rows =
        fields
        |> Enum.map(fn {col, logical, type} ->
          "('#{table}', '#{col}', '#{logical}', '#{type}')"
        end)
        |> Enum.join(", ")

      execute """
      INSERT INTO fld_field (fld_table_name, fld_column_name, fld_logical_name, fld_type)
      VALUES #{fld_rows}
      ON CONFLICT (fld_table_name, fld_column_name) DO NOTHING
      """,
      "DELETE FROM fld_field WHERE fld_table_name = '#{table}'"
    end

    create_portfolio_table()
    catalog_sync([PortfolioByIndustry])
  end

  def down do
    catalog_sync_down([PortfolioByIndustry])
    drop(table(:sea_portfolio_by_industry))

    for {table, resource, _fields} <- Enum.reverse(@rollup_tables) do
      execute "DELETE FROM fld_field WHERE fld_table_name = '#{table}'"
      execute "DELETE FROM tam_table WHERE tam_table_name = '#{table}' AND tam_resource = '#{resource}'"
      execute "DROP TABLE IF EXISTS #{table}"
    end
  end

  # One CREATE per table, generated from the SAME field list the catalog rows
  # use — the physical shape and the catalog can never drift. The PK is
  # DB-defaulted (the rebuild SQL never names it); refreshed_at is DB-defaulted.
  defp create_rollup_table(table, fields) do
    {pk_col, _, _} = hd(fields)

    cols =
      fields
      |> Enum.with_index()
      |> Enum.map(fn
        {{col, _logical, type}, 0} ->
          "#{col} #{@pg_types[type]} NOT NULL DEFAULT gen_random_uuid()"

        {{col, "refreshed_at", type}, _} ->
          "#{col} #{@pg_types[type]} NOT NULL DEFAULT now()"

        {{col, _logical, type}, _} ->
          "#{col} #{@pg_types[type]}"
      end)
      |> Enum.join(",\n      ")

    execute """
    CREATE TABLE IF NOT EXISTS #{table} (
      #{cols},
      PRIMARY KEY (#{pk_col})
    )
    """,
    "DROP TABLE IF EXISTS #{table}"
  end

  defp create_portfolio_table do
    create table(:sea_portfolio_by_industry, primary_key: false) do
      add(:sea_industry, :text, null: false)
      add(:sea_tenant_count, :integer, null: false, default: 0)
      add(:sea_revenue_cents, :bigint, null: false, default: 0)
      add(:sea_refreshed_at, :utc_datetime)
      add(:sea_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:sea_org_id, :uuid)

      # Timestamp defaults so a raw projection INSERT (the seed path — rows
      # arrive from a rollup refresh in production) lands complete.
      add(:sea_inserted_at, :utc_datetime, null: false, default: fragment("now()"))
      add(:sea_updated_at, :utc_datetime, null: false, default: fragment("now()"))
    end

    create(index(:sea_portfolio_by_industry, [:sea_industry]))
  end
end
