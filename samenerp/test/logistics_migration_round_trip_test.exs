defmodule Samenerp.LogisticsMigrationRoundTripTest do
  @moduledoc """
  The L1 logistics migration's reversibility gate: apply it to the host schema,
  take it back down, and apply it again.

  `down/0` is the expand phase's promise — the `eni_lot_tracked` column, its
  `fld_field` catalog row and both shipment tables must go. The next `up/0`
  must then re-derive the flag from the live `Lot` rows, including a lot
  written after the first backfill, which the flag does not track until the
  migration runs again.

  This module owns a scratch database (`async: false`), like the backfill
  proof, and drives the real source migration directory itself. It reads that
  database through raw SQL and never touches the shared test schema.
  """

  use ExUnit.Case, async: false

  # Ecto.Migrator reads this source DIRECTORY, so a patched source migration is
  # the one that executes — never a stale priv copy under `_build`.
  @migrations Path.expand("../priv/repo/migrations", __DIR__)
  @l1_migration Path.join(@migrations, "20261122120000_mount_inventory_logistics.exs")
  @l1_version 20_261_122_120_000

  @org_id Ecto.UUID.generate()
  @cost_object_id Ecto.UUID.generate()
  @lot_item_id Ecto.UUID.generate()
  @plain_item_id Ecto.UUID.generate()

  defmodule ScratchRepo do
    use Ecto.Repo, otp_app: :samenerp, adapter: Ecto.Adapters.Postgres
  end

  setup_all do
    assert File.regular?(@l1_migration),
           "the L1 round-trip test must load the source migration from #{@migrations}"

    config = scratch_config()
    :ok = Samen.TestDb.ensure_up!(config)
    {:ok, _} = ScratchRepo.start_link(config)

    run_migrator(:up, @l1_version - 1)
    seed_items_and_lot()
    run_migrator(:up, @l1_version)

    on_exit(fn ->
      if Process.whereis(ScratchRepo), do: Supervisor.stop(ScratchRepo)
      _ = Ecto.Adapters.Postgres.storage_down(config)
      :ok
    end)

    :ok
  end

  test "the L1 logistics migration round-trips down/0 and re-backfills on the next up" do
    # The first up: the seeded lot-backed item is true, the control stays false.
    assert @l1_version in Ecto.Migrator.migrated_versions(ScratchRepo)
    assert flag(@lot_item_id) == true
    assert flag(@plain_item_id) == false

    # A Lot created AFTER the backfill is not tracked by the migration: the
    # live `Lot` existence check, not the flag, is what refuses its shipment.
    insert_lot(@plain_item_id, "L1-POST-BACKFILL")
    assert flag(@plain_item_id) == false

    # down/0 removes everything up/0 added.
    run_migrator(:down, @l1_version - 1)

    assert column_count() == 0
    assert catalog_count("eni_item", "eni_lot_tracked") == 0
    refute rel_exists?("shp_shipment")
    refute rel_exists?("shm_shipment_line")

    # up/0 runs the backfill again and now sees the post-backfill lot.
    run_migrator(:up, @l1_version)

    assert column_count() == 1
    assert catalog_count("eni_item", "eni_lot_tracked") == 1
    assert rel_exists?("shp_shipment")
    assert rel_exists?("shm_shipment_line")

    assert flag(@lot_item_id) == true
    assert flag(@plain_item_id) == true
  end

  defp scratch_config do
    Samenerp.Repo.config()
    |> Keyword.delete(:pool)
    |> Keyword.put(
      :database,
      "samenerp_logistics_round_trip_#{System.unique_integer([:positive])}"
    )
    |> Keyword.put(:pool, DBConnection.ConnectionPool)
    |> Keyword.put(:pool_size, 3)
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

  defp seed_items_and_lot do
    execute(
      """
      INSERT INTO eco_cost_object
        (eco_id, eco_org_id, eco_code, eco_name, eco_kind, eco_inserted_at, eco_updated_at)
      VALUES ($1, $2, $3, $4, $5, $6, $6)
      """,
      [
        uuid_param(@cost_object_id),
        uuid_param(@org_id),
        "L1-RT",
        "L1 round-trip cost object",
        "project",
        now()
      ]
    )

    for {id, sku} <- [{@lot_item_id, "L1-RT-LOT"}, {@plain_item_id, "L1-RT-PLAIN"}] do
      execute(
        """
        INSERT INTO eni_item
          (eni_id, eni_org_id, eni_sku, eni_name, eni_kind, eni_uom, eni_inserted_at, eni_updated_at)
        VALUES ($1, $2, $3, $4, 'stocked', 'unit', $5, $5)
        """,
        [uuid_param(id), uuid_param(@org_id), sku, sku, now()]
      )
    end

    insert_lot(@lot_item_id, "L1-RT-LOT-1")
  end

  defp insert_lot(item_id, code) do
    execute(
      """
      INSERT INTO elt_lot
        (elt_id, elt_org_id, elt_code, elt_stage, elt_wafer_count, elt_die_expected,
         elt_die_actual, elt_item_id, elt_cost_object_id, elt_inserted_at, elt_updated_at)
      VALUES ($1, $2, $3, 'design', 0, 0, 0, $4, $5, $6, $6)
      """,
      [
        uuid(),
        uuid_param(@org_id),
        code,
        uuid_param(item_id),
        uuid_param(@cost_object_id),
        now()
      ]
    )
  end

  defp flag(item_id) do
    query_value("SELECT eni_lot_tracked FROM eni_item WHERE eni_id = $1", [uuid_param(item_id)])
  end

  defp column_count do
    query_value(
      "SELECT count(*) FROM information_schema.columns " <>
        "WHERE table_name = 'eni_item' AND column_name = 'eni_lot_tracked'",
      []
    )
  end

  defp catalog_count(table, column) do
    query_value(
      "SELECT count(*) FROM fld_field WHERE fld_table_name = $1 AND fld_column_name = $2",
      [table, column]
    )
  end

  defp rel_exists?(name), do: query_value("SELECT to_regclass($1) IS NOT NULL", [name])

  defp execute(sql, params), do: Ecto.Adapters.SQL.query!(ScratchRepo, sql, params)

  defp query_value(sql, params) do
    %{rows: [[value]]} = execute(sql, params)
    value
  end

  defp now, do: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

  defp uuid, do: Ecto.UUID.dump!(Ecto.UUID.generate())

  defp uuid_param(value), do: Ecto.UUID.dump!(value)
end
