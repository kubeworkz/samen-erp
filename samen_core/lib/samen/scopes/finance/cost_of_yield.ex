defmodule Samen.Scopes.Finance.CostOfYield do
  @moduledoc """
  The **cost-of-yield** read (WS-ACCT Phase 7; ADR-054 D4) — what the good units
  actually cost, and what the yield was, per cost object and period.

  Cost of yield is a DERIVED number, never stored: it is the standard cost of
  the good units plus the yield variance the period **absorbed into inventory**
  (unfavourable adds cost; favourable relieves it). That is the same arithmetic
  the disposition posted, read back from the variance row, so the dashboard and
  the ledger cannot disagree:

      coy = Σ allowed_qty(line, good_units) × standard price   (the card)
          + yield variance amount                              (the row)

      coy per unit = coy ÷ good units                          (integer cents)

  `yield_bp` is the period's realized good output per input unit, in basis
  points, taken from the actual material issued and the same `output_units`
  the run recorded: `output × 10_000 ÷ input`. Both are the card's own unit
  convention (dies per wafer, boards per panel), and `nil` when the card has no
  yield-bearing material line or nothing was issued.

  No row for a cost object in the period means the period had no yield
  variance to report — the read returns nothing for it rather than a
  zero-per-unit that would look like a measurement.
  """

  require Ash.Query

  @doc """
  The cost-of-yield entries for `{org, "YYYY-MM"}`.

  Opts (required): `:variance`, `:standard`, `:standard_line`.
  """
  def for_period(org_id, period_key, opts) do
    variance_mod = Keyword.fetch!(opts, :variance)
    standard_mod = Keyword.fetch!(opts, :standard)
    line_mod = Keyword.fetch!(opts, :standard_line)

    variance_mod
    |> Ash.Query.filter(org_id == ^org_id and period_key == ^period_key and type == :yield)
    |> Ash.read!(authorize?: false)
    |> Enum.map(fn row ->
      standard = read_standard(standard_mod, org_id, row.standard_id)
      lines = read_lines(line_mod, org_id, row.standard_id)
      output = row.inputs["output_units"] || 0

      standard_cents =
        Enum.reduce(lines, 0, fn line, acc ->
          allowed = Samen.Scopes.Finance.VarianceMath.allowed_quantity(line, output)
          acc + allowed * line.standard_unit_price_cents
        end)

      absorbed = row.amount_cents
      coy = standard_cents + absorbed
      input_units = yield_input(lines, row.inputs)

      %{
        cost_object_id: row.cost_object_id,
        standard_id: row.standard_id,
        period_key: period_key,
        good_units: output,
        standard_cents: standard_cents,
        absorbed_cents: absorbed,
        coy_cents: coy,
        coy_per_unit_cents: if(output > 0, do: div(coy, output)),
        input_units: input_units,
        yield_bp: if(input_units > 0, do: div(output * 10_000, input_units)),
        standard_code: standard && standard.code
      }
    end)
  end

  # The yield-bearing material lines' ACTUAL input, from the row's own inputs.
  defp yield_input(lines, inputs) do
    lines
    |> Enum.filter(&(&1.element == :material and &1.usage_basis == :yield))
    |> Enum.reduce(0, fn line, acc ->
      case Map.fetch(inputs["lines"] || %{}, to_string(line.id)) do
        {:ok, actual} -> acc + actual["qty"]
        :error -> acc
      end
    end)
  end

  defp read_standard(standard_mod, org_id, id) do
    standard_mod
    |> Ash.Query.filter(org_id == ^org_id and id == ^id)
    |> Ash.read_one!(authorize?: false)
  end

  defp read_lines(line_mod, org_id, standard_id) do
    line_mod
    |> Ash.Query.filter(org_id == ^org_id and standard_id == ^standard_id)
    |> Ash.read!(authorize?: false)
  end
end
