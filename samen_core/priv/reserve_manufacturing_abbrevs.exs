# Bootstrap helper (E6): reserve the four Manufacturing abbrevs through the
# SANCTIONED allocator — never by hand (ADR-023). Run like:
#
#   cd samen_core
#   elixir -S mix run priv/reserve_manufacturing_abbrevs.exs
#
# The direct Allocator.reserve!/5 route (idempotent): sequential mix-task runs
# clobber the build-tree registry (each compile re-copies priv/ over the build
# mirror), so the reservations are applied to BOTH the source registry and the
# current build-tree copy. Delete this script after the run — the reservations
# are permanent and the registry is the record.
defmodule ReserveE6 do
  def run do
    {:ok, _} = Application.ensure_all_started(:samen_core)

    reservations = [
      {"sbm", "SamenCore.Support.InventoryFixture.Bom"},
      {"sbl", "SamenCore.Support.InventoryFixture.BomLine"},
      {"swk", "SamenCore.Support.InventoryFixture.WorkOrder"},
      {"spg", "SamenCore.Support.InventoryFixture.ProductionLog"}
    ]

    Enum.each(reservations, fn {abbrev, owner} ->
      :ok =
        Samen.Abbrev.Allocator.reserve!(
          "samen_core",
          abbrev,
          owner,
          Samen.AbbrevRegistry.path(),
          []
        )

      IO.puts("reserved #{abbrev} -> #{owner}")
    end)

    # Mirror the reservations into the build-tree copy so the NEXT compile of
    # the fixture resources (which validates against :code.priv_dir) passes.
    src = File.read!(Samen.AbbrevRegistry.path())

    build_copy =
      Path.join(:code.priv_dir(:samen_core) |> to_string(), "abbrev_registry.json")

    File.write!(build_copy, src)

    IO.puts("mirrored into #{build_copy} (#{byte_size(src)} bytes)")
  end
end

ReserveE6.run()
