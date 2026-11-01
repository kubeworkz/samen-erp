defmodule Samen.Scopes.Finance.VarianceMath do
  @moduledoc """
  The standard-cost variance arithmetic (WS-ACCT Phase 7; ADR-054 D4, R8).

  One pure module computes all seven of the manual's variance classes from a
  standard card plus the period's declared actuals, so the **engine** and the
  **R8 read** can never disagree about what a variance *is*: the engine posts
  the number this module returns, and `Samen.Scopes.Finance.ReconcileVariance`
  recomputes the same number from the row's own recorded inputs to prove the
  posting still ties to the card. A second implementation in the read would be
  a second truth — exactly what the reconciliation spine exists to prevent.

  ## The card

  A `CostStandard` is one output item's standard, effective from a date, per
  cost object. Its lines are per element:

    * `:material` — `standard_qty` per GOOD output unit at 100 % yield, priced
      at `standard_unit_price_cents`; `expected_yield_bp` scales the input the
      good units are allowed (8_500 = 85.00 %); `usage_basis` says which usage
      variance the line feeds (`:yield`, `:bom`, or `:none` for price-only);
    * `:labor` — `standard_qty` = standard labour MINUTES per output unit,
      `standard_unit_price_cents` = cents per minute;
    * `:overhead` — the same two fields, as the standard absorption base and
      rate (minutes, cents per minute).

  Minutes and base-UOM quantities are integers, and every rate is cents per
  integer unit, so every variance is integer-exact. Basis points for yield are
  the integer form of a percentage; `ceil_div/2` is used only where a
  *fractional* allowed input must round UP (rounding down would silently grant
  free material).

  ## The seven classes (signed: positive = UNFAVOURABLE, actual > standard)

  | type | actual | standard |
  |---|---|---|
  | `:ppv` | Σ actual price × actual qty | Σ standard price × actual qty |
  | `:yield` | Σ standard price × actual qty | Σ standard price × allowed qty |
  | `:bom` | Σ standard price × actual qty | Σ standard price × allowed qty |
  | `:labor_rate` | Σ actual rate × actual minutes | Σ standard rate × actual minutes |
  | `:labor_efficiency` | Σ standard rate × actual minutes | Σ standard rate × allowed minutes |
  | `:overhead_spending` | Σ actual rate × actual minutes | Σ standard rate × actual minutes |
  | `:overhead_volume` | Σ standard rate × actual minutes | Σ standard rate × allowed minutes |

  `allowed` is `output_units × standard_qty` (BOM, labour, overhead) or, for a
  yield line, `ceil(output_units × standard_qty × 10_000 / expected_yield_bp)`.
  The two overhead legs sum to actual − applied, the classic flexible-budget
  split; the labour pair is the same decomposition. Yield and BOM are the two
  bases of the material usage variance: a yield line's allowance is
  yield-scaled, a BOM line's is structural (its `expected_yield_bp` must be
  100 %). A material line with `usage_basis: :none` feeds price variance only.

  ## Inputs are strict, fail-honest

  `normalize/2` refuses an actual for a line the card does not have
  (`:unknown_actual_line`), a card line with no actual
  (`:missing_actual_line`), a negative quantity or price, and a non-integer
  value. A cost the period did not report cannot be priced, and silently
  treating it as zero would post a variance built on a guess.
  """

  @types [
    :ppv,
    :yield,
    :bom,
    :labor_rate,
    :labor_efficiency,
    :overhead_spending,
    :overhead_volume
  ]

  @doc "The seven variance classes, in report order."
  def types, do: @types

  @doc """
  Validate and normalize the period's declared actuals against the card.

  Accepts the card's line structs (any map with `:id`, `:element`,
  `:usage_basis`) and the action's `actuals` map:

      %{
        "output_units" => 880,
        "lines" => %{
          "<standard line id>" => %{"qty" => 1000, "unit_price_cents" => 305_000}
        }
      }

  Returns `{:ok, normalized}` with string keys only (the shape stored on the
  variance row), or `{:error, {:missing_actual_line, id}}` /
  `{:error, {:unknown_actual_line, id}}` / `{:error, {:invalid_actual, field}}`.
  """
  def normalize(card_lines, actuals) do
    with {:ok, output_units} <- fetch_non_neg_int(actuals, "output_units"),
         {:ok, raw_lines} <- fetch_lines(actuals),
         :ok <- reject_unknown(raw_lines, card_lines),
         {:ok, lines} <- collect(card_lines, raw_lines) do
      {:ok, %{"output_units" => output_units, "lines" => lines}}
    end
  end

  @doc """
  The `{actual_cents, standard_cents}` pair for one variance `type`, from the
  card's lines and the normalized inputs.

  Returns `{:ok, {actual, standard}}` — both integers, and their difference is
  the variance. A type with no participating line is `{:ok, {0, 0}}`; `plan/2`
  marks it `measured?: false` so the engine records NOTHING for it (a card with
  no labour does not have a labour variance of zero — it has none), while a
  measured class that happens to net to zero IS recorded as a fact.
  """
  def amount(type, card_lines, normalized) when type in @types do
    with {:ok, output_units} <- fetch_non_neg_int(normalized, "output_units"),
         {:ok, raw_lines} <- fetch_lines(normalized) do
      participating = Enum.filter(card_lines, &participates?(type, &1))

      # A recompute (R8) may read a card whose line set no longer matches the
      # row's recorded inputs: that is an UNTIED row, not a crash. Check before
      # the arithmetic so `line_amount/4` can fetch safely.
      case Enum.find(participating, &(not Map.has_key?(raw_lines, to_string(&1.id)))) do
        nil ->
          {:ok,
           Enum.reduce(participating, {0, 0}, fn line, {a, s} ->
             {la, ls} = line_amount(type, line, output_units, raw_lines)
             {a + la, s + ls}
           end)}

        line ->
          {:error, {:missing_actual_line, to_string(line.id)}}
      end
    end
  end

  @doc """
  Plan all seven classes: a list of specs, one per class.

  Each spec carries `measured?:` — whether the card has any line that feeds the
  class. A measured class with a zero difference is a FACT (the period was
  priced and the variance was nil) and is recorded; an unmeasured class (a card
  with no labour) is not.
  """
  def plan(card_lines, normalized) do
    Enum.map(@types, fn type ->
      {:ok, {actual, standard}} = amount(type, card_lines, normalized)

      %{
        type: type,
        measured?: Enum.any?(card_lines, &participates?(type, &1)),
        actual_amount_cents: actual,
        standard_amount_cents: standard,
        amount_cents: actual - standard,
        inputs: normalized
      }
    end)
  end

  @doc """
  Recompute one class for a variance ROW from its stored inputs — the R8 tie
  check. Returns `{:ok, {actual, standard}}` or an error when the inputs no
  longer name lines the card carries.
  """
  def recompute(type, card_lines, normalized) when type in @types do
    amount(type, card_lines, normalized)
  end

  # ── per-line arithmetic ────────────────────────────────────────────────────

  defp line_amount(:ppv, line, _output, lines) do
    {qty, price} = actual(lines, line)

    {price * qty, line.standard_unit_price_cents * qty}
  end

  defp line_amount(:yield, line, output, lines) do
    {qty, _price} = actual(lines, line)
    allowed = allowed_quantity(line, output)

    {line.standard_unit_price_cents * qty, line.standard_unit_price_cents * allowed}
  end

  defp line_amount(:bom, line, output, lines) do
    {qty, _price} = actual(lines, line)
    allowed = allowed_quantity(line, output)

    {line.standard_unit_price_cents * qty, line.standard_unit_price_cents * allowed}
  end

  defp line_amount(:labor_rate, line, _output, lines) do
    {minutes, rate} = actual(lines, line)

    {rate * minutes, line.standard_unit_price_cents * minutes}
  end

  defp line_amount(:labor_efficiency, line, output, lines) do
    {minutes, _rate} = actual(lines, line)
    allowed = allowed_quantity(line, output)

    {line.standard_unit_price_cents * minutes, line.standard_unit_price_cents * allowed}
  end

  defp line_amount(:overhead_spending, line, _output, lines) do
    {minutes, rate} = actual(lines, line)

    {rate * minutes, line.standard_unit_price_cents * minutes}
  end

  defp line_amount(:overhead_volume, line, output, lines) do
    {minutes, _rate} = actual(lines, line)
    allowed = allowed_quantity(line, output)

    {line.standard_unit_price_cents * minutes, line.standard_unit_price_cents * allowed}
  end

  defp participates?(:ppv, line), do: line.element == :material
  defp participates?(:yield, line), do: line.element == :material and line.usage_basis == :yield
  defp participates?(:bom, line), do: line.element == :material and line.usage_basis == :bom
  defp participates?(:labor_rate, line), do: line.element == :labor
  defp participates?(:labor_efficiency, line), do: line.element == :labor
  defp participates?(:overhead_spending, line), do: line.element == :overhead
  defp participates?(:overhead_volume, line), do: line.element == :overhead

  @doc """
  The input quantity a card line ALLOWS for `output_units` good units: the
  yield-scaled allowance for a `:yield` material line, the structural
  `output × standard_qty` otherwise. Public because the cost-of-yield read must
  value the good units with the same rule the variance engine used.
  """
  def allowed_quantity(line, output_units) do
    if line.element == :material and line.usage_basis == :yield do
      ceil_div(output_units * line.standard_qty * 10_000, line.expected_yield_bp)
    else
      output_units * line.standard_qty
    end
  end

  defp ceil_div(numerator, denominator) do
    div(numerator + denominator - 1, denominator)
  end

  defp actual(lines, line) do
    row = Map.fetch!(lines, to_string(line.id))

    {row["qty"], row["unit_price_cents"]}
  end

  # ── normalization helpers ──────────────────────────────────────────────────

  defp fetch_non_neg_int(map, key) do
    case fetch(map, key) do
      value when is_integer(value) and value >= 0 -> {:ok, value}
      _ -> {:error, {:invalid_actual, key}}
    end
  end

  defp fetch_lines(map) do
    case fetch(map, "lines") do
      lines when is_map(lines) -> {:ok, lines}
      _ -> {:error, {:invalid_actual, "lines"}}
    end
  end

  defp fetch(map, key), do: Map.get(map, key) || Map.get(map, String.to_atom(key))

  defp reject_unknown(raw_lines, card_lines) do
    known = MapSet.new(card_lines, &to_string(&1.id))

    case Enum.find(Map.keys(raw_lines), &(not MapSet.member?(known, to_string(&1)))) do
      nil -> :ok
      id -> {:error, {:unknown_actual_line, to_string(id)}}
    end
  end

  defp collect(card_lines, raw_lines) do
    Enum.reduce_while(card_lines, {:ok, %{}}, fn line, {:ok, acc} ->
      id = to_string(line.id)

      with {:ok, raw} <- Map.fetch(raw_lines, id),
           {:ok, qty} <- actual_int(raw, "qty"),
           {:ok, price} <- actual_int(raw, "unit_price_cents") do
        {:cont, {:ok, Map.put(acc, id, %{"qty" => qty, "unit_price_cents" => price})}}
      else
        :error -> {:halt, {:error, {:missing_actual_line, id}}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp actual_int(row, key) when is_map(row), do: fetch_non_neg_int(row, key)
  defp actual_int(_row, key), do: {:error, {:invalid_actual, key}}
end
