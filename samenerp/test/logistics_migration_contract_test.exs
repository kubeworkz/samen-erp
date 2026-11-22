defmodule Samenerp.LogisticsMigrationContractTest do
  use ExUnit.Case, async: true

  @migrations Path.expand("../priv/repo/migrations", __DIR__)

  test "the L1 logistics migration is discovered as an :expand down-check target" do
    assert %{
             version: 20_261_122_120_000,
             name: "20261122120000_mount_inventory_logistics.exs",
             phase: :expand
           } =
             Enum.find(
               Samen.Migration.DownCheck.expand_migrations(@migrations),
               &(&1.version == 20_261_122_120_000)
             )
  end
end
