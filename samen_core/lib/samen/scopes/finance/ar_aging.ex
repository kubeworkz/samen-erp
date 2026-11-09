defmodule Samen.Scopes.Finance.ArAging do
  @moduledoc """
  AR aging and customer statements over the existing AR document spine.

  The SaaS Billing scope is the AR document source of truth (`Invoice`), and a
  `PaymentReceipt` is the GL-side cash intake. This module joins the two WITHOUT
  inventing a second ledger:

    * an invoice contributes its `amount_due_cents`;
    * a POSTED `PaymentReceipt` contributes `amount_cents` for its
      `invoice_id` (`invoice_key: "billing_invoice"`);
    * outstanding is `amount_due_cents - Σ(posted receipts)`, floored at zero.

  The Billing mirror's own `amount_paid_cents` is deliberately ignored: it is the
  provider's view, not the ledger's posted cash. A provider mirror that says
  "paid" while the GL has not received the cash must still age.

  ## Aging buckets

  `:current` (not yet due), `:days_1_30`, `:days_31_60`, `:days_61_90`,
  `:days_90_plus`, and `:undated` (no due date). A zero-outstanding invoice is
  omitted from aging. The statement includes paid invoices for a full history.

  ## Integration

      {:ok, aging} =
        Samen.Scopes.Finance.ArAging.for_org(
          invoice: Samenerp.Billing.Invoice,
          receipt: Samenerp.Erp.PaymentReceipt,
          org_id: org_id,
          scope: scope,
          as_of: ~D[2026-11-08]
        )

      {:ok, statement} =
        Samen.Scopes.Finance.ArAging.statement_for_customer(
          invoice: Samenerp.Billing.Invoice,
          receipt: Samenerp.Erp.PaymentReceipt,
          org_id: org_id,
          scope: scope,
          customer_id: customer_id,
          as_of: ~D[2026-11-08]
        )

  The pure `aging/3` and `statement/4` functions accept already-loaded maps, so
  hosts can feed a different invoice/receipt source without changing the math.
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
  `:amount_due_cents`). Receipt maps use `:invoice_id` and `:amount_cents`.
  Only invoices with a positive outstanding amount appear in the result.
  """
  def aging(invoices, receipts, opts) do
    as_of = Keyword.fetch!(opts, :as_of)
    paid = paid_by_invoice(receipts)

    rows =
      invoices
      |> Enum.map(&aging_row(&1, paid, as_of))
      |> Enum.reject(&is_nil/1)
      |> Enum.sort_by(&{&1.due_date || ~D[9999-12-31], &1.invoice_id})

    buckets =
      Enum.reduce(rows, empty_buckets(), fn row, acc ->
        Map.update!(acc, row.bucket, &(&1 + row.outstanding_cents))
      end)

    %{
      as_of: as_of,
      total_cents: Enum.reduce(rows, 0, &(&1.outstanding_cents + &2)),
      buckets: buckets,
      invoices: rows
    }
  end

  @doc """
  Build a customer statement as of `opts[:as_of]`.

  Includes every invoice for the customer (paid or open), the posted receipts
  that settled those invoices, the outstanding total and the customer's aging.
  """
  def statement(invoices, receipts, customer_id, opts) do
    as_of = Keyword.fetch!(opts, :as_of)

    customer_invoices =
      invoices
      |> Enum.filter(&(&1.customer_id == customer_id))
      |> Enum.sort_by(&{&1.invoice_date || ~D[9999-12-31], &1.id})

    invoice_ids = MapSet.new(customer_invoices, & &1.id)

    customer_receipts =
      receipts
      |> Enum.filter(&MapSet.member?(invoice_ids, &1.invoice_id))
      |> Enum.sort_by(&sort_time(&1.paid_at))

    paid = paid_by_invoice(customer_receipts)

    rows =
      Enum.map(customer_invoices, fn invoice ->
        amount = amount_of(invoice)
        paid_cents = Map.get(paid, invoice.id, 0)

        %{
          invoice_id: invoice.id,
          invoice_date: invoice.invoice_date,
          due_date: invoice.due_date,
          amount_cents: amount,
          paid_cents: paid_cents,
          outstanding_cents: max(amount - paid_cents, 0),
          status: Map.get(invoice, :status)
        }
      end)

    total_invoiced = Enum.reduce(rows, 0, &(&1.amount_cents + &2))
    total_paid = Enum.reduce(customer_receipts, 0, &(&1.amount_cents + &2))
    outstanding = Enum.reduce(rows, 0, &(&1.outstanding_cents + &2))

    %{
      customer_id: customer_id,
      as_of: as_of,
      invoices: rows,
      receipts: customer_receipts,
      totals: %{
        invoiced_cents: total_invoiced,
        paid_cents: total_paid,
        outstanding_cents: outstanding
      },
      aging: aging(customer_invoices, customer_receipts, as_of: as_of)
    }
  end

  @doc """
  Load open Billing invoices and posted billing receipts for an org and return
  the org-wide aging. Requires `:invoice`, `:receipt`, `:org_id`, `:scope` and
  `:as_of`.
  """
  def for_org(opts) do
    with {:ok, invoices, receipts} <- load(opts) do
      {:ok, aging(invoices, receipts, as_of: Keyword.fetch!(opts, :as_of))}
    end
  end

  @doc """
  Load the org's AR documents and return one customer's statement. Requires the
  same options as `for_org/1` plus `:customer_id`.
  """
  def statement_for_customer(opts) do
    with {:ok, invoices, receipts} <- load(opts) do
      customer_id = Keyword.fetch!(opts, :customer_id)

      {:ok, statement(invoices, receipts, customer_id, as_of: Keyword.fetch!(opts, :as_of))}
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
           |> Ash.Query.filter(
             org_id == ^org_id and status == :posted and invoice_key == "billing_invoice"
           )
           |> Ash.read(scope: scope) do
      {:ok, Enum.map(invoices, &normalize_invoice/1), Enum.map(receipts, &normalize_receipt/1)}
    end
  end

  defp normalize_invoice(invoice) do
    %{
      id: invoice.id,
      customer_id: invoice.customer_id,
      invoice_date: date_of(Map.get(invoice, :inserted_at)),
      due_date: date_of(Map.get(invoice, :due_date)),
      amount_cents: Map.get(invoice, :amount_due_cents) || 0,
      status: Map.get(invoice, :status)
    }
  end

  defp normalize_receipt(receipt) do
    %{
      id: receipt.id,
      invoice_id: receipt.invoice_id,
      amount_cents: receipt.amount_cents || 0,
      paid_at: Map.get(receipt, :paid_at)
    }
  end

  defp aging_row(invoice, paid, as_of) do
    amount = amount_of(invoice)
    paid_cents = Map.get(paid, invoice.id, 0)
    outstanding = amount - paid_cents

    if outstanding > 0 do
      due_date = date_of(Map.get(invoice, :due_date))
      days_overdue = days_overdue(due_date, as_of)

      %{
        invoice_id: invoice.id,
        customer_id: invoice.customer_id,
        due_date: due_date,
        amount_cents: amount,
        paid_cents: paid_cents,
        outstanding_cents: outstanding,
        days_overdue: days_overdue,
        bucket: bucket_for(due_date, days_overdue)
      }
    end
  end

  defp amount_of(invoice) do
    Map.get(invoice, :amount_cents) || Map.get(invoice, :amount_due_cents) || 0
  end

  defp paid_by_invoice(receipts) do
    Enum.reduce(receipts, %{}, fn receipt, acc ->
      Map.update(
        acc,
        receipt.invoice_id,
        receipt.amount_cents || 0,
        &(&1 + (receipt.amount_cents || 0))
      )
    end)
  end

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
