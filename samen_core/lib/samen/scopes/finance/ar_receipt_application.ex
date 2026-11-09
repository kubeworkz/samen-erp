defmodule Samen.Scopes.Finance.ArReceiptApplication do
  @moduledoc """
  Applies one customer payment across several open Billing invoices.

  The existing `PaymentReceipt` is the AR cash intake for ONE invoice: it
  anchors the invoice and posts the cash+AR-clearing entry exactly once. A
  multi-invoice payment is therefore an EXECUTION over that same resource, not
  a second ledger shape: each selected invoice gets its own receipt row and its
  own posted entry, and the shared reference groups the applications.

  The service is the transactional boundary. It reads the customer's statement
  through `Samen.Scopes.Finance.ArAging`, refuses stale or over-allocated
  invoices BEFORE writing, then creates and posts every receipt inside one
  repository transaction. A failure on any allocation rolls the whole payment
  back — nothing is partially applied.

  The durable facts are the posted receipts and their entries. There is no
  separate batch header, matching the AP payment-run posture.

  ## Example

      {:ok, run} =
        Samen.Scopes.Finance.ArReceiptApplication.apply(
          invoice: MyApp.Billing.Invoice,
          receipt: MyApp.Erp.PaymentReceipt,
          repo: MyApp.Repo,
          scope: scope,
          org_id: org_id,
          customer_id: customer_id,
          paid_at: ~U[2026-11-08 00:00:00Z],
          reference: "DEP-100",
          allocations: [
            %{invoice_id: first.id, amount_cents: 10_000},
            %{invoice_id: second.id, amount_cents: 4_000}
          ]
        )
  """

  require Ash.Query

  alias Samen.Scopes.Finance.ArAging

  @invoice_key "billing_invoice"

  @type allocation :: %{invoice_id: String.t(), amount_cents: pos_integer()}

  @type run :: %{
          reference: String.t(),
          customer_id: String.t(),
          paid_at: DateTime.t(),
          total_cents: non_neg_integer(),
          receipts: [struct()]
        }

  @doc """
  Apply `:allocations` to the customer's open invoices.

  Required options: `:invoice`, `:receipt`, `:repo`, `:scope`, `:org_id`,
  `:customer_id`, `:paid_at` and `:allocations`. Optional: `:reference`,
  `:memo` and `:currency` (default `"USD"`).

  Each allocation is `%{invoice_id: id, amount_cents: positive_integer}`.
  Returns `{:ok, run}` or `{:error, reason}`. On error no receipt is posted.
  """
  @spec apply(keyword()) :: {:ok, run()} | {:error, term()}
  def apply(opts) do
    receipt_resource = Keyword.fetch!(opts, :receipt)
    invoice_resource = Keyword.fetch!(opts, :invoice)
    repo = Keyword.fetch!(opts, :repo)
    scope = Keyword.fetch!(opts, :scope)
    org_id = Keyword.fetch!(opts, :org_id)
    customer_id = Keyword.get(opts, :customer_id)
    paid_at = Keyword.get(opts, :paid_at)
    reference = Keyword.get(opts, :reference)
    memo = Keyword.get(opts, :memo)
    currency = Keyword.get(opts, :currency, "USD")

    with :ok <- validate_customer(customer_id),
         {:ok, paid_at} <- normalize_paid_at(paid_at),
         {:ok, allocations} <- normalize_allocations(Keyword.get(opts, :allocations)),
         {:ok, statement} <-
           load_statement(invoice_resource, receipt_resource, org_id, scope, customer_id, paid_at),
         :ok <- validate_allocations(allocations, statement),
         :ok <- validate_not_posted(receipt_resource, org_id, scope, allocations) do
      reference = normalize_reference(reference, paid_at)

      case repo.transaction(fn ->
             execute(
               allocations,
               receipt_resource,
               scope,
               org_id,
               customer_id,
               paid_at,
               reference,
               memo,
               currency,
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

  defp execute(
         allocations,
         receipt_resource,
         scope,
         org_id,
         customer_id,
         paid_at,
         reference,
         memo,
         currency,
         repo
       ) do
    {receipts, notifications} =
      Enum.map_reduce(allocations, [], fn allocation, notifications ->
        attrs = %{
          org_id: org_id,
          invoice_key: @invoice_key,
          invoice_id: allocation.invoice_id,
          amount_cents: allocation.amount_cents,
          currency: currency,
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

    %{
      reference: reference,
      customer_id: customer_id,
      paid_at: paid_at,
      total_cents: Enum.reduce(receipts, 0, fn receipt, acc -> acc + receipt.amount_cents end),
      receipts: receipts,
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
        repo.rollback({:receipt_post_failed, receipt.invoice_id, reason})
    end
  end

  defp load_statement(invoice_resource, receipt_resource, org_id, scope, customer_id, paid_at) do
    case ArAging.statement_for_customer(
           invoice: invoice_resource,
           receipt: receipt_resource,
           org_id: org_id,
           scope: scope,
           customer_id: customer_id,
           as_of: DateTime.to_date(paid_at)
         ) do
      {:ok, statement} -> {:ok, statement}
      {:error, reason} -> {:error, {:statement_unreadable, reason}}
    end
  end

  defp validate_allocations(allocations, statement) do
    by_invoice = Map.new(statement.invoices, &{&1.invoice_id, &1})

    Enum.reduce_while(allocations, :ok, fn allocation, :ok ->
      case Map.fetch(by_invoice, allocation.invoice_id) do
        :error ->
          {:halt, {:error, {:invoice_not_found, allocation.invoice_id}}}

        {:ok, row} ->
          cond do
            row.outstanding_cents <= 0 ->
              {:halt, {:error, {:invoice_already_paid, allocation.invoice_id}}}

            allocation.amount_cents > row.outstanding_cents ->
              {:halt, {:error, {:over_allocation, allocation.invoice_id, row.outstanding_cents}}}

            true ->
              {:cont, :ok}
          end
      end
    end)
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

  defp validate_customer(customer_id) when is_binary(customer_id) do
    if String.trim(customer_id) == "", do: {:error, :customer_required}, else: :ok
  end

  defp validate_customer(_customer_id), do: {:error, :customer_required}

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

  defp normalize_allocations(allocations) when is_list(allocations) and allocations != [] do
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
