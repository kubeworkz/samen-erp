defmodule Samen.Scopes.Finance.ForecastWeights do
  @moduledoc """
  The scenario-weight guard for `ForecastVersion` (WS-ACCT Phase 14; ADR-054
  D11).

  A forecast version carries exactly three scenario weights — `base`,
  `upside`, `downside` — and they must sum to 1.0. The row stores them under
  string keys because jsonb returns string keys on read; normalizing at write
  time keeps the read side from having to guess whether it is looking at atom
  or string keys.

  The refusal is a field-level Ash error, not a database CHECK: a map's
  numeric sum is not something a portable column constraint can express.
  Every entry is also bounded to `[0, 1]`; a negative or greater-than-one
  weight is not a scenario, it is a typo.
  """

  use Ash.Resource.Change

  @keys ~w(base downside upside)
  @tolerance 1.0e-6

  @impl true
  def change(changeset, _opts, _context) do
    weights = Ash.Changeset.get_attribute(changeset, :scenario_weights)

    case normalize(weights) do
      {:ok, normalized} ->
        Ash.Changeset.force_change_attribute(changeset, :scenario_weights, normalized)

      {:error, message} ->
        Ash.Changeset.add_error(changeset, field: :scenario_weights, message: message)
    end
  end

  @doc false
  def normalize(weights) when is_map(weights) do
    normalized =
      Map.new(weights, fn {key, value} ->
        {key |> to_string(), number(value)}
      end)

    cond do
      Enum.sort(Map.keys(normalized)) != @keys ->
        {:error,
         "scenario_weights must name exactly base, upside and downside " <>
           "(got #{inspect(Map.keys(normalized))})"}

      Enum.any?(normalized, fn {_key, value} -> is_nil(value) or value < 0 or value > 1 end) ->
        {:error, "every scenario weight must be a number between 0 and 1"}

      abs(Enum.sum(Map.values(normalized)) - 1.0) > @tolerance ->
        {:error,
         "scenario weights must sum to 1.0 (got #{Enum.sum(Map.values(normalized))}); " <>
           "a scenario mix that does not add to one is not a weighted forecast"}

      true ->
        {:ok, normalized}
    end
  end

  def normalize(_), do: {:error, "scenario_weights must be a map of base/upside/downside weights"}

  defp number(value) when is_integer(value), do: value * 1.0
  defp number(value) when is_float(value), do: value
  defp number(%Decimal{} = value), do: Decimal.to_float(value)
  defp number(_), do: nil
end
