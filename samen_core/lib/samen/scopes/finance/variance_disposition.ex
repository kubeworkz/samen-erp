defmodule Samen.Scopes.Finance.VarianceDisposition do
  @moduledoc """
  The manual's **per-type variance disposition table, adopted verbatim**
  (WS-ACCT Phase 7; ADR-054 D4 + Ratification 2).

  A variance is not merely an arithmetic difference: the manual says where each
  one GOES, and R8 asserts each variance reaches the account its row names, not
  that the arithmetic nets. The table is binding:

  | type | disposition | account meaning | why (the manual's) |
  |---|---|---|---|
  | `:ppv` | `:write_off_cogs` | `:cogs` | non-recurring; not attributable to specific inventory |
  | `:yield` | `:absorb_inventory` | `:finished_goods_chip` | attributable to a specific production run |
  | `:bom` | `:absorb_inventory` | `:finished_goods_board` | attributable to a specific board production |
  | `:labor_rate` | `:write_off_rd` | `:rd_expense` | period cost, not inventory-related |
  | `:labor_efficiency` | `:write_off_rd` | `:rd_expense` | period cost, not inventory-related |
  | `:overhead_volume` | `:write_off_cogs` | `:cogs` | capacity-related; not product-specific |
  | `:overhead_spending` | `:write_off_rd` | `:rd_expense` | period cost |

  ## The four variance accounts, and why per-chip detail is a dimension

  ADR-054 D2 fixes **four** variance meanings (`variance_ppv`, `variance_yield`,
  `variance_labor`, `variance_overhead`), while the manual's chart carries ten
  variance rows (per type AND per chip). The books resolve that the way the
  whole ledger resolves granularity: the four family accounts hold the
  postings, the variance ROW keeps the type, and the cost object rides the
  entry's dimension (`project`/`chip`/`cost_pool`, whichever the card
  declares), so "yield variance, GPU, March" is a `GROUP BY` over the
  append-only lines — derived, never a fifth account. `:variance_yield` is the
  material-usage family and holds both `:yield` and `:bom`; their distinct
  dispositions are what keeps the two apart at the target account.

  ## Direction

  `amount_cents` is signed, positive = unfavourable (actual > standard). An
  unfavourable variance DEBITS its disposition target and CREDITS its variance
  account; a favourable one is the mirror. The variance account therefore
  carries a **credit** balance equal to Σ(actual − standard) for its family,
  which is exactly the number R8 compares the variance rows to.
  """

  @table %{
    ppv: %{
      disposition: :write_off_cogs,
      account_meaning: :cogs,
      variance_meaning: :variance_ppv,
      label: "Purchase price"
    },
    yield: %{
      disposition: :absorb_inventory,
      account_meaning: :finished_goods_chip,
      variance_meaning: :variance_yield,
      label: "Yield"
    },
    bom: %{
      disposition: :absorb_inventory,
      account_meaning: :finished_goods_board,
      variance_meaning: :variance_yield,
      label: "BOM"
    },
    labor_rate: %{
      disposition: :write_off_rd,
      account_meaning: :rd_expense,
      variance_meaning: :variance_labor,
      label: "Labour rate"
    },
    labor_efficiency: %{
      disposition: :write_off_rd,
      account_meaning: :rd_expense,
      variance_meaning: :variance_labor,
      label: "Labour efficiency"
    },
    overhead_volume: %{
      disposition: :write_off_cogs,
      account_meaning: :cogs,
      variance_meaning: :variance_overhead,
      label: "Overhead volume"
    },
    overhead_spending: %{
      disposition: :write_off_rd,
      account_meaning: :rd_expense,
      variance_meaning: :variance_overhead,
      label: "Overhead spending"
    }
  }

  @dispositions [:absorb_inventory, :write_off_cogs, :write_off_rd]

  @doc "The binding row for a variance type."
  def for_type(type), do: Map.fetch!(@table, type)

  @doc "The disposition enum."
  def dispositions, do: @dispositions

  @doc "The variance-account meaning a type posts into (its family)."
  def variance_meaning(type), do: for_type(type).variance_meaning

  @doc "The account meaning a type's disposition names."
  def account_meaning(type), do: for_type(type).account_meaning

  @doc "The disposition of a type."
  def disposition(type), do: for_type(type).disposition

  @doc "A human label for the entry memo."
  def label(type), do: for_type(type).label

  @doc "Every type, in report order."
  def types, do: Samen.Scopes.Finance.VarianceMath.types()
end
