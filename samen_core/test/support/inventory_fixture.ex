defmodule SamenCore.Support.InventoryFixture do
  @moduledoc """
  Kernel test-fixture domain mounting the **Inventory** scope (WS-ERP E3;
  ADR-049 §3) inside `samen_core`'s own test suite — the
  `FinanceFixture` shape (E1+E2) applied to stock.

  Fresh abbrevs (`sit`/`swh`/`skl`/`slv` — the scope's demo defaults
  `ini`/`inw`/`inl`/`ins` stay unclaimed until the first real host mount,
  ADR-004/ADR-023 discipline; the in-tree fixture is a distinct owner under
  the `samen_core` host namespace). The registry rows are written by the
  SANCTIONED allocator (never by hand — ADR-023); on the Elixir box, before
  the first compile of a NEW fixture resource:

      cd samen_core
      mix samen.abbrev.reserve --host samen_core \\
        --owner SamenCore.Support.InventoryFixture.Item --abbrev sit
      mix samen.abbrev.reserve --host samen_core \\
        --owner SamenCore.Support.InventoryFixture.Warehouse --abbrev swh
      mix samen.abbrev.reserve --host samen_core \\
        --owner SamenCore.Support.InventoryFixture.StockLedger --abbrev skl
      mix samen.abbrev.reserve --host samen_core \\
        --owner SamenCore.Support.InventoryFixture.StockLevel --abbrev slv

  then update the `samen_core` golden literals in `test/abbrev_registry_test.exs`,
  `test/abbrev_allocator_test.exs`, and `test/abbrev_flatten_conflict_test.exs`
  (the new `map_size`; the allocator-emitted `byte_size` recomputes from the
  actual file).
  """
  use Ash.Domain, validate_config_inclusion?: false

  use Samen.Scopes.Inventory,
    otp_app: :samen_core,
    repo: SamenCore.TestRepo,
    namespace: SamenCore.Support.InventoryFixture,
    abbrevs: %{
      item: "sit",
      warehouse: "swh",
      stock_ledger: "skl",
      stock_level: "slv"
    }
end
