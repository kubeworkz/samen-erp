defmodule Samen.Scopes.Finance.ApPaymentRun do
  @moduledoc """
  A transactional **AP payment run** over the per-bill `ApInvoice.:pay` action.

  A run is an execution, not a new ledger resource: every selected bill gets
  its own posted `JournalEntry` anchored `source_key: "ap_payment"` and its own
  `:approved -> :paid` transition. The run adds the cross-bill guarantees that
  a loop of independent payments would not have:

    * all bills must belong to the same vendor;
    * every bill must still be `:approved` (a stale or already-paid bill refuses
      the whole run before any cash leaves);
    * bills that look like the same vendor document entered twice refuse the
      run unless the caller explicitly confirms them (see `duplicates/1`);
    * the payments execute inside one repository transaction, so a failure on
      a later bill rolls back the earlier payments;
    * every payment entry carries the same caller-visible run reference in its
      memo, and the returned run summary is the remittance advice source.

  The run header itself is deliberately not persisted yet. The durable facts
  are the posted payment entries and the bills' `:paid` status; a persisted run
  header, stored remittance batches, partial payments and discounts are
  follow-on slices. The bank file is `Samen.Scopes.Finance.ApAchFile`, rendered
  from the returned run.

  ## Example

      {:ok, run} =
        Samen.Scopes.Finance.ApPaymentRun.pay(
          ap_invoice: Samenerp.Erp.ApInvoice,
          repo: Samenerp.Repo,
          scope: scope,
          bill_ids: [bill.id],
          payment_date: ~D[2026-11-08],
          reference: "NOV-AP-01"
        )

      File.write!("remittance.csv",
        Samen.Scopes.Finance.ApPaymentRun.remittance_csv(run))
  """

  @type run :: %{
          reference: String.t(),
          payment_date: Date.t(),
          vendor_id: String.t(),
          total_cents: non_neg_integer(),
          payments: [map()]
        }

  @doc """
  Pay every bill in `bill_ids` in one transaction.

  Options:

    * `:ap_invoice` (required) — the mounted `ApInvoice` resource
    * `:repo` (required) — the Ecto repo that owns that resource
    * `:scope` (required) — the `Samen.Scope` authorizing the bills
    * `:bill_ids` (required) — non-empty list of bill UUIDs, all one vendor
    * `:payment_date` (required) — the `Date` posted as the payment entry date
    * `:reference` — the remittance reference; generated when absent
    * `:memo` — optional note copied into every payment entry
    * `:allow_duplicates` — opt in to paying bills `duplicates/1` groups
      together (default `false`: the run refuses them)

  Returns `{:ok, run}` or `{:error, reason}`. On error no payment from the run
  is committed. A duplicate suspicion is `{:error, {:duplicate_bills, ids}}`.
  """
  @spec pay(keyword()) :: {:ok, run()} | {:error, term()}
  def pay(opts) do
    ap_invoice = Keyword.fetch!(opts, :ap_invoice)
    repo = Keyword.fetch!(opts, :repo)
    scope = Keyword.fetch!(opts, :scope)
    bill_ids = Keyword.get(opts, :bill_ids)
    payment_date = Keyword.get(opts, :payment_date)
    memo = Keyword.get(opts, :memo)
    allow_duplicates = Keyword.get(opts, :allow_duplicates, false)
    reference = normalize_reference(Keyword.get(opts, :reference), payment_date)

    with :ok <- validate_bill_ids(bill_ids),
         :ok <- validate_payment_date(payment_date),
         {:ok, bills} <- load_bills(ap_invoice, bill_ids, scope),
         :ok <- validate_bills(bills, allow_duplicates),
         {:ok, run} <-
           transact(repo, fn ->
             execute_run(bills, payment_date, reference, memo, scope, repo)
           end) do
      {:ok, run}
    end
  end

  @doc """
  Render the run as a CSV remittance advice.

  The file is intentionally bank-agnostic: one row per bill with the shared
  run reference, payment date, vendor, bill number, due date and amount in
  cents. It is not a NACHA/ACH file.
  """
  @spec remittance_csv(run()) :: String.t()
  def remittance_csv(run) do
    header =
      "reference,payment_date,vendor_id,bill_number,due_date,amount_cents\n"

    rows =
      Enum.map(run.payments, fn payment ->
        [
          run.reference,
          Date.to_iso8601(run.payment_date),
          run.vendor_id,
          payment.number,
          payment.due_date && Date.to_iso8601(payment.due_date),
          payment.amount_cents
        ]
        |> Enum.map(&csv_cell/1)
        |> Enum.join(",")
      end)

    header <> Enum.join(rows, "\n") <> "\n"
  end

  defp execute_run(bills, payment_date, reference, memo, scope, repo) do
    payments =
      Enum.map(bills, fn bill ->
        params = %{payment_date: payment_date, reference: reference, memo: memo}

        case bill
             |> Ash.Changeset.for_update(:pay, params, scope: scope)
             |> Ash.update() do
          {:ok, paid} ->
            %{
              bill_id: paid.id,
              number: paid.number,
              due_date: paid.due_date,
              amount_cents: bill_total(paid),
              status: paid.status
            }

          {:error, reason} ->
            repo.rollback({:payment_failed, bill.id, reason})
        end
      end)

    %{
      reference: reference,
      payment_date: payment_date,
      vendor_id: hd(bills).vendor_id,
      total_cents: Enum.sum(Enum.map(payments, & &1.amount_cents)),
      payments: payments
    }
  end

  defp validate_bill_ids(ids) when is_list(ids) and ids != [] do
    if Enum.all?(ids, &is_binary/1) and Enum.uniq(ids) == ids do
      :ok
    else
      {:error, :bill_ids_must_be_unique_uuids}
    end
  end

  defp validate_bill_ids(_), do: {:error, :bill_ids_required}

  defp validate_payment_date(%Date{}), do: :ok
  defp validate_payment_date(_), do: {:error, :payment_date_required}

  defp load_bills(ap_invoice, bill_ids, scope) do
    bills =
      Enum.reduce_while(bill_ids, [], fn id, acc ->
        case Ash.get(ap_invoice, id, scope: scope) do
          {:ok, nil} -> {:halt, {:error, {:bill_not_found, id}}}
          {:ok, bill} -> {:cont, [bill | acc]}
          {:error, reason} -> {:halt, {:error, {:bill_read_failed, id, reason}}}
        end
      end)

    case bills do
      {:error, _} = error -> error
      bills -> {:ok, Enum.reverse(bills)}
    end
  end

  defp validate_bills([first | rest] = bills, allow_duplicates) do
    cond do
      Enum.any?(bills, &(&1.status != :approved)) ->
        {:error, {:not_approved, Enum.find(bills, &(&1.status != :approved)).id}}

      Enum.any?(rest, &(&1.vendor_id != first.vendor_id)) ->
        {:error, :mixed_vendors}

      not allow_duplicates and duplicates(bills) != [] ->
        ids =
          bills
          |> duplicates()
          |> Enum.flat_map(fn %{bills: group} -> Enum.map(group, & &1.id) end)
          |> Enum.uniq()

        {:error, {:duplicate_bills, ids}}

      true ->
        :ok
    end
  end

  @doc """
  Bills that look like the same vendor document entered twice.

  Two bills are grouped when they share the vendor, the line total and the bill
  date — the shape a re-keyed invoice takes when only the vendor's number
  differs (`{org, number}` is already unique at the database, so an identical
  number cannot be stored twice). Returns one entry per group, each with the
  shared key and its bills sorted by number; `[]` when nothing looks doubled.

  Detection is over the bills the caller supplies: the payment page passes its
  whole approved list, and `pay/1` passes the batch it is about to execute. A
  copy that was already paid is outside both sets and is NOT detected here.
  """
  @spec duplicates([map()]) :: [%{key: tuple(), bills: [map()]}]
  def duplicates(bills) when is_list(bills) do
    bills
    |> Enum.reject(&(Map.get(&1, :vendor_id) in [nil, ""]))
    |> Enum.group_by(fn bill ->
      {bill.vendor_id, bill_total(bill), Map.get(bill, :bill_date)}
    end)
    |> Enum.filter(fn {_key, group} -> length(group) > 1 end)
    |> Enum.map(fn {key, group} ->
      %{key: key, bills: Enum.sort_by(group, &to_string(Map.get(&1, :number)))}
    end)
    |> Enum.sort_by(fn %{key: {vendor, total, date}} ->
      {to_string(date), vendor, total}
    end)
  end

  defp transact(repo, fun) do
    repo.transaction(fun)
  end

  defp bill_total(bill) do
    Samen.Scopes.Finance.ApDuplicates.total(bill)
  end

  defp normalize_reference(reference, _payment_date)
       when is_binary(reference) and reference != "" do
    reference
  end

  defp normalize_reference(_reference, %Date{} = payment_date) do
    "APRUN-#{Date.to_iso8601(payment_date)}-" <>
      (Ash.UUID.generate() |> binary_part(0, 8) |> String.upcase())
  end

  defp normalize_reference(_reference, _payment_date) do
    "APRUN-" <> (Ash.UUID.generate() |> binary_part(0, 8) |> String.upcase())
  end

  defp csv_cell(nil), do: ""

  defp csv_cell(value) when is_binary(value) do
    if String.contains?(value, [",", "\"", "\n", "\r"]) do
      "\"" <> String.replace(value, "\"", "\"\"") <> "\""
    else
      value
    end
  end

  defp csv_cell(value), do: to_string(value)
end
