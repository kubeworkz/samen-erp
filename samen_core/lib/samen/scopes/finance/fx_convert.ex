defmodule Samen.Scopes.Finance.FxConvert do
  @moduledoc """
  Currency conversion using stored exchange rates (WS-ERP E10).

  Converts amounts between currencies using historical rates from the
  `ExchangeRate` table. The conversion is:

      converted = amount * rate

  where `rate` is the rate from `from_currency` → `to_currency` at the
  given timestamp.

  ## Fail-closed invariant

  If no rate is stored for the requested pair at the requested time,
  the conversion returns `{:error, :rate_not_found}`. The caller
  (typically `FxConversionGuard`) must refuse the posting.

  ## Same-currency shortcut

  If `from_currency == to_currency`, the amount is returned as-is with
  rate "1.0" — no lookup needed.

  ## Rate lookup strategy

  1. Exact match: (from, to, at-or-before timestamp)
  2. Most recent rate for the pair (any timestamp) — fallback for
     stale rates with a warning
  3. No match → `{:error, :rate_not_found}`
  """

  @doc """
  Convert an amount from one currency to another at a given timestamp.

  Returns `{:ok, {converted_cents, rate_string}}` or
  `{:error, :rate_not_found}`.
  """
  def convert(amount_cents, from_currency, to_currency, valid_at, opts) do
    repo = Keyword.fetch!(opts, :repo)
    rate_resource = Keyword.fetch!(opts, :rate_resource)

    if from_currency == to_currency do
      {:ok, {amount_cents, "1.0"}}
    else
      if is_nil(repo) or is_nil(rate_resource) do
        {:error, :rate_not_found}
      else
        case find_rate(rate_resource, repo, from_currency, to_currency, valid_at) do
        {:ok, rate_string} ->
          rate = parse_rate(rate_string)
          converted = round(amount_cents * rate)
          {:ok, {converted, rate_string}}

        {:error, :rate_not_found} ->
          {:error, :rate_not_found}
        end
      end
    end
  end

  @doc """
  Convert and return the base-currency equivalent for a batch of amounts.
  Useful for reports that need to aggregate across currencies.
  """
  def convert_batch(items, base_currency, valid_at, opts) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case convert(item.amount_cents, item.currency, base_currency, valid_at, opts) do
        {:ok, {converted, rate}} ->
          {:cont, {:ok, [Map.merge(item, %{base_amount_cents: converted, fx_rate: rate}) | acc]}}

        {:error, :rate_not_found} ->
          {:halt, {:error, {:rate_not_found, item.currency}}}
      end
    end)
    |> case do
      {:ok, results} -> {:ok, Enum.reverse(results)}
      error -> error
    end
  end

  defp find_rate(resource, repo, from_currency, to_currency, valid_at) do
    table = AshPostgres.DataLayer.Info.table(resource)

    # Try exact match: rate valid at or before the requested timestamp
    sql = """
    SELECT rate FROM #{table}
    WHERE from_currency = $1 AND to_currency = $2 AND valid_at <= $3
    ORDER BY valid_at DESC
    LIMIT 1
    """

    case repo.query(sql, [from_currency, to_currency, valid_at]) do
      {:ok, %{rows: [[rate]]}} ->
        {:ok, rate}

      {:ok, %{rows: []}} ->
        # Fallback: most recent rate for the pair (any time)
        fallback_sql = """
        SELECT rate FROM #{table}
        WHERE from_currency = $1 AND to_currency = $2
        ORDER BY valid_at DESC
        LIMIT 1
        """

        case repo.query(fallback_sql, [from_currency, to_currency]) do
          {:ok, %{rows: [[rate]]}} -> {:ok, rate}
          {:ok, %{rows: []}} -> {:error, :rate_not_found}
          {:error, _} -> {:error, :rate_not_found}
        end

      {:error, _} ->
        {:error, :rate_not_found}
    end
  end

  defp parse_rate(rate_string) do
    case Decimal.parse(rate_string) do
      {decimal, _} -> Decimal.to_float(decimal)
      :error -> raise ArgumentError, "Invalid rate: #{rate_string}"
    end
  end
end
