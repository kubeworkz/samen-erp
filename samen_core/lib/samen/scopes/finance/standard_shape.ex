defmodule Samen.Scopes.Finance.StandardShape do
  @moduledoc """
  Cross-field shape guard for `CostStandardLine` (WS-ACCT Phase 7; ADR-054 D4).

  Three rules the per-attribute validations cannot express:

    * a `:material` line names the item it standardizes (`item_id`), because
      "material at 3 000 cents per unit" without saying per unit of WHAT is not
      a standard;
    * `:labor` and `:overhead` lines carry no `item_id` and must be
      `usage_basis: :none` — their usage variance is efficiency/volume, not
      yield or BOM, and a labour line tagged `:bom` would silently feed the
      board's BOM variance;
    * a `:bom` line's allowance is structural, so its `expected_yield_bp` must
      be 100 % — a yield-scaled BOM allowance would make the BOM variance
      depend on scrap, which is the yield variance's job.

  Fail-closed: any violation adds an error to the changeset and the line does
  not land.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    element = Ash.Changeset.get_attribute(changeset, :element)
    item_id = Ash.Changeset.get_attribute(changeset, :item_id)
    usage = Ash.Changeset.get_attribute(changeset, :usage_basis)
    yield_bp = Ash.Changeset.get_attribute(changeset, :expected_yield_bp)

    changeset
    |> check(
      element == :material and is_nil(item_id),
      "a material standard line must name the item it standardizes"
    )
    |> check(
      element in [:labor, :overhead] and not is_nil(item_id),
      "a #{element} standard line carries no item (its standard is minutes and a rate)"
    )
    |> check(
      element in [:labor, :overhead] and usage != :none,
      "a #{element} standard line must be usage_basis :none — its usage variance is " <>
        "efficiency/volume, not yield or BOM"
    )
    |> check(
      usage == :bom and yield_bp != 10_000,
      "a :bom standard line's expected yield must be 100 % — a yield-scaled BOM allowance " <>
        "would fold scrap into the BOM variance"
    )
  end

  defp check(changeset, false, _message), do: changeset

  defp check(changeset, true, message) do
    Ash.Changeset.add_error(changeset, field: :base, message: message)
  end
end
