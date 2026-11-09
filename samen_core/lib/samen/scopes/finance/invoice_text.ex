defmodule Samen.Scopes.Finance.InvoiceText do
  @moduledoc """
  The deterministic **invoice-text parser** — the second half of AP capture.

  Capture is two honest stages: something turns a document into TEXT (the OCR
  seam, `Samen.Scopes.Finance.InvoiceOcr`), and this module turns text into a
  reviewable draft. The parser is pure, offline and boring on purpose: an
  operator can always see exactly why a field was filled the way it was, and a
  host can run it over a text-layer PDF, a pasted email, or an OCR provider's
  output without any of them changing the rules.

  ## What it reads

  Line-oriented labels, case-insensitive:

    * number — `Invoice No: INV-2041` (or a bare `INV-2041` token);
    * invoice date / due date — ISO (`2026-10-14`), US slashes
      (`10/14/2026`) and `Oct 14, 2026`;
    * total — `Total due`, `Amount due`, `Balance due`, `Invoice total` or a
      bare `Total` line, taking the LAST such line (totals sit at the bottom);
    * line items — a description followed by at least two spaces and an amount
      (`Steel plate            4,250.00`), excluding subtotal/total/due rows so
      nothing is counted twice;
    * vendor — an explicit `Vendor:`/`Supplier:`/`From:` line, else the first
      name-like line in the header block;
    * currency — `$`/`€`/`£` or a `USD`/`EUR`/`GBP`/`CAD`/`AUD` token; USD
      otherwise.

  ## What it refuses to invent

  Missing fields come back `nil` with a warning, never a default that looks
  extracted. When a parsed total exceeds the captured lines (tax, freight, a
  line the OCR dropped) the difference is added as an explicit
  `"Unallocated …"` line with a warning — visible in review, summable in the
  ledger, and never silently absorbed into another line. When the lines exceed
  the total the parser only warns; the capture step refuses to confirm until an
  operator fixes it.
  """

  @type line :: %{description: String.t(), amount_cents: integer()}

  @type draft :: %{
          vendor_name: String.t() | nil,
          number: String.t() | nil,
          invoice_date: Date.t() | nil,
          due_date: Date.t() | nil,
          total_cents: integer() | nil,
          currency: String.t(),
          lines: [line()],
          warnings: [String.t()]
        }

  @number_label ~r/invoice\s*(?:no\.?|number|#)\s*[:#]?\s*([A-Z0-9][A-Z0-9._\/-]*)/i
  @bare_number ~r/\b(INV[-\/ ]?[A-Z0-9]{2,})\b/i
  @invoice_date ~r/(?:invoice|bill|issue)\s*date\s*[:\-]?\s*([^\n]+)/i
  @due_date ~r/due\s*date\s*[:\-]?\s*([^\n]+)/i
  @plain_date ~r/(?<!due )\bdate\s*[:\-]?\s*([^\n]+)/i
  @total_line ~r/\b(total\s+due|amount\s+due|balance\s+due|invoice\s+total|total)\b/i
  @skip_line ~r/\b(subtotal|sub-total|total|amount\s+due|balance\s+due)\b/i
  @amount_at_end ~r/\A(?<desc>.+?)\s{2,}(?<amount>[$€£]?\s*-?\d[\d,]*(?:\.\d{2}))\s*\z/
  @date_token ~r/\d{4}-\d{2}-\d{2}|\d{1,2}\/\d{1,2}\/\d{4}|[A-Za-z]{3,9}\.?\s+\d{1,2},?\s+\d{4}/

  @doc """
  Parse invoice text into a draft.

  Returns `{:error, :empty_text}` for blank input; every other shortcoming is a
  `nil` field plus a warning in `:warnings`.
  """
  @spec parse(String.t()) :: {:ok, draft()} | {:error, :empty_text}
  def parse(text) when is_binary(text) do
    if String.trim(text) == "" do
      {:error, :empty_text}
    else
      rows = text |> normalize() |> String.split("\n", trim: true)
      do_parse(rows, Enum.join(rows, "\n"))
    end
  end

  @doc "Parse only the first date-looking token in a string (`nil` when none)."
  @spec date_in(String.t()) :: Date.t() | nil
  def date_in(text) when is_binary(text) do
    case Regex.run(@date_token, text) do
      [token] -> parse_date(token)
      _none -> nil
    end
  end

  @doc "Parse one money token into integer cents (`nil` when it is not money)."
  @spec amount_in(String.t()) :: integer() | nil
  def amount_in(text) when is_binary(text) do
    cleaned =
      text
      |> String.replace(~r/[$€£\s]/, "")
      |> String.replace(",", "")

    case Float.parse(cleaned) do
      {value, ""} -> round(value * 100)
      _other -> nil
    end
  end

  # -- parse ------------------------------------------------------------------

  defp do_parse(rows, text) do
    warnings = []
    number = invoice_number(text)
    invoice_date = labeled_date(text, @invoice_date) || labeled_date(text, @plain_date)
    due_date = labeled_date(text, @due_date)
    currency = currency(text)
    parsed_total = total_cents(rows)
    lines = line_items(rows)

    warnings =
      warnings
      |> warn(number == nil, "invoice number not found — enter it before confirming")
      |> warn(invoice_date == nil, "invoice date not found — enter it before confirming")
      |> warn(due_date == nil, "due date not found — confirm it before paying")
      |> warn(parsed_total == nil, "invoice total not found — check the parsed lines")

    {total, lines, warnings} = balance(parsed_total, lines, currency, warnings)

    {:ok,
     %{
       vendor_name: vendor_name(rows),
       number: number,
       invoice_date: invoice_date,
       due_date: due_date,
       total_cents: total,
       currency: currency,
       lines: lines,
       warnings: warnings
     }}
  end

  defp balance(nil, lines, _currency, warnings) do
    {sum(lines), lines, warnings}
  end

  defp balance(total, lines, currency, warnings) do
    case total - sum(lines) do
      difference when difference == 0 ->
        {total, lines, warnings}

      difference when difference > 0 ->
        line = %{
          description: "Unallocated (parsed total less captured lines)",
          amount_cents: difference
        }

        {total, lines ++ [line],
         warnings ++
           [
             "added an unallocated line for #{money(difference, currency)} so the lines match the parsed total — review it"
           ]}

      difference ->
        {total, lines,
         warnings ++
           [
             "captured lines exceed the parsed total by #{money(-difference, currency)} — correct them before confirming"
           ]}
    end
  end

  defp invoice_number(text) do
    case Regex.run(@number_label, text) do
      [_, number] -> clean_number(number)
      _none -> bare_number(text)
    end
  end

  defp bare_number(text) do
    case Regex.run(@bare_number, text) do
      [_, number] -> trim_number(number)
      _none -> nil
    end
  end

  defp clean_number(number), do: trim_number(number)

  defp trim_number(number) do
    number
    |> String.trim()
    |> String.trim_trailing(".")
    |> String.trim_trailing(",")
    |> case do
      "" -> nil
      value -> value
    end
  end

  defp labeled_date(text, regex) do
    case Regex.run(regex, text) do
      [_, rest] -> date_in(rest)
      _none -> nil
    end
  end

  defp total_cents(rows) do
    rows
    |> Enum.filter(&Regex.match?(@total_line, &1))
    |> Enum.reverse()
    |> Enum.find_value(fn row ->
      row
      |> amounts()
      |> List.last()
    end)
  end

  defp amounts(row) do
    ~r/[$€£]?\s*-?\d[\d,]*(?:\.\d{2})/
    |> Regex.scan(row)
    |> List.flatten()
    |> Enum.map(&amount_in/1)
    |> Enum.reject(&is_nil/1)
  end

  defp line_items(rows) do
    rows
    |> Enum.map(fn row ->
      case Regex.named_captures(@amount_at_end, row) do
        %{"desc" => description, "amount" => amount} ->
          if skip_line?(description, row) do
            nil
          else
            cents = amount_in(amount)

            if is_integer(cents) and cents > 0 do
              %{description: clean_description(description), amount_cents: cents}
            end
          end

        _none ->
          nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> dedupe_exact()
  end

  defp skip_line?(description, row) do
    Regex.match?(@skip_line, description) or Regex.match?(@skip_line, row) or
      Regex.match?(@number_label, row) or Regex.match?(@due_date, row) or
      Regex.match?(@invoice_date, row)
  end

  # A repeated identical row (the common OCR double-read) is one line.
  defp dedupe_exact(lines) do
    lines
    |> Enum.reduce([], fn line, acc ->
      if Enum.member?(acc, line), do: acc, else: acc ++ [line]
    end)
  end

  defp clean_description(description) do
    description
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, 120)
  end

  defp currency(text) do
    cond do
      String.contains?(text, "$") -> "USD"
      String.contains?(text, "€") -> "EUR"
      String.contains?(text, "£") -> "GBP"
      true -> code_currency(text)
    end
  end

  defp code_currency(text) do
    case Regex.run(~r/\b(USD|EUR|GBP|CAD|AUD)\b/, text) do
      [_, code] -> code
      _none -> "USD"
    end
  end

  defp vendor_name(rows) do
    explicit_vendor(rows) || header_name(rows)
  end

  defp explicit_vendor(rows) do
    Enum.find_value(rows, fn row ->
      case Regex.run(~r/\A\s*(?:vendor|supplier|from|remit\s+from)\s*[:\-]\s*(.+?)\s*\z/i, row) do
        [_, name] -> String.slice(String.trim(name), 0, 80)
        _none -> nil
      end
    end)
  end

  defp header_name(rows) do
    rows
    |> Enum.take(8)
    |> Enum.find_value(fn row ->
      trimmed = String.trim(row)

      if name_like?(trimmed), do: String.slice(trimmed, 0, 80)
    end)
  end

  defp name_like?(row) do
    cond do
      String.length(row) < 2 or String.length(row) > 60 -> false
      Regex.match?(@amount_at_end, row) -> false
      Regex.match?(@number_label, row) -> false
      Regex.match?(@total_line, row) -> false
      Regex.match?(@due_date, row) or Regex.match?(@invoice_date, row) -> false
      Regex.match?(~r/^(bill|ship|sold)\s+to\b/i, row) -> false
      Regex.match?(~r/^invoice\b/i, row) -> false
      Regex.match?(~r/[\$€£]/, row) -> false
      not Regex.match?(~r/[A-Za-z]{2,}/, row) -> false
      true -> true
    end
  end

  defp sum(lines), do: Enum.reduce(lines, 0, &(&1.amount_cents + &2))

  defp warn(warnings, true, message), do: warnings ++ [message]
  defp warn(warnings, false, _message), do: warnings

  defp money(cents, currency) when is_integer(cents) do
    "#{currency} #{div(cents, 100)}.#{cents |> rem(100) |> Integer.to_string() |> String.pad_leading(2, "0")}"
  end

  defp normalize(text) do
    text
    |> String.replace("\r\n", "\n")
    |> String.replace("\r", "\n")
    |> String.replace("\u00A0", " ")
    |> String.replace(~r/\t+/, "  ")
  end

  # -- dates ------------------------------------------------------------------

  defp parse_date(value) do
    value = String.trim(value)

    Enum.find_value([&iso_date/1, &slash_date/1, &named_date/1], fn parser -> parser.(value) end)
  end

  defp iso_date(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      _other -> nil
    end
  end

  # Slashes are US-style (month first) unless the first component cannot be a
  # month — then it is the day and the second is the month. Two components that
  # could both be a month stay month-first, never silently reordered.
  defp slash_date(value) do
    case Regex.run(~r/\A(\d{1,2})\/(\d{1,2})\/(\d{4})\z/, value) do
      [_, first, second, year] ->
        {month, day} = slash_pair(String.to_integer(first), String.to_integer(second))
        Date.new(String.to_integer(year), month, day) |> ok_or_nil()

      _none ->
        nil
    end
  end

  defp slash_pair(first, second) when first > 12 and second <= 12, do: {second, first}
  defp slash_pair(first, second), do: {first, second}

  defp named_date(value) do
    case Regex.run(~r/\A([A-Za-z]{3,9})\.?\s+(\d{1,2}),?\s+(\d{4})\z/, value) do
      [_, month, day, year] ->
        with month when is_integer(month) <- month_number(month),
             {:ok, date} <- Date.new(String.to_integer(year), month, String.to_integer(day)) do
          date
        else
          _other -> nil
        end

      _none ->
        nil
    end
  end

  defp ok_or_nil({:ok, date}), do: date
  defp ok_or_nil(_other), do: nil

  defp month_number(name) do
    months = ~w(jan feb mar apr may jun jul aug sep oct nov dec)

    case Enum.find_index(months, &(String.downcase(String.slice(name, 0, 3)) == &1)) do
      nil -> nil
      index -> index + 1
    end
  end
end
