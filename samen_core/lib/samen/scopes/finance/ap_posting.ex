defmodule Samen.Scopes.Finance.ApPosting do
  @moduledoc """
  The AP posting cascade (WS-ERP E2; design §2.2): on `:approve`, land the
  expense+liability `JournalEntry` in the org's functional currency.

  The bill's lines are denominated in the bill's `currency`. When that differs
  from the org's base currency, the line amounts and total are converted at a
  stored rate dated at or before the bill date; the rate and base total are
  stamped onto the bill so payment settles the liability that was actually
  posted. A missing rate refuses the approval — the ledger never invents an FX
  conversion.

  Runs in `:approve`'s `before_action` inside the decision transaction, so a
  posting failure rolls back the approval transition and its audit. The
  exactly-once status check and the posting-account resolution are unchanged.
  """

  use Ash.Resource.Change

  alias Samen.Scopes.Finance.ApFx

  @source_key "ap_invoice"

  @impl true
  def change(changeset, opts, _context) do
    entry_resource = Keyword.fetch!(opts, :entry)
    pa_resource = Keyword.fetch!(opts, :posting_account)
    org_fx_settings = Keyword.fetch!(opts, :org_fx_settings)
    exchange_rate = Keyword.fetch!(opts, :exchange_rate)
    repo = Keyword.fetch!(opts, :repo)

    org_id = loaded_org_id(changeset)

    Ash.Changeset.before_action(changeset, fn changeset ->
      do_post(
        changeset,
        org_id,
        entry_resource,
        pa_resource,
        org_fx_settings,
        exchange_rate,
        repo
      )
    end)
  end

  defp do_post(
         changeset,
         org_id,
         entry_resource,
         pa_resource,
         org_fx_settings,
         exchange_rate,
         repo
       ) do
    bill = changeset.data
    base_currency = ApFx.base_currency(org_fx_settings, org_id)
    currency = bill.currency || base_currency

    with :ok <- refuse_non_draft(changeset),
         {:ok, lines} <- lines_of(bill),
         :ok <- refuse_zero_total(lines),
         {:ok, ap_clearing} <- posting_account(pa_resource, org_id, :ap_clearing),
         {:ok, base_total, rate, converted_lines} <-
           functional_lines(
             lines,
             currency,
             base_currency,
             bill.bill_date,
             org_id,
             exchange_rate,
             repo
           ) do
      entry_lines =
        (Enum.map(converted_lines, fn line ->
           %{account_id: line.account_id, debit_cents: line.amount_cents, credit_cents: 0}
         end) ++
           [
             %{
               account_id: ap_clearing.account_id,
               debit_cents: 0,
               credit_cents: base_total
             }
           ])
        |> Enum.reject(&(&1.debit_cents == 0 and &1.credit_cents == 0))

      entry_attrs = %{
        org_id: org_id,
        entry_date: bill.bill_date,
        memo: "AP bill #{bill.number}" <> memo_suffix(bill.memo),
        source_key: @source_key,
        source_id: bill.id,
        lines: entry_lines
      }

      case entry_resource
           |> Ash.Changeset.for_create(:create_reversal, entry_attrs, authorize?: false)
           |> Ash.create(authorize?: false) do
        {:ok, entry} ->
          changeset
          |> Ash.Changeset.force_change_attribute(:currency, currency)
          |> Ash.Changeset.force_change_attribute(:base_currency, base_currency)
          |> Ash.Changeset.force_change_attribute(:base_total_cents, base_total)
          |> Ash.Changeset.force_change_attribute(:exchange_rate, rate)
          |> Ash.Changeset.force_change_attribute(:status, :approved)
          |> Ash.Changeset.force_change_attribute(:posted_entry_id, entry.id)
          |> Ash.Changeset.force_change_attribute(:posted_at, now())

        {:error, reason} ->
          Ash.Changeset.add_error(changeset,
            field: :base,
            message: "the AP bill's posting entry failed to land: #{inspect(reason)}"
          )
      end
    else
      {:error, reason} ->
        Ash.Changeset.add_error(changeset,
          field: :base,
          message: "the AP bill cannot be approved: #{format(reason, currency, base_currency)}"
        )
    end
  end

  defp functional_lines(lines, currency, base_currency, bill_date, org_id, exchange_rate, repo) do
    total = total(lines)

    if currency == base_currency do
      {:ok, total, "1.0", lines}
    else
      with {:ok, {base_total, rate}} <-
             ApFx.convert(total, currency, base_currency, bill_date, org_id, repo, exchange_rate),
           {:ok, converted} <- ApFx.convert_lines(lines, rate, base_total) do
        {:ok, base_total, rate, converted}
      else
        {:error, reason} -> {:error, {reason, currency, base_currency}}
      end
    end
  end

  defp loaded_org_id(changeset) do
    case Ash.Changeset.get_attribute(changeset, :org_id) do
      %Ash.NotLoaded{} -> Ash.load!(changeset.data, [:org_id], authorize?: false).org_id
      value -> value
    end
  end

  defp refuse_non_draft(changeset) do
    case Ash.Changeset.get_attribute(changeset, :status) || changeset.data.status do
      :draft -> :ok
      other -> {:error, {:not_draft, other}}
    end
  end

  defp lines_of(bill) do
    case bill.lines do
      lines when is_list(lines) and lines != [] -> {:ok, lines}
      _ -> {:error, :no_lines}
    end
  end

  defp refuse_zero_total(lines) do
    if total(lines) > 0, do: :ok, else: {:error, :zero_total}
  end

  defp total(lines), do: Enum.sum(Enum.map(lines, &line_amount/1))

  defp line_amount(line) when is_map(line),
    do: Map.get(line, :amount_cents) || Map.get(line, "amount_cents") || 0

  defp posting_account(pa_resource, org_id, key) do
    require Ash.Query

    case pa_resource
         |> Ash.Query.filter(org_id == ^org_id and key == ^key)
         |> Ash.read_one(authorize?: false) do
      {:ok, nil} -> {:error, {:unmapped_posting_account, key}}
      {:ok, row} -> {:ok, row}
      {:error, reason} -> {:error, reason}
    end
  end

  defp format({:unmapped_posting_account, key}, _currency, _base),
    do:
      "no PostingAccount row maps `#{key}` for this org (fail-honest — accounts are a " <>
        "host decision; seed the org's posting accounts first)"

  defp format({:not_draft, status}, _currency, _base),
    do: "the bill is #{inspect(status)} — only a :draft bill can be approved"

  defp format(:no_lines, _currency, _base), do: "the bill carries no lines"

  defp format(:zero_total, _currency, _base),
    do: "the bill total is zero — an AP posting of nothing is not a fact"

  defp format({:rate_not_found, _from, _to}, currency, base),
    do:
      "no exchange rate is stored for #{currency} → #{base} at or before the bill date; " <>
        "store the rate before approving this bill"

  defp format({:rounding, _from, _to}, currency, base),
    do: "the #{currency} → #{base} conversion rounded to zero on a line; adjust the bill lines"

  defp format(reason, _currency, _base), do: inspect(reason)

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp memo_suffix(nil), do: ""
  defp memo_suffix(""), do: ""
  defp memo_suffix(memo), do: " — " <> memo
end
