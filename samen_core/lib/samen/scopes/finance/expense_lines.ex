defmodule Samen.Scopes.Finance.ExpenseLines do
  @moduledoc """
  Shared validation for an expense report's embedded lines.

  A line names a same-org, active `ExpenseCategory` and optionally a same-org,
  active `CorporateCard` when its payment method is `"corporate_card"`. The
  report's currency must match the card's currency, receipt policy and
  per-line caps are enforced, and the returned totals are the only amounts the
  posting/settlement cascades use. No PII: ids, amounts, dates and opaque
  receipt references only.
  """

  require Ash.Query

  @payment_methods ~w(cash personal_card corporate_card)

  @type facts :: %{
          total_cents: non_neg_integer(),
          employee_cents: non_neg_integer(),
          card_cents_by_account: %{optional(String.t()) => non_neg_integer()},
          categories: %{optional(String.t()) => struct()},
          cards: %{optional(String.t()) => struct()},
          lines: [map()],
          currency: String.t()
        }

  @doc """
  Validate `lines` against the org's categories/cards.

  Returns `{:ok, facts}` or `{:error, message}`. `require_lines: true` is used
  by submit/approve so a draft can exist empty while a report cannot be
  submitted or posted empty.
  """
  @spec validate(
          term(),
          term(),
          String.t() | nil,
          module(),
          module(),
          keyword()
        ) :: {:ok, facts()} | {:error, String.t()}
  def validate(lines, currency, org_id, category_resource, card_resource, opts \\ []) do
    require_lines? = Keyword.get(opts, :require_lines, false)

    with :ok <- validate_list(lines),
         {:ok, normalized} <- normalize_lines(lines),
         :ok <- require_any(normalized, require_lines?),
         {:ok, normalized_currency} <- normalize_currency(currency),
         {:ok, categories} <-
           load_by_id(category_resource, org_id, Enum.map(normalized, & &1.category_id)),
         {:ok, cards} <-
           load_by_id(
             card_resource,
             org_id,
             normalized |> Enum.map(& &1.corporate_card_id) |> Enum.reject(&is_nil/1)
           ),
         {:ok, totals} <- validate_lines(normalized, normalized_currency, categories, cards) do
      {:ok,
       Map.merge(
         %{
           lines: normalized,
           currency: normalized_currency,
           categories: categories,
           cards: cards
         },
         totals
       )}
    end
  end

  defp validate_list(lines) when is_list(lines), do: :ok
  defp validate_list(_lines), do: {:error, "expense report lines must be a list"}

  defp require_any([], true), do: {:error, "an expense report needs at least one line"}
  defp require_any(_lines, _required?), do: :ok

  defp normalize_lines(lines) do
    lines
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {line, index}, {:ok, acc} ->
      case normalize_line(line, index) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, _} = error -> error
    end
  end

  defp normalize_line(line, index) when is_map(line) do
    category_id = uuid(field(line, :category_id))
    card_id = uuid(field(line, :corporate_card_id))
    description = text(field(line, :description))
    amount_cents = field(line, :amount_cents)
    spent_on = parse_date(field(line, :spent_on))
    payment_method = method(field(line, :payment_method))
    receipt_ref = text(field(line, :receipt_ref))

    cond do
      is_nil(category_id) ->
        {:error, "line #{index}: category_id must be a UUID"}

      not is_nil(field(line, :corporate_card_id)) and is_nil(card_id) ->
        {:error, "line #{index}: corporate_card_id must be a UUID"}

      is_nil(description) ->
        {:error, "line #{index}: description is required"}

      not is_integer(amount_cents) or amount_cents <= 0 ->
        {:error, "line #{index}: amount_cents must be a positive integer"}

      is_nil(spent_on) ->
        {:error, "line #{index}: spent_on must be a date"}

      payment_method not in @payment_methods ->
        {:error, "line #{index}: payment_method must be cash, personal_card or corporate_card"}

      payment_method == "corporate_card" and is_nil(card_id) ->
        {:error, "line #{index}: a corporate-card expense must name corporate_card_id"}

      payment_method != "corporate_card" and not is_nil(card_id) ->
        {:error, "line #{index}: only a corporate-card expense may name corporate_card_id"}

      true ->
        {:ok,
         %{
           category_id: category_id,
           corporate_card_id: card_id,
           description: description,
           amount_cents: amount_cents,
           spent_on: spent_on,
           payment_method: payment_method,
           receipt_ref: receipt_ref
         }}
    end
  end

  defp normalize_line(_line, index), do: {:error, "line #{index} must be a map"}

  defp validate_lines(lines, currency, categories, cards) do
    lines
    |> Enum.with_index(1)
    |> Enum.reduce_while(
      {:ok, %{total_cents: 0, employee_cents: 0, card_cents_by_account: %{}}},
      fn {line, index}, {:ok, acc} ->
        category = Map.get(categories, line.category_id)
        card = line.corporate_card_id && Map.get(cards, line.corporate_card_id)

        case validate_line(line, index, currency, category, card) do
          :ok ->
            card_cents_by_account =
              if card do
                Map.update(
                  acc.card_cents_by_account,
                  card.account_id,
                  line.amount_cents,
                  &(&1 + line.amount_cents)
                )
              else
                acc.card_cents_by_account
              end

            employee_cents =
              if line.payment_method == "corporate_card" do
                acc.employee_cents
              else
                acc.employee_cents + line.amount_cents
              end

            {:cont,
             {:ok,
              %{
                acc
                | total_cents: acc.total_cents + line.amount_cents,
                  employee_cents: employee_cents,
                  card_cents_by_account: card_cents_by_account
              }}}

          {:error, message} ->
            {:halt, {:error, message}}
        end
      end
    )
  end

  defp validate_line(_line, index, _currency, nil, _card),
    do: {:error, "line #{index}: expense category is not available in this org"}

  defp validate_line(_line, index, _currency, category, _card) when not category.is_active,
    do: {:error, "line #{index}: expense category is inactive"}

  defp validate_line(line, index, _currency, _category, nil)
       when line.payment_method == "corporate_card",
       do: {:error, "line #{index}: corporate card is not available in this org"}

  defp validate_line(_line, index, _currency, _category, card)
       when not is_nil(card) and not card.is_active,
       do: {:error, "line #{index}: corporate card is inactive"}

  defp validate_line(_line, index, currency, _category, card)
       when not is_nil(card) and card.currency != currency,
       do: {:error, "line #{index}: corporate card currency does not match the report currency"}

  defp validate_line(line, index, _currency, category, _card)
       when category.requires_receipt and is_nil(line.receipt_ref),
       do: {:error, "line #{index}: a receipt is required for this category"}

  defp validate_line(line, index, _currency, category, _card)
       when is_integer(category.max_amount_cents) and
              line.amount_cents > category.max_amount_cents,
       do:
         {:error,
          "line #{index}: amount exceeds the category limit of #{category.max_amount_cents} cents"}

  defp validate_line(_line, _index, _currency, _category, _card), do: :ok

  defp load_by_id(_resource, _org_id, []), do: {:ok, %{}}

  defp load_by_id(resource, org_id, ids) do
    ids = Enum.uniq(ids)

    rows =
      resource
      |> Ash.Query.filter(org_id == ^org_id and id in ^ids)
      |> Ash.read!(authorize?: false)

    {:ok, Map.new(rows, &{&1.id, &1})}
  end

  defp normalize_currency(value) when is_binary(value) do
    normalized = value |> String.trim() |> String.upcase()

    if Regex.match?(~r/\A[A-Z]{3}\z/, normalized) do
      {:ok, normalized}
    else
      {:error, "expense report currency must be a three-letter ISO 4217 code"}
    end
  end

  defp normalize_currency(_value),
    do: {:error, "expense report currency must be a three-letter ISO 4217 code"}

  defp field(map, key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end

  defp uuid(_value), do: nil

  defp text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp text(_value), do: nil

  defp method(value) when is_atom(value), do: Atom.to_string(value)
  defp method(value) when is_binary(value), do: value
  defp method(_value), do: nil

  defp parse_date(%Date{} = date), do: date

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp parse_date(_value), do: nil
end
