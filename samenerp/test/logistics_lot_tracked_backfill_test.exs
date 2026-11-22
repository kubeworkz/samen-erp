defmodule Samenerp.LogisticsLotTrackedBackfillTest do
  @moduledoc """
  The L1 backfill gate: seed an existing Item with a Lot and a control Item
  without one BEFORE the L1 logistics migration, then apply only that
  migration and assert the physical `eni_item.eni_lot_tracked` state and its
  catalog row.
  """

  use ExUnit.Case, async: false

  # Ecto.Migrator reads this source DIRECTORY, so a patched source migration is
  # the one that executes — never a stale priv copy under `_build`.
  @migrations Path.expand("../priv/repo/migrations", __DIR__)
  @l1_migration Path.join(@migrations, "20261122120000_mount_inventory_logistics.exs")
  @l1_version 20_261_122_120_000
  @lot_item_id Ecto.UUID.generate()
  @plain_item_id Ecto.UUID.generate()

  defmodule ScratchRepo do
    use Ecto.Repo, otp_app: :samenerp, adapter: Ecto.Adapters.Postgres
  end

  setup_all do
    assert File.regular?(@l1_migration),
           "the L1 backfill test must load the source migration from #{@migrations}"

    config =
      Samenerp.Repo.config()
      |> Keyword.delete(:pool)
      |> Keyword.put(
        :database,
        "samenerp_logistics_backfill_#{System.unique_integer([:positive])}"
      )
      |> Keyword.put(:pool, DBConnection.ConnectionPool)
      |> Keyword.put(:pool_size, 3)

    :ok = Samen.TestDb.ensure_up!(config)
    {:ok, _} = ScratchRepo.start_link(config)

    previous = Code.get_compiler_option(:ignore_module_conflict)
    Code.put_compiler_option(:ignore_module_conflict, true)

    try do
      # Bring the host schema through the migration IMMEDIATELY BEFORE L1.
      Ecto.Migrator.run(ScratchRepo, @migrations, :up, to: @l1_version - 1, log: false)
      seed_items_and_lot()

      Ecto.Migrator.run(ScratchRepo, @migrations, :up, to: @l1_version, log: false)
    after
      Code.put_compiler_option(:ignore_module_conflict, previous || false)
    end

    on_exit(fn ->
      if Process.whereis(ScratchRepo), do: Supervisor.stop(ScratchRepo)
      _ = Ecto.Adapters.Postgres.storage_down(config)
      :ok
    end)

    :ok
  end

  test "the L1 migration backfills Item.lot_tracked from existing Lot rows" do
    assert query_value(
             "SELECT eni_lot_tracked FROM eni_item WHERE eni_id = $1",
             [uuid_param(@lot_item_id)]
           ) == true

    assert query_value(
             "SELECT eni_lot_tracked FROM eni_item WHERE eni_id = $1",
             [uuid_param(@plain_item_id)]
           ) == false

    assert query_value(
             "SELECT fld_type FROM fld_field WHERE fld_table_name = 'eni_item' AND fld_column_name = 'eni_lot_tracked'",
             []
           ) == "Boolean"

    assert query_value(
             "SELECT data_type FROM information_schema.columns WHERE table_name = 'eni_item' AND column_name = 'eni_lot_tracked'",
             []
           ) == "boolean"
  end

  defp seed_items_and_lot do
    org_id = uuid()
    cost_object_id = uuid()

    execute(
      """
      INSERT INTO eco_cost_object
        (eco_id, eco_org_id, eco_code, eco_name, eco_kind, eco_inserted_at, eco_updated_at)
      VALUES ($1, $2, $3, $4, $5, $6, $6)
      """,
      [cost_object_id, org_id, "L1-BACKFILL", "L1 backfill cost object", "project", now()]
    )

    for {id, sku} <- [{@lot_item_id, "L1-LOT"}, {@plain_item_id, "L1-PLAIN"}] do
      execute(
        """
        INSERT INTO eni_item
          (eni_id, eni_org_id, eni_sku, eni_name, eni_kind, eni_uom, eni_inserted_at, eni_updated_at)
        VALUES ($1, $2, $3, $4, 'stocked', 'unit', $5, $5)
        """,
        [uuid_param(id), org_id, sku, sku, now()]
      )
    end

    execute(
      """
      INSERT INTO elt_lot
        (elt_id, elt_org_id, elt_code, elt_stage, elt_wafer_count, elt_die_expected,
         elt_die_actual, elt_item_id, elt_cost_object_id, elt_inserted_at, elt_updated_at)
      VALUES ($1, $2, $3, 'design', 0, 0, 0, $4, $5, $6, $6)
      """,
      [uuid(), org_id, "L1-LOT-1", uuid_param(@lot_item_id), cost_object_id, now()]
    )
  end

  defp execute(sql, params), do: Ecto.Adapters.SQL.query!(ScratchRepo, sql, params)

  defp query_value(sql, params) do
    %{rows: [[value]]} = execute(sql, params)
    value
  end

  defp now, do: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

  defp uuid, do: Ecto.UUID.dump!(Ecto.UUID.generate())

  defp uuid_param(value), do: Ecto.UUID.dump!(value)
end
