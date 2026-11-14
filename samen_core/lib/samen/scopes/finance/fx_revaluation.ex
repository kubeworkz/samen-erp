defmodule Samen.Scopes.Finance.FxRevaluation do
  @moduledoc """
  Period-end remeasurement of open foreign-currency AP (the AP half of
  ADR-049 §7.3, lifted for the close by the WS-ACCT books work).

  An approved AP bill carries the functional-currency liability that was
  posted at approval (`base_total_cents`) and the rate used
  (`exchange_rate`). Between approval and payment the vendor-facing amount is
  unchanged, but the functional liability moves with the closing rate. This
  module measures that movement at a fiscal-period end and posts the unrealized
  difference:

    * CAD weakens / the foreign liability grows:
      **Dr unrealized FX gain/loss, Cr AP clearing**
    * CAD strengthens / the foreign liability shrinks:
      **Dr AP clearing, Cr unrealized FX gain/loss**

  It then updates each bill's carrying `base_total_cents` and `exchange_rate`
  so `ApPaymentPosting` computes realized FX against the carrying amount, not
  against the original approval amount. That is what prevents the same rate
  movement from being recognized twice.

  ## Deliberately AP-only

  The close revalues AP monetary liabilities. It does not revalue AR, cash, or
  intercompany balances, and it does not operate a consolidation/translation
  reserve: the books have one functional currency (CAD), and a CTA belongs to
  translating a foreign operation into a presentation currency, not to a CAD
  entity's USD payables.

  ## Fail closed

  Every bill is remeasured through `ApFx.convert/7`, the strict
  org-scoped lookup that only accepts a rate dated at or before the period end.
  A missing period-end rate or a missing carrying amount refuses the whole
  preview/post rather than silently using a stale or future rate.

  ## One entry per close; bill voids clear it, not void it

  The posted entry aggregates every revalued bill (`source_id` is the close
  run), so it cannot be voided for one bill without reversing the others.
  `Samen.Scopes.Finance.VoidApInvoice` therefore posts a bill-specific
  current-period `ap_void` clearing entry that reverses the bill's cumulative
  unrealized difference; the shared revaluation entry stays posted history and
  the two net to zero.

  ## Idempotence

  The preview measures `remeasured - carrying` from the bill's current stored
  carrying amount. Posting updates that carrying amount, so a second run at the
  same rate produces a zero delta and no second entry. A later rate creates an
  incremental entry, not a duplicate recognition of the earlier one.
  """

  use Ash.Resource.Change

  require Ash.Query

  alias Samen.Scopes.Finance.ApFx

  @source_key "fx_revaluation"

  @doc """
  Read-only measurement of the period-end adjustment for `close_run`'s period.

  Returns a map with the priced bills, the aggregate gain/loss, and a status of
  `:ready` or `:noop`. Missing rates, missing carrying amounts, or a non-AP
  base currency return `{:error, reason}`.
  """
  @spec preview(map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def preview(close_run, period, opts) do
    repo = Keyword.fetch!(opts, :repo)
    ap_invoice = Keyword.fetch!(opts, :ap_invoice)
    org_fx_settings = Keyword.fetch!(opts, :org_fx_settings)
    exchange_rate = Keyword.fetch!(opts, :exchange_rate)
    org_id = org_id(close_run)
    as_of = period_end(period)
    base_currency = ApFx.base_currency(org_fx_settings, org_id)

    with {:ok, bills} <-
           open_bills(ap_invoice, org_id, base_currency, Keyword.get(opts, :lock?, false)),
         {:ok, rows} <-
           remeasure(bills, base_currency, as_of, org_id, repo, exchange_rate) do
      gain_cents =
        rows |> Enum.filter(&(&1.delta_cents < 0)) |> Enum.map(&(-&1.delta_cents)) |> Enum.sum()

      loss_cents =
        rows |> Enum.filter(&(&1.delta_cents > 0)) |> Enum.map(& &1.delta_cents) |> Enum.sum()

      {:ok,
       %{
         close_run_id: close_run.id,
         period_id: period.id,
         as_of: as_of,
         base_currency: base_currency,
         bills: rows,
         gain_cents: gain_cents,
         loss_cents: loss_cents,
         net_cents: loss_cents - gain_cents,
         status: if(gain_cents + loss_cents > 0, do: :ready, else: :noop)
       }}
    end
  end

  @doc false
  @impl true
  def change(changeset, opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      case post(changeset.data, opts) do
        {:ok, _result} ->
          changeset

        {:error, reason} ->
          Ash.Changeset.add_error(changeset,
            field: :base,
            message: "the period-end FX revaluation was refused: #{format(reason)}"
          )
      end
    end)
  end

  @doc """
  Post the period-end adjustment for `close_run`.

  Runs in the close action's transaction. The entry is anchored
  `source_key: "fx_revaluation"` and `source_id: <close_run id>`, and carries
  one debit/credit pair per repriced bill with the bill number in the line
  memo. A completed close run or a closed period refuses the write.
  """
  @spec post(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def post(close_run, opts) do
    repo = Keyword.fetch!(opts, :repo)

    repo.transaction(fn ->
      with :ok <- ensure_in_progress(close_run),
           {:ok, period} <- load_period(close_run, opts),
           :ok <- ensure_period_open(period),
           {:ok, preview} <-
             preview(close_run, period, Keyword.put(opts, :lock?, true)),
           {:ok, result} <- do_post(close_run, period, preview, opts) do
        result
      else
        {:error, reason} -> repo.rollback(reason)
      end
    end)
  end

  defp do_post(_close_run, _period, %{status: :noop} = preview, _opts), do: {:ok, preview}

  defp do_post(close_run, period, preview, opts) do
    org_id = org_id(close_run)
    entry_resource = Keyword.fetch!(opts, :entry)
    pa_resource = Keyword.fetch!(opts, :posting_account)
    ap_invoice = Keyword.fetch!(opts, :ap_invoice)
    base_currency = preview.base_currency

    with {:ok, ap_clearing} <- posting_account(pa_resource, org_id, :ap_clearing),
         {:ok, unrealized} <- posting_account(pa_resource, org_id, :unrealized_fx_gain_loss),
         {:ok, entry} <-
           create_entry(close_run, period, preview, entry_resource, ap_clearing, unrealized),
         :ok <- update_bills(preview.bills, base_currency, ap_invoice) do
      {:ok, Map.merge(preview, %{status: :posted, entry_id: entry.id})}
    end
  end

  defp open_bills(resource, org_id, base_currency, lock?) do
    query =
      resource
      |> Ash.Query.filter(org_id == ^org_id and status == :approved)
      |> maybe_lock(lock?)

    case Ash.read(query, authorize?: false) do
      {:ok, bills} -> {:ok, Enum.filter(bills, &foreign_bill?(&1, base_currency))}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_lock(query, true), do: Ash.Query.lock(query, :for_update)
  defp maybe_lock(query, false), do: query

  defp foreign_bill?(%{currency: currency}, base_currency) when is_binary(currency) do
    String.upcase(currency) != base_currency
  end

  defp foreign_bill?(_bill, _base_currency), do: false

  defp remeasure(bills, base_currency, as_of, org_id, repo, exchange_rate) do
    bills
    |> Enum.reduce_while({:ok, []}, fn bill, {:ok, acc} ->
      case remeasure_bill(bill, base_currency, as_of, org_id, repo, exchange_rate) do
        {:ok, row} -> {:cont, {:ok, [row | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, rows} -> {:ok, Enum.reverse(rows)}
      error -> error
    end
  end

  defp remeasure_bill(bill, base_currency, as_of, org_id, repo, exchange_rate) do
    with :ok <- check_base_currency(bill, base_currency),
         {:ok, total} <- total_cents(bill),
         {:ok, carrying} <- carrying_cents(bill),
         {:ok, {remeasured, rate}} <-
           convert(total, bill.currency, base_currency, as_of, org_id, repo, exchange_rate) do
      delta = remeasured - carrying

      {:ok,
       %{
         bill_id: bill.id,
         number: bill.number,
         currency: bill.currency,
         total_cents: total,
         carrying_base_cents: carrying,
         remeasured_base_cents: remeasured,
         rate: rate,
         delta_cents: delta,
         direction: direction(delta)
       }}
    else
      {:error, :rate_not_found} ->
        {:error, {:rate_not_found, bill.number, bill.currency, base_currency}}

      {:error, reason} ->
        {:error, {reason, bill.number}}
    end
  end

  defp check_base_currency(%{base_currency: base_currency}, base_currency)
       when is_binary(base_currency),
       do: :ok

  defp check_base_currency(_bill, _base_currency), do: {:error, :missing_base_currency}

  defp total_cents(%{lines: lines}) when is_list(lines) and lines != [] do
    total = Enum.sum(Enum.map(lines, &line_amount/1))
    if total > 0, do: {:ok, total}, else: {:error, :zero_total}
  end

  defp total_cents(_bill), do: {:error, :no_lines}

  defp carrying_cents(%{base_total_cents: amount}) when is_integer(amount) and amount > 0,
    do: {:ok, amount}

  defp carrying_cents(_bill), do: {:error, :missing_base_amount}

  defp convert(total, currency, base_currency, as_of, org_id, repo, exchange_rate) do
    case ApFx.convert(total, currency, base_currency, as_of, org_id, repo, exchange_rate) do
      {:ok, {amount, rate}} -> {:ok, {amount, rate}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp direction(0), do: :none
  defp direction(delta) when delta > 0, do: :loss
  defp direction(_delta), do: :gain

  defp create_entry(close_run, period, preview, entry_resource, ap_clearing, unrealized) do
    lines = Enum.flat_map(preview.bills, &entry_lines(&1, ap_clearing, unrealized))

    attrs = %{
      org_id: org_id(close_run),
      entry_date: preview.as_of,
      memo: entry_memo(period),
      source_key: @source_key,
      source_id: close_run.id,
      lines: lines
    }

    case entry_resource
         |> Ash.Changeset.for_create(:create_reversal, attrs, authorize?: false)
         |> Ash.create(authorize?: false) do
      {:ok, entry} -> {:ok, entry}
      {:error, reason} -> {:error, {:entry_failed, reason}}
    end
  end

  defp entry_lines(%{delta_cents: 0}, _ap_clearing, _unrealized), do: []

  defp entry_lines(%{delta_cents: delta} = row, ap_clearing, unrealized) when delta > 0 do
    memo = line_memo(row, "loss")

    [
      %{
        account_id: unrealized.account_id,
        debit_cents: delta,
        credit_cents: 0,
        memo: memo
      },
      %{
        account_id: ap_clearing.account_id,
        debit_cents: 0,
        credit_cents: delta,
        memo: memo
      }
    ]
  end

  defp entry_lines(%{delta_cents: delta} = row, ap_clearing, unrealized) do
    amount = -delta
    memo = line_memo(row, "gain")

    [
      %{
        account_id: ap_clearing.account_id,
        debit_cents: amount,
        credit_cents: 0,
        memo: memo
      },
      %{
        account_id: unrealized.account_id,
        debit_cents: 0,
        credit_cents: amount,
        memo: memo
      }
    ]
  end

  defp update_bills(rows, base_currency, ap_invoice) do
    Enum.reduce_while(rows, :ok, fn
      %{delta_cents: 0}, :ok ->
        {:cont, :ok}

      row, :ok ->
        attrs = %{
          base_total_cents: row.remeasured_base_cents,
          exchange_rate: row.rate,
          base_currency: base_currency
        }

        with {:ok, bill} <- Ash.get(ap_invoice, row.bill_id, authorize?: false),
             {:ok, _bill} <-
               bill
               |> Ash.Changeset.for_update(:revalue_fx, attrs, authorize?: false)
               |> Ash.update(authorize?: false) do
          {:cont, :ok}
        else
          {:error, reason} -> {:halt, {:error, {:bill_update_failed, row.bill_id, reason}}}
        end
    end)
  end

  defp posting_account(resource, org_id, key) do
    case resource
         |> Ash.Query.filter(org_id == ^org_id and key == ^key)
         |> Ash.read_one(authorize?: false) do
      {:ok, nil} -> {:error, {:unmapped_posting_account, key}}
      {:ok, row} -> {:ok, row}
      {:error, reason} -> {:error, reason}
    end
  end

  defp load_period(close_run, opts) do
    period_resource = Keyword.fetch!(opts, :period)

    case Ash.get(period_resource, close_run.period_id, authorize?: false) do
      {:ok, period} -> {:ok, period}
      {:error, reason} -> {:error, {:period_not_found, reason}}
    end
  end

  defp ensure_in_progress(%{status: :in_progress}), do: :ok
  defp ensure_in_progress(%{status: :completed}), do: {:error, :close_run_completed}
  defp ensure_in_progress(%{status: status}), do: {:error, {:close_run_not_in_progress, status}}

  defp ensure_period_open(%{status: :closed}), do: {:error, :period_closed}
  defp ensure_period_open(_period), do: :ok

  defp org_id(%{org_id: org_id}) when is_binary(org_id), do: org_id

  defp org_id(close_run) do
    Ash.load!(close_run, [:org_id], authorize?: false).org_id
  end

  defp period_end(%{year: year, month: month}) do
    Date.new!(year, month, 1) |> Date.end_of_month()
  end

  defp line_amount(line) when is_map(line) do
    Map.get(line, :amount_cents) || Map.get(line, "amount_cents") || 0
  end

  defp entry_memo(period) do
    "Period-end FX revaluation — #{period.year}-#{String.pad_leading(to_string(period.month), 2, "0")}"
  end

  defp line_memo(row, kind) do
    "Unrealized FX #{kind} — #{row.number} (#{row.currency} @ #{row.rate})"
  end

  defp format(:close_run_completed),
    do:
      "the close run is COMPLETED — its figures are a signed fact; start the next period's close"

  defp format(:period_closed),
    do: "the fiscal period is CLOSED — a period-end adjustment cannot be posted into it"

  defp format(:missing_base_currency),
    do:
      "a foreign-currency bill has no functional currency — re-approve it before revaluing the period"

  defp format(:missing_base_amount),
    do:
      "a foreign-currency bill has no functional-currency carrying amount — re-approve it before revaluing the period"

  defp format({:rate_not_found, number, currency, base}),
    do:
      "no #{currency}→#{base} rate is stored at or before the period end for bill #{number}; " <>
        "store the closing rate before posting the revaluation"

  defp format({:unmapped_posting_account, key}),
    do:
      "no PostingAccount row maps `#{key}` for this org — map the unrealized-FX account before posting"

  defp format({:bill_update_failed, bill_id, reason}),
    do: "bill #{bill_id} could not be updated to its carrying amount: #{inspect(reason)}"

  defp format({:entry_failed, reason}),
    do: "the revaluation journal entry failed to land: #{inspect(reason)}"

  defp format({:period_not_found, reason}),
    do: "the close run's period could not be read: #{inspect(reason)}"

  defp format({:close_run_not_in_progress, status}), do: "the close run is #{inspect(status)}"
  defp format({reason, bill_number}), do: "#{inspect(reason)} (bill #{bill_number})"
  defp format(reason), do: inspect(reason)
end
