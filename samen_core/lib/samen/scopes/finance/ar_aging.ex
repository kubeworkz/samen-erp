defmodule Samen.Scopes.Finance.ArAging do
  @moduledoc """
  AR aging and customer statements over the existing AR document spine.

  The SaaS Billing scope is the AR document source of truth (`Invoice`), and a
  `PaymentReceipt` is the GL-side cash intake. This module joins the two WITHOUT
  inventing a second ledger:

    * an invoice contributes its `amount_due_cents` in its own currency;
    * a POSTED invoice-bound `PaymentReceipt` contributes `amount_cents` for its
      `invoice_id` (`invoice_key: "billing_invoice"`);
    * a POSTED on-account `PaymentReceipt` has no invoice anchor. Its
      `amount_cents` is customer credit until `ReceiptAllocation` rows apply it;
      only the allocated amount reduces an invoice, and the remainder is the
      customer's unapplied cash balance;
    * a POSTED (`:open` or `:applied`) `CreditNote` contributes its
      `amount_cents` for its `invoice_id`;
    * outstanding is `amount_due_cents - Σ(applied receipts/allocations) -
      Σ(posted credits)`, floored at zero, and only ever within one currency.

  ## Currency grouping

  Cents in different currencies are never added. `by_currency` carries one
  group per currency, each with its own buckets and total; the top-level
  `total_cents`/`buckets` stay populated only for a single-currency result so a
  caller cannot accidentally treat a mixed total as money. `unapplied_cash`
  and `unapplied_by_currency` carry the customer-credit side.

  The Billing mirror's own `amount_paid_cents` is deliberately ignored: it is the
  provider's view, not the ledger's posted cash. A provider mirror that says
  "paid" while the GL has not received the cash must still age.

  ## Aging buckets

  `:current` (not yet due), `:days_1_30`, `:days_31_60`, `:days_61_90`,
  `:days_90_plus`, and `:undated` (no due date). A zero-outstanding invoice is
  omitted from aging. The statement includes paid invoices for a full history.
  """

  require Ash.Query

  @bucket_keys [
    :current,
    :days_1_30,
    :days_31_60,
    :days_61_90,
    :days_90_plus,
    :undated
  ]

  @type bucket ::
          :current | :days_1_30 | :days_31_60 | :days_61_90 | :days_90_plus | :undated

  @doc """
  Age the supplied invoices as of `opts[:as_of]`.

  Invoice maps use `:id`, `:customer_id`, `:due_date`, `:amount_cents` (or
  `:amount_due_cents`) and `:currency` (default `"USD"`). Receipt maps use
  `:invoice_id` (nil for on-account cash), `:amount_cents`, `:currency` and
  `:customer_id`. Credit maps use `:invoice_id`, `:amount_cents`, `:currency`
  and a posted `:status`. Allocation maps use `:receipt_id`, `:invoice_id`,
  `:amount_cents` and `:currency`.

  Only invoices with a positive outstanding amount appear in the result.
  """
  def aging(invoices, receipts, opts) do
    as_of = Keyword.fetch!(opts, :as_of)
    allocations = Keyword.get(opts, :allocations, [])
    credits = Keyword.get(opts, :credit_notes, [])

    paid = paid_by_invoice(receipts, allocations)
    credited = credited_by_invoice(credits)

    rows =
      invoices
      |> Enum.map(&aging_row(&1, paid, credited, as_of))
      |> Enum.reject(&is_nil/1)
      |> Enum.sort_by(&{&1.currency, &1.due_date || ~D[9999-12-31], &1.invoice_id})

    by_currency =
      rows
      |> Enum.group_by(& &1.currency)
      |> Map.new(fn {currency, currency_rows} ->
        {currency, currency_group(currency, currency_rows)}
      end)

    unapplied = unapplied_cash(receipts, allocations)
    unapplied_by_currency = sum_by_currency(unapplied, & &1.unapplied_cents)
    single = single_currency(by_currency)

    %{
      as_of: as_of,
      invoices: rows,
      customer_ids: customer_ids(invoices),
      currencies: by_currency |> Map.keys() |> Enum.sort(),
      by_currency: by_currency,
      total_cents: single && single.total_cents,
      buckets: single && single.buckets,
      unapplied_cash: unapplied,
      unapplied_by_currency: unapplied_by_currency,
      unapplied_cents: single && Map.get(unapplied_by_currency, single.currency, 0)
    }
  end

  @doc """
  Build a customer statement as of `opts[:as_of]`.

  Includes every invoice for the customer (paid or open), the posted receipts
  and credit applications that settled them, the posted credits that adjusted
  them, the customer's unapplied cash, and currency-grouped totals.
  """
  def statement(invoices, receipts, customer_id, opts) do
    as_of = Keyword.fetch!(opts, :as_of)
    allocations = Keyword.get(opts, :allocations, [])

    customer_invoices =
      invoices
      |> Enum.filter(&(value_of(&1, :customer_id) == customer_id))
      |> Enum.sort_by(&{value_of(&1, :invoice_date) || ~D[9999-12-31], value_of(&1, :id)})

    invoice_ids = MapSet.new(customer_invoices, &value_of(&1, :id))

    customer_receipts =
      receipts
      |> Enum.filter(fn receipt ->
        value_of(receipt, :customer_id) == customer_id or
          MapSet.member?(invoice_ids, value_of(receipt, :invoice_id))
      end)
      |> Enum.sort_by(&sort_time(value_of(&1, :paid_at)))

    receipt_ids = MapSet.new(customer_receipts, &value_of(&1, :id))

    customer_allocations =
      allocations
      |> Enum.filter(fn allocation ->
        MapSet.member?(invoice_ids, value_of(allocation, :invoice_id)) or
          MapSet.member?(receipt_ids, value_of(allocation, :receipt_id))
      end)

    customer_credits =
      opts
      |> Keyword.get(:credit_notes, [])
      |> Enum.filter(&posted_adjustment?/1)
      |> Enum.filter(&MapSet.member?(invoice_ids, value_of(&1, :invoice_id)))
      |> Enum.sort_by(&{date_of(value_of(&1, :date)) || ~D[9999-12-31], value_of(&1, :id)})

    paid = paid_by_invoice(customer_receipts, customer_allocations)
    credited = credited_by_invoice(customer_credits)
    unapplied = unapplied_cash(customer_receipts, customer_allocations, customer_id)

    rows =
      Enum.map(customer_invoices, fn invoice ->
        currency = currency_of(invoice)
        amount = amount_of(invoice)
        paid_cents = Map.get(paid, {value_of(invoice, :id), currency}, 0)
        credited_cents = Map.get(credited, {value_of(invoice, :id), currency}, 0)

        %{
          invoice_id: value_of(invoice, :id),
          invoice_date: value_of(invoice, :invoice_date),
          due_date: value_of(invoice, :due_date),
          currency: currency,
          amount_cents: amount,
          paid_cents: paid_cents,
          credited_cents: credited_cents,
          outstanding_cents: max(amount - paid_cents - credited_cents, 0),
          status: value_of(invoice, :status)
        }
      end)
      |> Enum.sort_by(&{&1.currency, &1.invoice_date || ~D[9999-12-31], &1.invoice_id})

    by_currency = statement_by_currency(rows, unapplied)
    single = single_currency(by_currency)

    %{
      customer_id: customer_id,
      as_of: as_of,
      invoices: rows,
      receipts: customer_receipts,
      credit_notes: customer_credits,
      allocations: customer_allocations,
      unapplied_cash: unapplied,
      currencies: by_currency |> Map.keys() |> Enum.sort(),
      by_currency: by_currency,
      totals: single && single,
      aging:
        aging(customer_invoices, customer_receipts,
          as_of: as_of,
          allocations: customer_allocations,
          credit_notes: customer_credits
        )
    }
  end

  @doc """
  Load open Billing invoices, posted billing receipts, receipt allocations and
  posted credits for an org and return the org-wide aging. Requires `:invoice`,
  `:receipt`, `:org_id`, `:scope` and `:as_of`; `:receipt_allocation` and
  `:credit_note` are optional.
  """
  def for_org(opts) do
    with {:ok, invoices, receipts, allocations, credit_notes} <- load(opts) do
      {:ok,
       aging(invoices, receipts,
         as_of: Keyword.fetch!(opts, :as_of),
         allocations: allocations,
         credit_notes: credit_notes
       )}
    end
  end

  @doc """
  Load the org's AR documents and return one customer's statement. Requires the
  same options as `for_org/1` plus `:customer_id`.
  """
  def statement_for_customer(opts) do
    with {:ok, invoices, receipts, allocations, credit_notes} <- load(opts) do
      customer_id = Keyword.fetch!(opts, :customer_id)

      {:ok,
       statement(invoices, receipts, customer_id,
         as_of: Keyword.fetch!(opts, :as_of),
         allocations: allocations,
         credit_notes: credit_notes
       )}
    end
  end

  defp load(opts) do
    invoice_resource = Keyword.fetch!(opts, :invoice)
    receipt_resource = Keyword.fetch!(opts, :receipt)
    org_id = Keyword.fetch!(opts, :org_id)
    scope = Keyword.fetch!(opts, :scope)

    with {:ok, invoices} <-
           invoice_resource
           |> Ash.Query.filter(org_id == ^org_id and status in [:open, :paid])
           |> Ash.read(scope: scope),
         {:ok, receipts} <-
           receipt_resource
           |> Ash.Query.filter(org_id == ^org_id and status == :posted)
           |> Ash.read(scope: scope),
         {:ok, allocations} <- load_allocations(opts),
         {:ok, credit_notes} <- load_credit_notes(opts) do
      {:ok, Enum.map(invoices, &normalize_invoice/1), Enum.map(receipts, &normalize_receipt/1),
       Enum.map(allocations, &normalize_allocation/1),
       Enum.map(credit_notes, &normalize_credit/1)}
    end
  end

  defp load_allocations(opts) do
    case Keyword.get(opts, :receipt_allocation) do
      nil ->
        {:ok, []}

      resource ->
        org_id = Keyword.fetch!(opts, :org_id)
        scope = Keyword.fetch!(opts, :scope)

        resource
        |> Ash.Query.filter(org_id == ^org_id)
        |> Ash.read(scope: scope)
    end
  end

  defp load_credit_notes(opts) do
    case Keyword.get(opts, :credit_note) do
      nil ->
        {:ok, []}

      resource ->
        org_id = Keyword.fetch!(opts, :org_id)
        scope = Keyword.fetch!(opts, :scope)

        resource
        |> Ash.Query.filter(org_id == ^org_id and status in [:open, :applied])
        |> Ash.read(scope: scope)
    end
  end

  defp normalize_invoice(invoice) do
    %{
      id: invoice.id,
      customer_id: Map.get(invoice, :customer_id),
      invoice_date: date_of(Map.get(invoice, :inserted_at)),
      due_date: date_of(Map.get(invoice, :due_date)),
      amount_cents: Map.get(invoice, :amount_due_cents) || 0,
      currency: Map.get(invoice, :currency) || "USD",
      status: Map.get(invoice, :status)
    }
  end

  defp normalize_receipt(receipt) do
    %{
      id: receipt.id,
      customer_id: Map.get(receipt, :customer_id),
      invoice_id: Map.get(receipt, :invoice_id),
      amount_cents: receipt.amount_cents || 0,
      currency: Map.get(receipt, :currency) || "USD",
      paid_at: Map.get(receipt, :paid_at)
    }
  end

  defp normalize_allocation(allocation) do
    %{
      receipt_id: Map.get(allocation, :receipt_id),
      invoice_id: Map.get(allocation, :invoice_id),
      amount_cents: Map.get(allocation, :amount_cents) || 0,
      currency: Map.get(allocation, :currency) || "USD",
      applied_at: Map.get(allocation, :applied_at)
    }
  end

  defp normalize_credit(credit) do
    %{
      id: credit.id,
      invoice_id: Map.get(credit, :invoice_id),
      number: Map.get(credit, :number),
      kind: Map.get(credit, :kind),
      date: date_of(Map.get(credit, :date)),
      amount_cents: Map.get(credit, :amount_cents) || 0,
      currency: Map.get(credit, :currency) || "USD",
      status: Map.get(credit, :status)
    }
  end

  defp aging_row(invoice, paid, credited, as_of) do
    currency = currency_of(invoice)
    amount = amount_of(invoice)
    paid_cents = Map.get(paid, {value_of(invoice, :id), currency}, 0)
    credited_cents = Map.get(credited, {value_of(invoice, :id), currency}, 0)
    outstanding = amount - paid_cents - credited_cents

    if outstanding > 0 do
      due_date = date_of(Map.get(invoice, :due_date))
      days_overdue = days_overdue(due_date, as_of)

      %{
        invoice_id: value_of(invoice, :id),
        customer_id: value_of(invoice, :customer_id),
        currency: currency,
        due_date: due_date,
        amount_cents: amount,
        paid_cents: paid_cents,
        credited_cents: credited_cents,
        outstanding_cents: outstanding,
        days_overdue: days_overdue,
        bucket: bucket_for(due_date, days_overdue)
      }
    end
  end

  defp amount_of(invoice) do
    Map.get(invoice, :amount_cents) || Map.get(invoice, :amount_due_cents) || 0
  end

  defp currency_of(map) do
    case value_of(map, :currency) do
      currency when is_binary(currency) and currency != "" -> String.upcase(currency)
      _ -> "USD"
    end
  end

  defp paid_by_invoice(receipts, allocations) do
    receipt_totals =
      receipts
      |> Enum.filter(&value_of(&1, :invoice_id))
      |> Enum.reduce(%{}, fn receipt, acc ->
        add_amount(acc, value_of(receipt, :invoice_id), currency_of(receipt), receipt)
      end)

    allocation_totals =
      Enum.reduce(allocations, %{}, fn allocation, acc ->
        add_amount(acc, value_of(allocation, :invoice_id), currency_of(allocation), allocation)
      end)

    Map.merge(receipt_totals, allocation_totals, fn _key, left, right -> left + right end)
  end

  defp add_amount(acc, invoice_id, currency, map) do
    amount = Map.get(map, :amount_cents) || Map.get(map, "amount_cents") || 0
    Map.update(acc, {invoice_id, currency}, amount, &(&1 + amount))
  end

  defp credited_by_invoice(credits) do
    credits
    |> Enum.filter(&posted_adjustment?/1)
    |> Enum.reduce(%{}, fn credit, acc ->
      case value_of(credit, :invoice_id) do
        nil ->
          acc

        invoice_id ->
          amount = value_of(credit, :amount_cents) || 0
          key = {invoice_id, currency_of(credit)}
          Map.update(acc, key, amount, &(&1 + amount))
      end
    end)
  end

  defp unapplied_cash(receipts, allocations, customer_id \\ nil) do
    applied_by_receipt =
      Enum.reduce(allocations, %{}, fn allocation, acc ->
        receipt_id = value_of(allocation, :receipt_id)
        amount = value_of(allocation, :amount_cents) || 0
        Map.update(acc, receipt_id, amount, &(&1 + amount))
      end)

    receipts
    |> Enum.filter(&is_nil(value_of(&1, :invoice_id)))
    |> Enum.filter(fn receipt ->
      is_nil(customer_id) or value_of(receipt, :customer_id) == customer_id
    end)
    |> Enum.map(fn receipt ->
      amount = value_of(receipt, :amount_cents) || 0
      applied = Map.get(applied_by_receipt, value_of(receipt, :id), 0)

      %{
        receipt_id: value_of(receipt, :id),
        customer_id: value_of(receipt, :customer_id),
        currency: currency_of(receipt),
        amount_cents: amount,
        applied_cents: min(applied, amount),
        unapplied_cents: max(amount - applied, 0),
        paid_at: value_of(receipt, :paid_at)
      }
    end)
    |> Enum.filter(&(&1.unapplied_cents > 0))
    |> Enum.sort_by(&{&1.currency, sort_time(&1.paid_at), to_string(&1.receipt_id)})
  end

  defp currency_group(currency, rows) do
    buckets =
      Enum.reduce(rows, empty_buckets(), fn row, acc ->
        Map.update!(acc, row.bucket, &(&1 + row.outstanding_cents))
      end)

    %{
      currency: currency,
      total_cents: Enum.reduce(rows, 0, &(&1.outstanding_cents + &2)),
      buckets: buckets
    }
  end

  defp statement_by_currency(rows, unapplied) do
    rows
    |> Enum.group_by(& &1.currency)
    |> Map.new(fn {currency, currency_rows} ->
      invoiced = Enum.reduce(currency_rows, 0, &(&1.amount_cents + &2))
      paid = Enum.reduce(currency_rows, 0, &(&1.paid_cents + &2))
      credited = Enum.reduce(currency_rows, 0, &(&1.credited_cents + &2))
      outstanding = Enum.reduce(currency_rows, 0, &(&1.outstanding_cents + &2))

      unapplied_cents =
        unapplied
        |> Enum.filter(&(&1.currency == currency))
        |> Enum.reduce(0, &(&1.unapplied_cents + &2))

      {currency,
       %{
         currency: currency,
         invoiced_cents: invoiced,
         paid_cents: paid,
         credited_cents: credited,
         outstanding_cents: outstanding,
         unapplied_cents: unapplied_cents
       }}
    end)
  end

  defp single_currency(by_currency) do
    case Map.values(by_currency) do
      [single] ->
        Map.put(single, :currency, single.currency)

      [] ->
        %{
          currency: nil,
          total_cents: 0,
          buckets: empty_buckets(),
          invoiced_cents: 0,
          paid_cents: 0,
          credited_cents: 0,
          outstanding_cents: 0,
          unapplied_cents: 0
        }

      _multiple ->
        nil
    end
  end

  defp sum_by_currency(items, amount_fun) do
    Enum.reduce(items, %{}, fn item, acc ->
      Map.update(acc, item.currency, amount_fun.(item), &(&1 + amount_fun.(item)))
    end)
  end

  defp customer_ids(invoices) do
    invoices
    |> Enum.map(&value_of(&1, :customer_id))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp posted_adjustment?(credit) do
    value_of(credit, :status) in [:open, :applied, "open", "applied"]
  end

  defp value_of(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp value_of(_other, _key), do: nil

  defp days_overdue(nil, _as_of), do: nil

  defp days_overdue(due_date, as_of) do
    max(Date.diff(as_of, due_date), 0)
  end

  defp bucket_for(nil, _days), do: :undated
  defp bucket_for(_due_date, 0), do: :current
  defp bucket_for(_due_date, days) when days <= 30, do: :days_1_30
  defp bucket_for(_due_date, days) when days <= 60, do: :days_31_60
  defp bucket_for(_due_date, days) when days <= 90, do: :days_61_90
  defp bucket_for(_due_date, _days), do: :days_90_plus

  defp empty_buckets, do: Map.new(@bucket_keys, &{&1, 0})

  defp date_of(%Date{} = date), do: date
  defp date_of(%DateTime{} = datetime), do: DateTime.to_date(datetime)
  defp date_of(%NaiveDateTime{} = datetime), do: NaiveDateTime.to_date(datetime)
  defp date_of(_), do: nil

  defp sort_time(nil), do: ~U[9999-12-31 00:00:00Z]
  defp sort_time(%DateTime{} = datetime), do: datetime
  defp sort_time(%NaiveDateTime{} = datetime), do: DateTime.from_naive!(datetime, "Etc/UTC")
  defp sort_time(_), do: ~U[9999-12-31 00:00:00Z]
end
