defmodule Samen.Scopes.Finance.ApFx do
  @moduledoc """
  Functional-currency resolution for AP documents.

  An AP bill stores its vendor-facing `currency` and, at approval, the
  `base_currency`, the rate used (`exchange_rate`) and the functional
  `base_total_cents` that the liability was posted at. Payment uses those
  facts to settle the liability and to book the realized difference when the
  payment-date rate differs from the approval-date rate.

  Rates are looked up strictly at or before the requested date. There is no
  "most recent future rate" fallback: an FX posting never uses a rate the
  business could not have known on that date. Missing rates fail closed.
  """

  require Ash.Query

  @default_base "USD"
  @currency ~r/\A[A-Z]{3}\z/

  @doc "The org's functional currency, or USD when no settings row exists."
  @spec base_currency(module() | nil, String.t() | nil) :: String.t()
  def base_currency(nil, _org_id), do: @default_base

  def base_currency(settings_module, org_id) when is_atom(settings_module) do
    if is_binary(org_id) do
      case settings_module
           |> Ash.Query.filter(org_id == ^org_id)
           |> Ash.read_one(authorize?: false) do
        {:ok, %{base_currency: currency}} when is_binary(currency) ->
          normalize_currency(currency) || @default_base

        _ ->
          @default_base
      end
    else
      @default_base
    end
  end

  def base_currency(_settings_module, _org_id), do: @default_base

  @doc """
  Convert `amount_cents` from `from` to `to` at `at`.

  Returns `{:ok, {converted_cents, rate_string}}` or
  `{:error, :rate_not_found}`. Same-currency conversion is an identity and
  needs no rate row.
  """
  @spec convert(
          integer(),
          String.t(),
          String.t(),
          Date.t() | DateTime.t(),
          String.t() | nil,
          module(),
          module()
        ) :: {:ok, {integer(), String.t()}} | {:error, :rate_not_found}
  def convert(amount, from, to, at, org_id, repo, rate_resource)
      when is_integer(amount) and is_binary(from) and is_binary(to) do
    from = normalize_currency(from)
    to = normalize_currency(to)

    cond do
      is_nil(from) or is_nil(to) or is_nil(org_id) or is_nil(repo) or is_nil(rate_resource) ->
        {:error, :rate_not_found}

      from == to ->
        {:ok, {amount, "1.0"}}

      true ->
        at = at_datetime(at)

        case find_rate(rate_resource, org_id, from, to, at) do
          {:ok, rate_string, rate} ->
            {:ok, {round(amount * rate), rate_string}}

          {:error, :rate_not_found} ->
            {:error, :rate_not_found}
        end
    end
  end

  def convert(_amount, _from, _to, _at, _org_id, _repo, _rate_resource),
    do: {:error, :rate_not_found}

  @doc """
  Scale bill lines by `rate`, assigning any rounding residual to the last line
  so the converted lines sum exactly to `base_total`.
  """
  @spec convert_lines([map()], String.t(), integer()) ::
          {:ok, [map()]} | {:error, :rounding}
  def convert_lines(lines, rate_string, base_total) when is_list(lines) do
    case parse_rate(rate_string) do
      {:ok, rate} ->
        converted =
          Enum.map(lines, fn line ->
            Map.put(line, :amount_cents, round(line_amount(line) * rate))
          end)

        residual = base_total - Enum.sum(Enum.map(converted, &line_amount/1))

        case List.pop_at(converted, -1) do
          {nil, _rest} ->
            {:error, :rounding}

          {last, rest} ->
            amount = line_amount(last) + residual

            if amount > 0 do
              {:ok, rest ++ [Map.put(last, :amount_cents, amount)]}
            else
              {:error, :rounding}
            end
        end

      {:error, _} ->
        {:error, :rounding}
    end
  end

  def convert_lines(_lines, _rate, _base_total), do: {:error, :rounding}

  @doc "Normalize an ISO-4217 code; returns nil when the input is not valid."
  @spec normalize_currency(term()) :: String.t() | nil
  def normalize_currency(value) when is_binary(value) do
    value = value |> String.trim() |> String.upcase()
    if Regex.match?(@currency, value), do: value
  end

  def normalize_currency(_value), do: nil

  defp find_rate(resource, org_id, from, to, at) do
    case read_rate(resource, org_id, from, to, at) do
      {:ok, rate_string} ->
        case parse_rate(rate_string) do
          {:ok, rate} -> {:ok, rate_string, rate}
          {:error, _} -> {:error, :rate_not_found}
        end

      {:error, :rate_not_found} ->
        case read_rate(resource, org_id, to, from, at) do
          {:ok, inverse_string} ->
            case parse_rate(inverse_string) do
              {:ok, rate} when rate > 0 ->
                inverse = 1.0 / rate
                {:ok, Float.to_string(inverse), inverse}

              _ ->
                {:error, :rate_not_found}
            end

          {:error, _} ->
            {:error, :rate_not_found}
        end
    end
  end

  defp read_rate(resource, org_id, from, to, at) do
    resource
    |> Ash.Query.filter(
      org_id == ^org_id and from_currency == ^from and to_currency == ^to and valid_at <= ^at
    )
    |> Ash.Query.sort(valid_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, %{rate: rate}} when is_binary(rate) -> {:ok, rate}
      _ -> {:error, :rate_not_found}
    end
  end

  defp parse_rate(rate) when is_binary(rate) do
    case Decimal.parse(rate) do
      {decimal, ""} -> {:ok, Decimal.to_float(decimal)}
      _ -> {:error, :invalid_rate}
    end
  end

  defp parse_rate(_rate), do: {:error, :invalid_rate}

  defp at_datetime(%DateTime{} = datetime), do: datetime

  defp at_datetime(%Date{} = date) do
    DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
  end

  defp at_datetime(_other), do: DateTime.utc_now()

  defp line_amount(line) when is_map(line) do
    Map.get(line, :amount_cents) || Map.get(line, "amount_cents") || 0
  end
end
