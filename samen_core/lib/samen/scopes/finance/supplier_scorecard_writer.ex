defmodule Samen.Scopes.Finance.SupplierScorecardWriter do
  @moduledoc """
  Materializes the `dimensions` argument of a `SupplierScorecard` create into
  its weighted dimension rows (WS-ACCT Phase 15; ADR-054 D18).

  The scorecard is the aggregate root: a create either lands the five
  dimensions or rolls the header back. The writer enforces the scorecard's
  arithmetic contract before inserting:

    * exactly the five closed dimensions, once each;
    * integer weights from 1 to 100 that sum to exactly 100;
    * integer scores from 1 to 5.

  The composite and grade are not written here; `SupplierGovernance` derives
  them from these rows.
  """

  use Ash.Resource.Change

  @dimensions [
    :quality_yield,
    :delivery_schedule,
    :cost_commercial,
    :technical_support,
    :compliance_sustainability
  ]

  @impl true
  def change(changeset, opts, _context) do
    dimension_mod = Keyword.fetch!(opts, :dimension)

    Ash.Changeset.after_action(changeset, fn changeset, scorecard ->
      dimensions = Ash.Changeset.get_argument(changeset, :dimensions) || []
      org_id = Ash.Changeset.get_attribute(changeset, :org_id)

      with {:ok, normalized} <- normalize(dimensions) do
        rows =
          Enum.map(normalized, fn row ->
            row
            |> Map.put(:org_id, org_id)
            |> Map.put(:scorecard_id, scorecard.id)
          end)

        case bulk_insert(dimension_mod, rows) do
          :ok ->
            {:ok, scorecard}

          {:error, reason} ->
            {:error,
             Ash.Error.Changes.InvalidAttribute.exception(
               field: :dimensions,
               message: "the scorecard dimensions failed to land: #{inspect(reason)}",
               value: nil
             )}
        end
      else
        {:error, message} ->
          {:error,
           Ash.Error.Changes.InvalidAttribute.exception(
             field: :dimensions,
             message: message,
             value: nil
           )}
      end
    end)
  end

  @doc false
  def normalize(rows) when is_list(rows) do
    with {:ok, normalized} <- normalize_rows(rows) do
      cond do
        length(rows) != 5 ->
          {:error, "a supplier scorecard requires exactly five dimensions"}

        length(Enum.uniq_by(normalized, & &1.dimension)) != 5 ->
          {:error, "each of the five scorecard dimensions must appear exactly once"}

        Enum.sum(Enum.map(normalized, & &1.weight_pct)) != 100 ->
          {:error,
           "dimension weights must sum to exactly 100 " <>
             "(got #{Enum.sum(Enum.map(normalized, & &1.weight_pct))})"}

        true ->
          {:ok, normalized}
      end
    end
  end

  def normalize(_),
    do: {:error, "dimensions must be a list of five weighted dimension maps"}

  defp normalize_rows(rows) do
    rows
    |> Enum.reduce_while({:ok, []}, fn row, {:ok, acc} ->
      case normalize_row(row) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  defp normalize_row(row) do
    with {:ok, dimension} <- normalize_dimension(fetch(row, :dimension)),
         {:ok, weight_pct} <- integer_field(row, :weight_pct, 1, 100),
         {:ok, score} <- integer_field(row, :score, 1, 5),
         {:ok, note} <- note_field(row) do
      row =
        %{dimension: dimension, weight_pct: weight_pct, score: score}
        |> maybe_put_note(note)

      {:ok, row}
    end
  end

  defp normalize_dimension(value) when value in @dimensions, do: {:ok, value}

  defp normalize_dimension(value) when is_binary(value) do
    case Enum.find(@dimensions, &(Atom.to_string(&1) == value)) do
      nil -> {:error, "unknown scorecard dimension #{inspect(value)}"}
      dimension -> {:ok, dimension}
    end
  end

  defp normalize_dimension(value) do
    {:error, "unknown scorecard dimension #{inspect(value)}"}
  end

  defp integer_field(row, key, min, max) do
    case fetch(row, key) do
      value when is_integer(value) and value >= min and value <= max ->
        {:ok, value}

      value ->
        {:error, "#{key} must be an integer between #{min} and #{max} (got #{inspect(value)})"}
    end
  end

  defp note_field(row) do
    case fetch(row, :note) do
      nil -> {:ok, nil}
      note when is_binary(note) and byte_size(note) <= 300 -> {:ok, note}
      _ -> {:error, "note must be a string of at most 300 bytes"}
    end
  end

  defp maybe_put_note(row, nil), do: row
  defp maybe_put_note(row, note), do: Map.put(row, :note, note)

  defp fetch(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, to_string(key))
    end
  end

  defp fetch(_map, _key), do: nil

  defp bulk_insert(_dimension_mod, []), do: :ok

  defp bulk_insert(dimension_mod, rows) do
    Ash.bulk_create(rows, dimension_mod, :system_create,
      authorize?: false,
      return_errors?: true,
      return_records?: false,
      stop_on_error?: true
    )
    |> case do
      %Ash.BulkResult{status: :success} -> :ok
      %Ash.BulkResult{status: status, errors: errors} -> {:error, {status, errors}}
    end
  end
end
