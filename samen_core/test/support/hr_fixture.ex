defmodule SamenCore.Support.HrFixture do
  @moduledoc """
  Kernel test-fixture domain mounting the **HR** scope (WS-ERP E7; design §5)
  inside `samen_core`'s own test suite — the Finance/Inventory fixture shape
  (mirrors `test/support/finance_fixture.ex`).

  Fresh abbrevs (`hem`/`hev`/`hlv`) — the scope's demo defaults stay unclaimed
  until the first real host mount (ADR-004/ADR-023 discipline; the in-tree
  fixture is a distinct owner under the `samen_core` host namespace). The
  registry rows are written by the SANCTIONED allocator (never by hand —
  ADR-023); on the Elixir box, before the first compile of a NEW fixture
  resource, run the bootstrap script (the direct Allocator.reserve!/5 route):

      cd samen_core
      elixir -S mix run priv/reserve_hr_abbrevs.exs

  then update the `samen_core` golden literals in `test/abbrev_registry_test.exs`,
  `test/abbrev_allocator_test.exs`, and `test/abbrev_flatten_conflict_test.exs`
  (the new `map_size`; the allocator-emitted `byte_size` recomputes from the
  actual file).

  ## The PII posture (INV-1, non-empty for the first time in WS-ERP)

  `Employee` carries the scope's ONLY vault-routed fields (`full_name` /
  `work_emails` / `work_phones` composites + the scalar `dob`). The fixture
  domain is deliberately NOT in `:ash_domains` (like every other fixture), so
  `vault_declared_parity` cannot discover the routes — the pairs are
  allow-listed in `config/test.exs` (the sx*/asj*/apd* posture). The masking
  red-paths prove per-plane resolution is REAL against these rows.

  Deliberately NOT in `:ash_domains` (like every other fixture here).
  """
  use Ash.Domain, validate_config_inclusion?: false

  use Samen.Scopes.Hr,
    otp_app: :samen_core,
    repo: SamenCore.TestRepo,
    namespace: SamenCore.Support.HrFixture,
    abbrevs: %{
      employee: "hem",
      employment_event: "hev",
      leave_request: "hlv"
    }
end
