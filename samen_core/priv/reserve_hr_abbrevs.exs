# Bootstrap helper (E7): reserve the three HR abbrevs through the SANCTIONED
# allocator — never by hand (ADR-023). Run like:
#
#   cd samen_core
#   elixir -S mix run priv/reserve_hr_abbrevs.exs
#
# The direct Allocator.reserve!/5 route (idempotent: same host+abbrev+owner is
# a byte no-op; raises on a genuine collision): sequential mix-task runs
# clobber the build-tree registry (each compile re-copies priv/ over the build
# mirror), so the reservations are mirrored into the CURRENT build-tree copy
# too. Deliberately NOT committed (the registry IS the record) — same posture
# as every phase's reserve script since E1.

# NOTE: no Application.ensure_all_started — starting :samen_core boots its
# supervision tree (repo, Oban), which has no business in a bootstrap script.
# The Allocator is a pure file operation over the registry JSON; only its
# modules need to be loadable (the -pa beam path provides them).

registry_path = "priv/abbrev_registry.json"
host = "samen_core"
owner_prefix = "SamenCore.Support.HrFixture"

reservations = [
  {"hem", owner_prefix <> ".Employee"},
  {"hev", owner_prefix <> ".EmploymentEvent"},
  {"hlv", owner_prefix <> ".LeaveRequest"}
]

Enum.each(reservations, fn {abbrev, owner} ->
  :ok = Samen.Abbrev.Allocator.reserve!(host, abbrev, owner, registry_path)
  IO.puts("reserved #{abbrev} -> #{owner}")
end)

# Mirror the reservations into the CURRENT build-tree copy so the next compile
# (and the fixture's compile-time abbrev validation) sees them without a
# rebuild. NOTE: no Mix.Project.build_path/0 — this script may run via bare
# `elixir -pa ...` outside mix, where the Mix.ProjectStack is not alive.
build_registry = Path.join("_build", "dev/lib/samen_core/priv/abbrev_registry.json")

build_registry =
  if File.exists?(build_registry),
    do: build_registry,
    else: Path.join("_build", "test/lib/samen_core/priv/abbrev_registry.json")

if File.exists?(build_registry) do
  File.cp!(registry_path, build_registry)
  IO.puts("mirrored into #{build_registry}")
end

IO.puts("registry size: #{byte_size(File.read!(registry_path))} bytes")
