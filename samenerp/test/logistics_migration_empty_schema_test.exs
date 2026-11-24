defmodule Samenerp.LogisticsMigrationEmptySchemaTest do
  @moduledoc """
  The L1 logistics migration on an EMPTY host schema: `up/0` must create its
  column, catalog row and shipment tables without a row to backfill, and
  `down/0` must remove them again.

  This is the deployment-before-data case. The migration's `UPDATE … WHERE
  EXISTS` and its catalog sync must not assume a seeded `eni_item` or
  `elt_lot`; this module owns a scratch database (`async: false`) that it
  never seeds and never shares.
  """

  use ExUnit.Case, async: false

  @migrations Path.expand("../priv/repo/migrations", __DIR__)
  @l1_migration Path.join(@migrations, "20261122120000_mount_inventory_logistics.exs")
  @l1_version 20_261_122_120_000

  defmodule ScratchRepo do
    use Ecto.Repo, otp_app: :samenerp, adapter: Ecto.Adapters.Postgres
  end

  setup_all do
    assert File.regular?(@l1_migration),
           "the L1 empty-schema test must load the source migration from #{@migrations}"

    config =
      Samenerp.Repo.config()
      |> Keyword.delete(:pool)
      |> Keyword.put(
        :database,
        "samenerp_logistics_empty_schema_#{System.unique_integer([:positive])}"
      )
      |> Keyword.put(:pool, DBConnection.ConnectionPool)
      |> Keyword.put(:pool_size, 3)

    :ok = Samen.TestDb.ensure_up!(config)
    {:ok, _} = ScratchRepo.start_link(config)

    # Registered before the first migration: a setup failure must still drop
    # the scratch database (a killed run can only leak it past the OS).
    on_exit(fn ->
      if Process.whereis(ScratchRepo), do: Supervisor.stop(ScratchRepo)
      _ = Ecto.Adapters.Postgres.storage_down(config)
      :ok
    end)

    run_migrator(:up, @l1_version - 1)

    :ok
  end

  test "the L1 logistics migration round-trips on a schema with no items or lots" do
    refute rel_exists?("shp_shipment")
    refute rel_exists?("shm_shipment_line")

    run_migrator(:up, @l1_version)

    assert column_count() == 1
    assert catalog_count() == 1
    assert rel_exists?("shp_shipment")
    assert rel_exists?("shm_shipment_line")

    # Nothing to backfill: the table is empty, so no row claims the flag.
    assert query_value("SELECT count(*) FROM eni_item", []) == 0
    assert query_value("SELECT count(*) FROM eni_item WHERE eni_lot_tracked", []) == 0
    assert query_value("SELECT count(*) FROM elt_lot", []) == 0

    run_migrator(:down, @l1_version - 1)

    assert column_count() == 0
    assert catalog_count() == 0
    refute rel_exists?("shp_shipment")
    refute rel_exists?("shm_shipment_line")
  end

  # Ecto.Migrator compiles migration modules that may already be loaded.
  defp run_migrator(direction, version) do
    previous = Code.get_compiler_option(:ignore_module_conflict)
    Code.put_compiler_option(:ignore_module_conflict, true)

    try do
      Ecto.Migrator.run(ScratchRepo, @migrations, direction, to: version, log: false)
    after
      Code.put_compiler_option(:ignore_module_conflict, previous || false)
    end
  end

  defp column_count do
    query_value(
      "SELECT count(*) FROM information_schema.columns " <>
        "WHERE table_name = 'eni_item' AND column_name = 'eni_lot_tracked'",
      []
    )
  end

  defp catalog_count do
    query_value(
      "SELECT count(*) FROM fld_field " <>
        "WHERE fld_table_name = 'eni_item' AND fld_column_name = 'eni_lot_tracked'",
      []
    )
  end

  defp rel_exists?(name), do: query_value("SELECT to_regclass($1) IS NOT NULL", [name])

  defp query_value(sql, params) do
    %{rows: [[value]]} = Ecto.Adapters.SQL.query!(ScratchRepo, sql, params)
    value
  end
end
