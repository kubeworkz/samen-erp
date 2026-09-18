defmodule Samen.Scopes.Finance.TaxCalculator do
  @moduledoc """
  Tax calculation for invoice/bill line items (WS-ERP E12).

  Computes the tax amount for a line item given a tax rate. The calculation:

      tax_amount = round(taxable_amount * rate / 100)

  where `rate` is a percentage string (e.g., "8.25" for 8.25%).

  ## Design

  - Tax is computed on the line's `amount_cents` (the pre-tax amount)
  - The result is stored as `tax_amount_cents` (integer cents)
  - The total line amount = `amount_cents + tax_amount_cents`
  - Tax rates are applied per-line, not per-invoice (more granular)

  ## Fail-closed invariant

  If a tax rate is referenced but not found, the calculation returns
  `{:error, :rate_not_found}`. The caller must refuse the posting.

  ## Same-currency only

  Tax calculation is in the transaction's currency. Multi-currency tax
  is handled by the FX layer (E10) at the total level, not the tax level.
  """

  @doc """
  Calculate tax for a line item.

  Returns `{:ok, %{tax_amount_cents: int, tax_rate_id: uuid, rate_string: String.t()}}`.
  """
  def calculate(amount_cents, tax_rate_id, opts) do
    repo = Keyword.fetch!(opts, :repo)
    rate_resource = Keyword.get(opts, :rate_resource)

    if is_nil(repo) or is_nil(rate_resource) do
      {:error, :rate_not_found}
    else
      table = AshPostgres.DataLayer.Info.table(rate_resource)

    sql = """
    SELECT id, rate FROM #{table}
    WHERE id = $1 AND is_active = true
    """

    case repo.query(sql, [dump_uuid(tax_rate_id)]) do
      {:ok, %{rows: [[id, rate_string]]}} ->
        rate = parse_rate(rate_string)
        tax_amount = round(amount_cents * rate / 100)

        {:ok,
         %{
           tax_amount_cents: tax_amount,
           tax_rate_id: id,
           rate_string: rate_string
         }}

      {:ok, %{rows: []}} ->
        {:error, :rate_not_found}

      {:error, _} ->
        {:error, :rate_not_found}
      end
    end
  end

  @doc """
  Calculate tax for a batch of line items.

  Returns `{:ok, [line_with_tax]}` or `{:error, reason}`.
  """
  def calculate_batch(lines, opts) do
    Enum.reduce_while(lines, {:ok, []}, fn line, {:ok, acc} ->
      case calculate(line.amount_cents, line.tax_rate_id, opts) do
        {:ok, tax} ->
          {:cont, {:ok, [Map.merge(line, tax) | acc]}}

        {:error, reason} ->
          {:halt, {:error, {:tax_calculation_failed, line, reason}}}
      end
    end)
    |> case do
      {:ok, results} -> {:ok, Enum.reverse(results)}
      error -> error
    end
  end

  @doc """
  Calculate total tax for an invoice/bill.

  Returns `{:ok, %{subtotal_cents: int, tax_cents: int, total_cents: int}}`.
  """
  def total(lines, opts) do
    case calculate_batch(lines, opts) do
      {:ok, taxed_lines} ->
        subtotal = Enum.reduce(taxed_lines, 0, fn l, acc -> acc + l.amount_cents end)
        tax = Enum.reduce(taxed_lines, 0, fn l, acc -> acc + l.tax_amount_cents end)

        {:ok,
         %{
           subtotal_cents: subtotal,
           tax_cents: tax,
           total_cents: subtotal + tax
         }}

      error ->
        error
    end
  end

  defp parse_rate(rate_string) do
    case Decimal.parse(rate_string) do
      {decimal, _} -> Decimal.to_float(decimal)
      :error -> raise ArgumentError, "Invalid tax rate: #{rate_string}"
    end
  end

  defp dump_uuid(nil), do: nil
  defp dump_uuid(id), do: Ecto.UUID.dump!(id)
end
