defmodule Samen.Scopes.Finance.ApInvoiceCapture do
  @moduledoc """
  **AP invoice capture**: document/text → parsed draft → duplicate checks →
  one draft `ApInvoice`.

  The pipeline is deliberately stateless until confirmation. A capture attempt
  is not a ledger fact, so nothing is written for a read, a rejected duplicate,
  or a parse that the operator abandons; the durable outcome is the draft bill
  the confirm step creates, which then follows the SAME approval path as any
  other bill (`ApInvoice.:approve`, ADR-040). This is the point of capture: it
  removes typing, not governance.

  ## The two duplicate checks

    * **Number collision** (`{:duplicate_number, bill}`) — `{org, number}` is
      unique at the database, so a bill with this number IS the same document
      however it was keyed. Refused unconditionally; no override exists.
    * **Possible duplicate** (`{:possible_duplicates, numbers}`) — same vendor,
      same total, same bill date, via `ApDuplicates` (the payment run's
      definition). A vendor can legitimately ship twice at the same price on the
      same day, so this one is refused unless the caller passes
      `allow_duplicate: true` — and the page only offers that after showing
      which bills it matched.

  ## Lines and the total

  The draft's lines must sum to `:total_cents`; a mismatch is refused with
  `{:lines_total_mismatch, total, sum}` rather than absorbed. The parser adds
  an explicit `"Unallocated …"` line when the parsed total exceeds the captured
  lines, so a tax/freight line the OCR missed is visible in review instead of
  quietly changing the bill.
  """

  require Ash.Query

  alias Samen.Scopes.Finance.{ApDuplicates, InvoiceOcr, InvoiceText}

  @type draft :: %{
          vendor_name: String.t() | nil,
          number: String.t() | nil,
          invoice_date: Date.t() | nil,
          due_date: Date.t() | nil,
          total_cents: integer() | nil,
          currency: String.t(),
          lines: [map()],
          warnings: [String.t()],
          source: :text | :document,
          source_name: String.t() | nil,
          text: String.t()
        }

  @doc """
  Read pasted text or a document into a reviewable draft.

  Options: `:text`, or `:document` with `:content_type` and `:file_name`.
  Returns `{:ok, draft}`; the draft's fields may be `nil` (with a warning) —
  the operator completes them in review.
  """
  @spec capture(keyword()) :: {:ok, draft()} | {:error, term()}
  def capture(opts) do
    with {:ok, text, source, name} <- source_text(opts),
         {:ok, draft} <- InvoiceText.parse(text) do
      {:ok, Map.merge(draft, %{source: source, source_name: name, text: text})}
    end
  end

  @doc """
  The org's bill carrying `number`, if any — the capture page's immediate
  duplicate check, before the operator has filled anything in.
  """
  @spec existing_number(module(), term(), String.t(), String.t()) ::
          {:ok, struct() | nil} | {:error, term()}
  def existing_number(ap_invoice, scope, org_id, number) when is_binary(number) do
    ap_invoice
    |> Ash.Query.filter(org_id == ^org_id and number == ^number)
    |> Ash.read_one(scope: scope)
  end

  def existing_number(_ap_invoice, _scope, _org_id, _number), do: {:ok, nil}

  @doc """
  Create the draft bill for a reviewed capture.

  Options: `:ap_invoice`, `:scope`, `:org_id`, `:vendor_id`, `:account_id`,
  `:number`, `:invoice_date`, `:bill_date` (defaults to `:invoice_date`),
  `:due_date`, `:total_cents`, `:lines`, `:memo`, `:allow_duplicate`.

  Returns `{:ok, bill}` (status `:draft`) or an error naming the refused check.
  """
  @spec confirm(keyword()) :: {:ok, struct()} | {:error, term()}
  def confirm(opts) do
    ap_invoice = Keyword.fetch!(opts, :ap_invoice)
    scope = Keyword.fetch!(opts, :scope)
    org_id = Keyword.fetch!(opts, :org_id)
    vendor_id = blank_to_nil(Keyword.get(opts, :vendor_id))
    account_id = blank_to_nil(Keyword.get(opts, :account_id))
    allow_duplicate = Keyword.get(opts, :allow_duplicate, false)

    with {:ok, number} <- required_string(Keyword.get(opts, :number), :invoice_number_required),
         {:ok, vendor_id} <- required_string(vendor_id, :vendor_required),
         {:ok, account_id} <- required_string(account_id, :account_required),
         {:ok, invoice_date} <-
           required_date(Keyword.get(opts, :invoice_date), :invoice_date_required),
         {:ok, bill_date} <- date_or(Keyword.get(opts, :bill_date), invoice_date),
         {:ok, lines} <- normalize_lines(Keyword.get(opts, :lines)),
         {:ok, total} <- total(Keyword.get(opts, :total_cents), lines),
         :ok <- unique_number(ap_invoice, scope, org_id, number),
         {:ok, duplicates} <-
           possible_duplicates(ap_invoice, scope, org_id, vendor_id, bill_date, lines, number),
         :ok <- allow_or_refuse(duplicates, allow_duplicate) do
      create_bill(ap_invoice, scope, %{
        org_id: org_id,
        vendor_id: vendor_id,
        account_id: account_id,
        number: number,
        bill_date: bill_date,
        due_date: Keyword.get(opts, :due_date),
        memo: blank_to_nil(Keyword.get(opts, :memo)),
        total_cents: total,
        lines: lines
      })
    end
  end

  # -- source -----------------------------------------------------------------

  defp source_text(opts) do
    case Keyword.get(opts, :text) do
      text when is_binary(text) ->
        if String.trim(text) == "",
          do: {:error, :empty_text},
          else: {:ok, text, :text, Keyword.get(opts, :source_name)}

      _none ->
        bytes = Keyword.get(opts, :document)
        content_type = Keyword.get(opts, :content_type, "application/octet-stream")

        with {:ok, text} <- InvoiceOcr.extract(bytes, content_type, opts) do
          {:ok, text, :document, Keyword.get(opts, :file_name)}
        end
    end
  end

  # -- confirmation -----------------------------------------------------------

  defp normalize_lines(lines) when is_list(lines) and lines != [] do
    normalized =
      Enum.map(lines, fn line ->
        %{
          description:
            line
            |> Map.get(:description, Map.get(line, :memo, ""))
            |> to_string()
            |> String.trim(),
          amount_cents: Map.get(line, :amount_cents) || Map.get(line, "amount_cents")
        }
      end)

    case Enum.find(normalized, fn line ->
           not (is_integer(line.amount_cents) and line.amount_cents > 0)
         end) do
      nil -> {:ok, normalized}
      bad -> {:error, {:invalid_line, bad}}
    end
  end

  defp normalize_lines(_lines), do: {:error, :lines_required}

  defp total(nil, lines), do: {:ok, Enum.sum(Enum.map(lines, & &1.amount_cents))}

  defp total(total_cents, lines) when is_integer(total_cents) do
    sum = Enum.sum(Enum.map(lines, & &1.amount_cents))

    if total_cents == sum,
      do: {:ok, total_cents},
      else: {:error, {:lines_total_mismatch, total_cents, sum}}
  end

  defp total(_total_cents, _lines), do: {:error, :invalid_total}

  defp unique_number(ap_invoice, scope, org_id, number) do
    case existing_number(ap_invoice, scope, org_id, number) do
      {:ok, nil} -> :ok
      {:ok, bill} -> {:error, {:duplicate_number, bill}}
      {:error, reason} -> {:error, {:duplicate_check_failed, reason}}
    end
  end

  defp possible_duplicates(ap_invoice, scope, org_id, vendor_id, bill_date, lines, number) do
    query =
      Ash.Query.filter(
        ap_invoice,
        org_id == ^org_id and vendor_id == ^vendor_id and bill_date == ^bill_date
      )

    case Ash.read(query, scope: scope) do
      {:ok, bills} ->
        candidate = %{
          vendor_id: vendor_id,
          bill_date: bill_date,
          number: number,
          lines: lines
        }

        {:ok, ApDuplicates.candidate_matches(bills, candidate)}

      {:error, reason} ->
        {:error, {:duplicate_check_failed, reason}}
    end
  end

  defp allow_or_refuse([], _allow_duplicate), do: :ok
  defp allow_or_refuse(_duplicates, true), do: :ok

  defp allow_or_refuse(duplicates, false) do
    {:error, {:possible_duplicates, Enum.map(duplicates, & &1.number)}}
  end

  defp create_bill(ap_invoice, scope, attrs) do
    lines =
      Enum.map(attrs.lines, fn line ->
        %{account_id: attrs.account_id, amount_cents: line.amount_cents, memo: line.description}
      end)

    ap_invoice
    |> Ash.Changeset.for_create(
      :create,
      %{
        org_id: attrs.org_id,
        vendor_id: attrs.vendor_id,
        number: attrs.number,
        bill_date: attrs.bill_date,
        due_date: attrs.due_date,
        memo: attrs.memo,
        lines: lines
      },
      scope: scope
    )
    |> Ash.create()
  end

  # -- field helpers ----------------------------------------------------------

  defp required_string(value, error) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, error}
      trimmed -> {:ok, trimmed}
    end
  end

  defp required_string(_value, error), do: {:error, error}

  defp required_date(%Date{} = date, _error), do: {:ok, date}
  defp required_date(_date, error), do: {:error, error}

  defp date_or(nil, fallback), do: {:ok, fallback}
  defp date_or(%Date{} = date, _fallback), do: {:ok, date}
  defp date_or(_date, fallback), do: {:ok, fallback}

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(value), do: value
end
