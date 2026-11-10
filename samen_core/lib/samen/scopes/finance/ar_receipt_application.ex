defmodule Samen.Scopes.Finance.ArReceiptApplication do
  @moduledoc """
  Applies customer cash across open Billing invoices and records on-account
  cash.

  A cash payment is an EXECUTION over the existing `PaymentReceipt` resource:

    * each invoice allocation creates one invoice-bound receipt and its posted
      cash+AR entry;
    * any unapplied part (an explicit amount or the excess over an invoice's
      outstanding balance) creates ONE on-account receipt, anchored to the
      customer and currency, with the same posted entry shape;
    * later, `apply_credit/1` applies that on-account receipt to invoices by
      writing immutable `ReceiptAllocation` rows. The cash already posted, so
      allocating it does not create a second ledger entry.

  The service is the transactional boundary. It reads the customer's statement
  through `Samen.Scopes.Finance.ArAging`, derives/validates the payment currency,
  refuses stale or cross-customer invoices BEFORE writing, then creates and
  posts every receipt inside one repository transaction. A receipt never
  settles an invoice in another currency.

  The durable facts are the posted receipts, allocations and their entries.
  There is no separate batch header, matching the AP payment-run posture.
  """

  require Ash.Query

  alias Samen.Scopes.Finance.ArAging

  @invoice_key "billing_invoice"

  @type allocation :: %{invoice_id: String.t(), amount_cents: pos_integer()}

  @type run :: %{
          reference: String.t(),
          customer_id: String.t(),
          paid_at: DateTime.t(),
          currency: String.t(),
          total_cents: non_neg_integer(),
          applied_cents: non_neg_integer(),
          unapplied_cents: non_neg_integer(),
          receipts: [struct()],
          credit_receipt: struct() | nil
        }

  @doc """
  Apply `:allocations` and/or `:unapplied_cents` to a customer's account.

  Required options: `:invoice`, `:receipt`, `:repo`, `:scope`, `:org_id`,
  `:customer_id` and `:paid_at`. Optional: `:credit_note` (posted AR
  adjustments net the invoice), `:receipt_allocation` (enables later credit
  applications), `:reference`, `:memo`, `:currency` and `:unapplied_cents`.

  Each allocation is `%{invoice_id: id, amount_cents: positive_integer}`. An
  allocation above the invoice's outstanding balance is applied up to that
  balance; the excess joins the customer's unapplied cash. `:currency` is
  derived from the invoices when omitted; it is REQUIRED for a pure on-account
  payment and is refused if it disagrees with an invoice's currency.

  Returns `{:ok, run}` or `{:error, reason}`. On error nothing is posted.
  """
  @spec apply(keyword()) :: {:ok, run()} | {:error, term()}
  def apply(opts) do
    receipt_resource = Keyword.fetch!(opts, :receipt)
    invoice_resource = Keyword.fetch!(opts, :invoice)
    receipt_allocation_resource = Keyword.get(opts, :receipt_allocation)
    repo = Keyword.fetch!(opts, :repo)
    scope = Keyword.fetch!(opts, :scope)
    org_id = Keyword.fetch!(opts, :org_id)
    customer_id = Keyword.get(opts, :customer_id)
    paid_at = Keyword.get(opts, :paid_at)
    reference = Keyword.get(opts, :reference)
    memo = Keyword.get(opts, :memo)
    currency = normalize_currency(Keyword.get(opts, :currency))
    explicit_unapplied = Keyword.get(opts, :unapplied_cents, 0)

    with :ok <- validate_customer(customer_id),
         {:ok, paid_at} <- normalize_paid_at(paid_at),
         {:ok, allocations} <- normalize_allocations(Keyword.get(opts, :allocations)),
         {:ok, explicit_unapplied} <- normalize_unapplied(explicit_unapplied),
         {:ok, statement} <-
           load_statement(
             invoice_resource,
             receipt_resource,
             receipt_allocation_resource,
             Keyword.get(opts, :credit_note),
             org_id,
             scope,
             customer_id,
             paid_at
           ),
         {:ok, plan} <- plan_allocations(allocations, statement, currency, explicit_unapplied),
         :ok <- validate_not_posted(receipt_resource, org_id, scope, plan.applied) do
      reference = normalize_reference(reference, paid_at)

      case repo.transaction(fn ->
             execute(
               plan,
               receipt_resource,
               scope,
               org_id,
               customer_id,
               paid_at,
               reference,
               memo,
               repo
             )
           end) do
        {:ok, run} ->
          # Ash collects notifications while the resources are inside our
          # transaction; dispatch them only AFTER the commit so a rolled-back
          # payment notifies nobody.
          Ash.Notifier.notify(run.notifications)
          {:ok, Map.delete(run, :notifications)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Apply part of a posted on-account receipt to one open invoice.

  Required options: `:invoice`, `:receipt`, `:receipt_allocation`, `:repo`,
  `:scope`, `:org_id`, `:customer_id`, `:receipt_id`, `:invoice_id` and
  `:amount_cents`. Optional `:applied_at` defaults to now. The receipt must be
  POSTED, on-account, in the same org/customer, and have enough remaining
  credit; the invoice must be open or paid in the SAME currency. Returns
  `{:ok, allocation}`.
  """
  @spec apply_credit(keyword()) :: {:ok, struct()} | {:error, term()}
  def apply_credit(opts) do
    receipt_resource = Keyword.fetch!(opts, :receipt)
    allocation_resource = Keyword.fetch!(opts, :receipt_allocation)
    invoice_resource = Keyword.fetch!(opts, :invoice)
    repo = Keyword.fetch!(opts, :repo)
    scope = Keyword.fetch!(opts, :scope)
    org_id = Keyword.fetch!(opts, :org_id)
    customer_id = Keyword.fetch!(opts, :customer_id)
    receipt_id = Keyword.fetch!(opts, :receipt_id)
    invoice_id = Keyword.fetch!(opts, :invoice_id)
    amount = Keyword.fetch!(opts, :amount_cents)
    applied_at = Keyword.get(opts, :applied_at, DateTime.utc_now())

    with :ok <- validate_customer(customer_id),
         true <- (is_integer(amount) and amount > 0) || {:error, :allocation_amount_invalid},
         {:ok, applied_at} <- normalize_paid_at(applied_at) do
      case repo.transaction(fn ->
             with {:ok, receipt} <- fetch_receipt(receipt_resource, org_id, receipt_id, scope),
                  :ok <- validate_on_account_receipt(receipt, customer_id),
                  {:ok, statement} <-
                    load_statement(
                      invoice_resource,
                      receipt_resource,
                      allocation_resource,
                      Keyword.get(opts, :credit_note),
                      org_id,
                      scope,
                      customer_id,
                      applied_at
                    ),
                  {:ok, invoice_row} <- fetch_invoice(statement, invoice_id),
                  :ok <- validate_credit_currency(receipt, invoice_row),
                  remaining = remaining_credit(statement, receipt),
                  :ok <- validate_credit_amount(amount, remaining, invoice_row) do
               case allocation_resource
                    |> Ash.Changeset.for_create(
                      :create,
                      %{
                        org_id: org_id,
                        receipt_id: receipt.id,
                        invoice_key: @invoice_key,
                        invoice_id: invoice_id,
                        amount_cents: amount,
                        currency: receipt.currency,
                        applied_at: applied_at
                      },
                      scope: scope
                    )
                    |> Ash.create() do
                 {:ok, allocation} -> allocation
                 {:error, reason} -> repo.rollback(reason)
               end
             else
               {:error, reason} -> repo.rollback(reason)
             end
           end) do
        {:ok, allocation} -> {:ok, allocation}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp execute(
         plan,
         receipt_resource,
         scope,
         org_id,
         customer_id,
         paid_at,
         reference,
         memo,
         repo
       ) do
    {receipts, notifications} =
      Enum.map_reduce(plan.applied, [], fn allocation, notifications ->
        attrs = %{
          org_id: org_id,
          customer_id: customer_id,
          invoice_key: @invoice_key,
          invoice_id: allocation.invoice_id,
          amount_cents: allocation.amount_cents,
          currency: plan.currency,
          paid_at: paid_at,
          memo: receipt_memo(reference, customer_id, memo)
        }

        case receipt_resource
             |> Ash.Changeset.for_create(:create, attrs, scope: scope)
             |> Ash.create(return_notifications?: true) do
          {:ok, receipt, created} ->
            {posted, posted_notifications} = post_receipt(receipt, scope, repo)
            {posted, notifications ++ created ++ posted_notifications}

          {:error, reason} ->
            repo.rollback({:receipt_create_failed, allocation.invoice_id, reason})
        end
      end)

    {credit_receipts, notifications} =
      if plan.unapplied_cents > 0 do
        attrs = %{
          org_id: org_id,
          customer_id: customer_id,
          invoice_key: nil,
          invoice_id: nil,
          amount_cents: plan.unapplied_cents,
          currency: plan.currency,
          paid_at: paid_at,
          memo: receipt_memo(reference, customer_id, memo) <> " — unapplied cash"
        }

        case receipt_resource
             |> Ash.Changeset.for_create(:create, attrs, scope: scope)
             |> Ash.create(return_notifications?: true) do
          {:ok, receipt, created} ->
            {posted, posted_notifications} = post_receipt(receipt, scope, repo)
            {[posted], notifications ++ created ++ posted_notifications}

          {:error, reason} ->
            repo.rollback({:receipt_create_failed, :on_account, reason})
        end
      else
        {[], notifications}
      end

    receipts = receipts ++ credit_receipts

    %{
      reference: reference,
      customer_id: customer_id,
      paid_at: paid_at,
      currency: plan.currency,
      total_cents: Enum.reduce(receipts, 0, fn receipt, acc -> acc + receipt.amount_cents end),
      applied_cents: Enum.reduce(plan.applied, 0, &(&1.amount_cents + &2)),
      unapplied_cents: plan.unapplied_cents,
      receipts: receipts,
      credit_receipt: List.first(credit_receipts),
      notifications: notifications
    }
  end

  defp post_receipt(receipt, scope, repo) do
    case receipt
         |> Ash.Changeset.for_update(:post_receipt, %{}, scope: scope)
         |> Ash.update(return_notifications?: true) do
      {:ok, posted, notifications} ->
        {posted, notifications}

      {:error, reason} ->
        repo.rollback({:receipt_post_failed, receipt.id, reason})
    end
  end

  defp load_statement(
         invoice_resource,
         receipt_resource,
         receipt_allocation_resource,
         credit_note_resource,
         org_id,
         scope,
         customer_id,
         paid_at
       ) do
    case ArAging.statement_for_customer(
           invoice: invoice_resource,
           receipt: receipt_resource,
           receipt_allocation: receipt_allocation_resource,
           credit_note: credit_note_resource,
           org_id: org_id,
           scope: scope,
           customer_id: customer_id,
           as_of: DateTime.to_date(paid_at)
         ) do
      {:ok, statement} -> {:ok, statement}
      {:error, reason} -> {:error, {:statement_unreadable, reason}}
    end
  end

  defp plan_allocations(allocations, statement, requested_currency, explicit_unapplied) do
    by_invoice = Map.new(statement.invoices, &{&1.invoice_id, &1})
    selected_rows = Enum.map(allocations, &Map.get(by_invoice, &1.invoice_id))

    selected_currencies =
      selected_rows |> Enum.reject(&is_nil/1) |> Enum.map(& &1.currency) |> Enum.uniq()

    missing = Enum.find(allocations, &(not Map.has_key?(by_invoice, &1.invoice_id)))

    settled =
      Enum.find(allocations, fn allocation ->
        case Map.fetch(by_invoice, allocation.invoice_id) do
          {:ok, row} -> row.outstanding_cents <= 0
          :error -> false
        end
      end)

    cond do
      missing ->
        {:error, {:invoice_not_found, missing.invoice_id}}

      settled ->
        {:error, {:invoice_already_paid, settled.invoice_id}}

      length(selected_currencies) > 1 ->
        {:error, {:mixed_currencies, selected_currencies}}

      is_nil(requested_currency) and selected_currencies == [] and explicit_unapplied == 0 ->
        {:error, :allocations_required}

      true ->
        derived_currency = List.first(selected_currencies)
        currency = requested_currency || derived_currency

        cond do
          is_nil(currency) ->
            {:error, :currency_required}

          not is_nil(derived_currency) and currency != derived_currency ->
            {:error, {:currency_mismatch, currency, derived_currency}}

          true ->
            reduce_allocations(allocations, by_invoice, currency, explicit_unapplied)
        end
    end
  end

  defp reduce_allocations(allocations, by_invoice, currency, explicit_unapplied) do
    {applied, overage} =
      Enum.reduce(allocations, {[], 0}, fn allocation, {applied, overage} ->
        case Map.fetch(by_invoice, allocation.invoice_id) do
          :error ->
            throw({:invoice_not_found, allocation.invoice_id})

          {:ok, row} ->
            if row.currency != currency do
              throw({:currency_mismatch, currency, row.currency})
            else
              amount = allocation.amount_cents
              applied_cents = min(amount, max(row.outstanding_cents, 0))

              applied =
                if applied_cents > 0 do
                  [%{invoice_id: allocation.invoice_id, amount_cents: applied_cents} | applied]
                else
                  applied
                end

              {applied, overage + (amount - applied_cents)}
            end
        end
      end)

    unapplied = overage + explicit_unapplied
    applied = Enum.reverse(applied)

    if applied == [] and unapplied == 0 do
      {:error, :allocations_required}
    else
      {:ok, %{currency: currency, applied: applied, unapplied_cents: unapplied}}
    end
  catch
    {:invoice_not_found, invoice_id} -> {:error, {:invoice_not_found, invoice_id}}
    {:currency_mismatch, expected, actual} -> {:error, {:currency_mismatch, expected, actual}}
  end

  defp validate_not_posted(receipt_resource, org_id, scope, allocations) do
    ids = Enum.map(allocations, & &1.invoice_id)
    invoice_key = @invoice_key

    case receipt_resource
         |> Ash.Query.filter(
           org_id == ^org_id and invoice_key == ^invoice_key and status == :posted and
             invoice_id in ^ids
         )
         |> Ash.read(scope: scope) do
      {:ok, []} ->
        :ok

      {:ok, [receipt | _rest]} ->
        {:error, {:already_applied, receipt.invoice_id}}

      {:error, reason} ->
        {:error, {:receipt_read_failed, reason}}
    end
  end

  defp fetch_receipt(resource, org_id, receipt_id, scope) do
    case resource
         |> Ash.Query.filter(id == ^receipt_id and org_id == ^org_id)
         |> Ash.read_one(scope: scope) do
      {:ok, nil} -> {:error, :receipt_not_found}
      {:ok, receipt} -> {:ok, receipt}
      {:error, _reason} -> {:error, :receipt_not_found}
    end
  end

  defp validate_on_account_receipt(receipt, customer_id) do
    cond do
      Map.get(receipt, :customer_id) != customer_id ->
        {:error, :customer_mismatch}

      Map.get(receipt, :status) != :posted ->
        {:error, :credit_not_posted}

      not is_nil(Map.get(receipt, :invoice_id)) ->
        {:error, :not_on_account}

      true ->
        :ok
    end
  end

  defp fetch_invoice(statement, invoice_id) do
    case Enum.find(statement.invoices, &(&1.invoice_id == invoice_id)) do
      nil -> {:error, {:invoice_not_found, invoice_id}}
      row -> {:ok, row}
    end
  end

  defp validate_credit_currency(receipt, invoice_row) do
    if receipt.currency == invoice_row.currency,
      do: :ok,
      else: {:error, {:currency_mismatch, receipt.currency, invoice_row.currency}}
  end

  defp remaining_credit(statement, receipt) do
    applied =
      statement.allocations
      |> Enum.filter(&(&1.receipt_id == receipt.id))
      |> Enum.reduce(0, &(&1.amount_cents + &2))

    max(receipt.amount_cents - applied, 0)
  end

  defp validate_credit_amount(amount, remaining, invoice_row) do
    cond do
      amount <= 0 ->
        {:error, :allocation_amount_invalid}

      amount > remaining ->
        {:error, {:credit_exceeded, remaining}}

      amount > invoice_row.outstanding_cents ->
        {:error, {:over_allocation, invoice_row.invoice_id, invoice_row.outstanding_cents}}

      true ->
        :ok
    end
  end

  defp validate_customer(customer_id) when is_binary(customer_id) do
    if String.trim(customer_id) == "", do: {:error, :customer_required}, else: :ok
  end

  defp validate_customer(_customer_id), do: {:error, :customer_required}

  defp normalize_currency(nil), do: nil

  defp normalize_currency(value) when is_binary(value) do
    case value |> String.trim() |> String.upcase() do
      "" -> nil
      currency -> currency
    end
  end

  defp normalize_currency(_value), do: nil

  defp normalize_unapplied(value) when is_integer(value) and value >= 0, do: {:ok, value}

  defp normalize_unapplied(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {cents, ""} when cents >= 0 -> {:ok, cents}
      _other -> {:error, :unapplied_amount_invalid}
    end
  end

  defp normalize_unapplied(nil), do: {:ok, 0}
  defp normalize_unapplied(_value), do: {:error, :unapplied_amount_invalid}

  defp normalize_paid_at(%DateTime{} = paid_at),
    do: {:ok, DateTime.truncate(paid_at, :second)}

  defp normalize_paid_at(%NaiveDateTime{} = paid_at) do
    case DateTime.from_naive(paid_at, "Etc/UTC") do
      {:ok, datetime} -> {:ok, DateTime.truncate(datetime, :second)}
      {:error, _reason} -> {:error, :paid_at_required}
    end
  end

  defp normalize_paid_at(%Date{} = date) do
    case DateTime.new(date, ~T[00:00:00], "Etc/UTC") do
      {:ok, datetime} -> {:ok, datetime}
      {:error, _reason} -> {:error, :paid_at_required}
    end
  end

  defp normalize_paid_at(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} ->
        {:ok, DateTime.truncate(datetime, :second)}

      {:error, _reason} ->
        case Date.from_iso8601(value) do
          {:ok, date} -> normalize_paid_at(date)
          {:error, _reason} -> {:error, :paid_at_required}
        end
    end
  end

  defp normalize_paid_at(_paid_at), do: {:error, :paid_at_required}

  defp normalize_allocations(nil), do: {:ok, []}
  defp normalize_allocations([]), do: {:ok, []}

  defp normalize_allocations(allocations) when is_list(allocations) do
    allocations
    |> Enum.reduce_while({:ok, [], MapSet.new()}, fn raw, {:ok, acc, seen} ->
      with {:ok, allocation} <- normalize_allocation(raw),
           false <- MapSet.member?(seen, allocation.invoice_id) do
        {:cont, {:ok, [allocation | acc], MapSet.put(seen, allocation.invoice_id)}}
      else
        true -> {:halt, {:error, :duplicate_allocation}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc, _seen} -> {:ok, Enum.reverse(acc)}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_allocations(_allocations), do: {:error, :allocations_required}

  defp normalize_allocation(raw) when is_map(raw) do
    invoice_id = Map.get(raw, :invoice_id) || Map.get(raw, "invoice_id")
    amount = Map.get(raw, :amount_cents) || Map.get(raw, "amount_cents")

    cond do
      not is_binary(invoice_id) or String.trim(invoice_id) == "" ->
        {:error, :invoice_id_required}

      not is_integer(amount) or amount <= 0 ->
        {:error, :allocation_amount_invalid}

      true ->
        {:ok, %{invoice_id: String.trim(invoice_id), amount_cents: amount}}
    end
  end

  defp normalize_allocation(_raw), do: {:error, :allocation_shape_invalid}

  defp normalize_reference(reference, paid_at) when is_binary(reference) do
    case String.trim(reference) do
      "" -> generated_reference(paid_at)
      value -> value
    end
  end

  defp normalize_reference(_reference, paid_at), do: generated_reference(paid_at)

  defp generated_reference(paid_at) do
    suffix = Ash.UUID.generate() |> binary_part(0, 8) |> String.upcase()
    "ARRCPT-#{Date.to_iso8601(DateTime.to_date(paid_at))}-#{suffix}"
  end

  defp receipt_memo(reference, customer_id, memo) do
    base = "AR receipt #{reference} — customer #{customer_id}"

    case memo do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> base
          trimmed -> base <> " — " <> trimmed
        end

      _other ->
        base
    end
  end
end
