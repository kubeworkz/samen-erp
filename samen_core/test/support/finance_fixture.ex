defmodule SamenCore.Support.FinanceFixture do
  @moduledoc """
  Kernel test-fixture domain mounting the **Finance** scope (WS-ERP E1; ADR-049
  §2) inside `samen_core`'s own test suite — mirrors
  `test/support/work_fixture.ex` (the Work scope's in-tree pilot).

  Fresh abbrevs (`sac`/`sje`/`sjl`) — the scope's demo defaults (`fca`/`fje`/
  `fjl`) stay unclaimed until the first real host mount (ADR-004/ADR-023
  discipline; the in-tree fixture is a distinct owner under the `samen_core`
  host namespace). The registry rows are written by the SANCTIONED allocator
  (never by hand — ADR-023); on the Elixir box, before the first compile of
  this fixture:

      cd samen_core
      mix samen.abbrev.reserve --host samen_core \
        --owner SamenCore.Support.FinanceFixture.Account --abbrev sac
      mix samen.abbrev.reserve --host samen_core \
        --owner SamenCore.Support.FinanceFixture.JournalEntry --abbrev sje
      mix samen.abbrev.reserve --host samen_core \
        --owner SamenCore.Support.FinanceFixture.JournalLine --abbrev sjl

  then update the `samen_core` golden literals in `test/abbrev_registry_test.exs`
  (`map_size == 445`), `test/abbrev_allocator_test.exs` (`map_size == 445` + the
  allocator-emitted `byte_size`), and `test/abbrev_flatten_conflict_test.exs`
  (`map_size == 445`) — all three are already updated here.
  """
  use Ash.Domain, validate_config_inclusion?: false

  use Samen.Scopes.Finance,
    otp_app: :samen_core,
    repo: SamenCore.TestRepo,
    namespace: SamenCore.Support.FinanceFixture,
    abbrevs: %{account: "sac", journal_entry: "sje", journal_line: "sjl"}
end
