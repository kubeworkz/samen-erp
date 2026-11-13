defmodule Samen.Scopes.Finance.JournalTemplateLines do
  @moduledoc """
  Validates and canonicalizes a journal template's reusable line set.

  A template is only useful if it can become a valid journal draft. This guard
  therefore applies the same R1 contract the journal itself applies:

    * at least two real lines (an empty template is not a journal);
    * exactly one of `debit_cents`/`credit_cents` is non-zero and positive;
    * Σ debits == Σ credits;
    * every `account_id` is an account in the template's org.

  Account ids are checked here, before the template can be saved, rather than
  only when a generated draft is attempted. The dimension map is carried
  through untouched and validated by the journal's own `DimensionGuard` when
  the draft is generated, so the ledger remains the single authority for that
  seam.
  """

  use Ash.Resource.Change

  require Ash.Query

  @impl true
  def change(changeset, opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      if changeset.action.type == :create or Map.has_key?(changeset.attributes, :lines) do
        validate(changeset, opts)
      else
        changeset
      end
    end)
  end

  defp validate(changeset, opts) do
    raw = Ash.Changeset.get_attribute(changeset, :lines) || []

    with {:ok, lines} <- normalize_lines(raw),
         :ok <- check_balance(lines),
         :ok <- check_accounts(changeset, lines, opts) do
      Ash.Changeset.force_change_attribute(changeset, :lines, lines)
    else
      {:error, message} -> Ash.Changeset.add_error(changeset, field: :lines, message: message)
    end
  end

  defp normalize_lines(lines) when is_list(lines) do
    lines
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {line, index}, {:ok, acc} ->
      case normalize_line(line, index) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
    |> case do
      {:ok, normalized} when length(normalized) >= 2 -> {:ok, Enum.reverse(normalized)}
      {:ok, _} -> {:error, "a journal template requires at least two lines"}
      other -> other
    end
  end

  defp normalize_lines(_), do: {:error, "lines must be a list of line maps"}

  defp normalize_line(line, index) when is_map(line) do
    account_id = get(line, :account_id)
    debit = get(line, :debit_cents)
    credit = get(line, :credit_cents)
    refs = get(line, :dimension_refs) || %{}

    with {:ok, account_id} <- uuid(account_id, index),
         {:ok, debit} <- cents(debit, index, :debit_cents),
         {:ok, credit} <- cents(credit, index, :credit_cents),
         :ok <- line_direction(debit, credit, index),
         true <- is_map(refs) do
      {:ok,
       %{
         account_id: account_id,
         debit_cents: debit,
         credit_cents: credit,
         memo: get(line, :memo),
         dimension_refs: refs
       }}
    else
      false ->
        {:error, "line #{index}: dimension_refs must be a map of axis => CostObject id"}

      {:error, message} ->
        {:error, message}
    end
  end

  defp normalize_line(_line, index), do: {:error, "line #{index} must be a map"}

  defp line_direction(debit, credit, index) do
    cond do
      debit < 0 or credit < 0 ->
        {:error, "line #{index}: amounts must be unsigned cents"}

      debit > 0 and credit > 0 ->
        {:error, "line #{index}: exactly one of debit_cents or credit_cents may be non-zero"}

      debit == 0 and credit == 0 ->
        {:error, "line #{index}: one of debit_cents or credit_cents must be non-zero"}

      true ->
        :ok
    end
  end

  defp check_balance(lines) do
    debits = Enum.reduce(lines, 0, &(&1.debit_cents + &2))
    credits = Enum.reduce(lines, 0, &(&1.credit_cents + &2))

    if debits == credits do
      :ok
    else
      {:error,
       "unbalanced journal template: debits sum to #{debits} but credits sum to " <>
         "#{credits} — Σ debits must equal Σ credits (R1)"}
    end
  end

  defp check_accounts(changeset, lines, opts) do
    account_mod = Keyword.fetch!(opts, :account)
    org_id = org_id(changeset)
    ids = lines |> Enum.map(& &1.account_id) |> Enum.uniq()

    query =
      account_mod
      |> Ash.Query.filter(org_id == ^org_id and id in ^ids)

    case Ash.read(query, authorize?: false) do
      {:ok, accounts} ->
        found = MapSet.new(accounts, & &1.id)
        missing = Enum.reject(ids, &MapSet.member?(found, &1))

        if missing == [] do
          :ok
        else
          {:error,
           "journal template names account(s) that are not in this org: #{inspect(missing)}"}
        end

      {:error, reason} ->
        {:error, "the template account check could not run: #{inspect(reason)}"}
    end
  end

  defp org_id(changeset) do
    case Ash.Changeset.get_attribute(changeset, :org_id) do
      value when is_binary(value) ->
        value

      _ ->
        case changeset.data do
          %{org_id: value} when is_binary(value) -> value
          data -> Ash.load!(data, [:org_id], authorize?: false).org_id
        end
    end
  end

  defp uuid(nil, index), do: {:error, "line #{index}: account_id is required"}

  defp uuid(value, index) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, "line #{index}: account_id must be a UUID"}
    end
  end

  defp cents(nil, _index, _field), do: {:ok, 0}
  defp cents(value, _index, _field) when is_integer(value), do: {:ok, value}

  defp cents(value, index, field) when is_binary(value) do
    case Integer.parse(value) do
      {amount, ""} -> {:ok, amount}
      _ -> {:error, "line #{index}: #{field} must be an integer number of cents"}
    end
  end

  defp cents(_value, index, field),
    do: {:error, "line #{index}: #{field} must be an integer number of cents"}

  defp get(map, key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end
end
