defmodule Samen.Scopes.Finance.ApAging do
  @moduledoc """
  AP aging and vendor statements over the existing AP bill + payment-run spine.

  The AP subledger is the host's `ApInvoice`. A bill is a liability once it is
  `:approved`; `:draft` was never approved, `:void` is no longer a liability,
  and `:paid` has been settled by a dual-controlled payment run. Only approved
  bills age, and the amount is the sum of the bill's own lines — the same
  subledger shape the payment run snapshots.

  ## Aging buckets

  `:current` (not yet due), `:days_1_30`, `:days_31_60`, `:days_61_90`,
  `:days_90_plus`, and `:undated` (no due date). A zero-outstanding bill is
  omitted from aging.

  ## Vendor statements

  A statement includes the vendor's open AND paid bills, the effective payment
  runs that settled them, the billed/paid/outstanding totals, and the vendor's
  open aging. A paid run whose reversal completed is not an effective payment,
  so it is excluded from the statement's payment history; the restored bill
  ages again as approved.

  ## Integration

      {:ok, aging} =
        Samen.Scopes.Finance.ApAging.for_org(
          ap_invoice: Samenerp.Erp.ApInvoice,
          org_id: org_id,
          scope: scope,
          as_of: ~D[2026-11-08]
        )

      {:ok, statement} =
        Samen.Scopes.Finance.ApAging.statement_for_vendor(
          ap_invoice: Samenerp.Erp.ApInvoice,
          repo: Samenerp.Repo,
          org_id: org_id,
          scope: scope,
          vendor_id: vendor_id,
          as_of: ~D[2026-11-08]
        )

  The pure `aging/2` and `statement/4` functions accept already-loaded maps, so
  hosts can feed a different bill/payment source without changing the math.
  """

  require Ash.Query

  alias Samen.Scopes.Finance.{ApPaymentReversal, ApPaymentRun}

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
  Age the supplied approved bills as of `opts[:as_of]`.

  Bill maps use `:id`, `:vendor_id`, `:number`, `:bill_date`, `:due_date`,
  `:amount_cents` (or `:lines`), and `:status`. Only `:approved` bills with a
  positive outstanding amount appear in the result.
  """
  def aging(bills, opts) do
    as_of = Keyword.fetch!(opts, :as_of)

    included =
      bills
      |> Enum.filter(&(status_of(&1) in [:approved, :paid]))

    rows =
      included
      |> Enum.map(&aging_row(&1, as_of))
      |> Enum.reject(&is_nil/1)
      |> Enum.sort_by(&{date_key(&1.due_date), &1.bill_id})

    buckets =
      Enum.reduce(rows, empty_buckets(), fn row, acc ->
        Map.update!(acc, row.bucket, &(&1 + row.outstanding_cents))
      end)

    %{
      as_of: as_of,
      total_cents: Enum.reduce(rows, 0, &(&1.outstanding_cents + &2)),
      buckets: buckets,
      bills: rows,
      vendor_ids: vendor_ids(included)
    }
  end

  @doc """
  Build a vendor statement as of `opts[:as_of]`.

  Includes every open or paid bill for the vendor, the effective paid-run
  payments that settled those bills, the outstanding total and the vendor's
  aging. `opts[:reversed_run_ids]` lists paid runs whose reversal completed;
  their payment rows are excluded.
  """
  def statement(bills, runs, vendor_id, opts) do
    as_of = Keyword.fetch!(opts, :as_of)
    reversed = opts |> Keyword.get(:reversed_run_ids, MapSet.new()) |> MapSet.new()

    vendor_bills =
      bills
      |> Enum.filter(&(vendor_of(&1) == vendor_id))
      |> Enum.filter(&(status_of(&1) in [:approved, :paid]))
      |> Enum.sort_by(&{date_key(date_of(Map.get(&1, :bill_date))), &1.id})

    rows =
      Enum.map(vendor_bills, fn bill ->
        amount = amount_of(bill)
        paid_cents = if status_of(bill) == :paid, do: amount, else: 0

        %{
          bill_id: bill.id,
          number: Map.get(bill, :number),
          bill_date: date_of(Map.get(bill, :bill_date)),
          due_date: date_of(Map.get(bill, :due_date)),
          amount_cents: amount,
          paid_cents: paid_cents,
          outstanding_cents: max(amount - paid_cents, 0),
          status: status_of(bill)
        }
      end)

    payments = payments_for_vendor(runs, vendor_id, reversed)

    total_billed = Enum.reduce(rows, 0, &(&1.amount_cents + &2))
    total_paid = Enum.reduce(rows, 0, &(&1.paid_cents + &2))
    outstanding = Enum.reduce(rows, 0, &(&1.outstanding_cents + &2))

    %{
      vendor_id: vendor_id,
      vendor_name: vendor_name(runs, vendor_id, reversed),
      as_of: as_of,
      bills: rows,
      payments: payments,
      totals: %{
        billed_cents: total_billed,
        paid_cents: total_paid,
        outstanding_cents: outstanding
      },
      aging: aging(vendor_bills, as_of: as_of)
    }
  end

  @doc """
  Load approved and paid AP bills for an org and return the org-wide aging.
  Requires `:ap_invoice`, `:org_id`, `:scope` and `:as_of`.
  """
  def for_org(opts) do
    with {:ok, bills} <- load(opts) do
      {:ok, aging(bills, as_of: Keyword.fetch!(opts, :as_of))}
    end
  end

  @doc """
  Load the org's AP documents and return one vendor's statement.

  Requires the same options as `for_org/1` plus `:vendor_id`, and either
  `:payment_runs` (already loaded) or `:repo` so the effective paid runs and
  completed reversals can be read.
  """
  def statement_for_vendor(opts) do
    with {:ok, bills} <- load(opts),
         {:ok, runs, reversed} <- load_runs(opts) do
      vendor_id = Keyword.fetch!(opts, :vendor_id)

      {:ok,
       statement(bills, runs, vendor_id,
         as_of: Keyword.fetch!(opts, :as_of),
         reversed_run_ids: reversed
       )}
    end
  end

  defp load(opts) do
    ap_invoice = Keyword.fetch!(opts, :ap_invoice)
    org_id = Keyword.fetch!(opts, :org_id)
    scope = Keyword.fetch!(opts, :scope)

    with {:ok, bills} <-
           ap_invoice
           |> Ash.Query.filter(org_id == ^org_id and status in [:approved, :paid])
           |> Ash.read(scope: scope) do
      {:ok, Enum.map(bills, &normalize_bill/1)}
    end
  end

  defp load_runs(opts) do
    if Keyword.has_key?(opts, :payment_runs) do
      {:ok, List.wrap(Keyword.get(opts, :payment_runs)),
       MapSet.new(Keyword.get(opts, :reversed_run_ids, []))}
    else
      repo = Keyword.fetch!(opts, :repo)
      org_id = Keyword.fetch!(opts, :org_id)
      runs = ApPaymentRun.list_runs(repo, org_id, status: :paid, limit: :all)

      case ApPaymentReversal.reversed_run_ids(repo, org_id) do
        {:ok, reversed} -> {:ok, runs, reversed}
        {:error, reason} -> {:error, {:payment_runs_unreadable, reason}}
      end
    end
  end

  defp normalize_bill(bill) do
    %{
      id: bill.id,
      vendor_id: Map.get(bill, :vendor_id),
      number: Map.get(bill, :number),
      bill_date: date_of(Map.get(bill, :bill_date)),
      due_date: date_of(Map.get(bill, :due_date)),
      amount_cents: bill_total(bill),
      status: Map.get(bill, :status)
    }
  end

  defp aging_row(bill, as_of) do
    if status_of(bill) == :approved do
      amount = amount_of(bill)

      if amount > 0 do
        due_date = date_of(Map.get(bill, :due_date))
        days_overdue = days_overdue(due_date, as_of)

        %{
          bill_id: bill.id,
          vendor_id: vendor_of(bill),
          number: Map.get(bill, :number),
          bill_date: date_of(Map.get(bill, :bill_date)),
          due_date: due_date,
          amount_cents: amount,
          outstanding_cents: amount,
          days_overdue: days_overdue,
          bucket: bucket_for(due_date, days_overdue)
        }
      end
    end
  end

  defp payments_for_vendor(runs, vendor_id, reversed) do
    runs
    |> List.wrap()
    |> Enum.filter(&(status_of(&1) == :paid))
    |> Enum.reject(&MapSet.member?(reversed, field(&1, :id)))
    |> Enum.flat_map(fn run ->
      payment_date = date_of(field(run, :payment_date))

      run
      |> field(:payments)
      |> List.wrap()
      |> Enum.filter(&(payment_vendor_id(&1, run) == vendor_id))
      |> Enum.map(fn payment ->
        %{
          run_id: field(run, :id),
          bill_id: field(payment, :bill_id),
          bill_number: field(payment, :number),
          reference: field(run, :reference),
          payment_date: payment_date,
          amount_cents: field(payment, :amount_cents) || 0
        }
      end)
    end)
    |> Enum.sort_by(&{date_key(&1.payment_date), to_string(&1.run_id), to_string(&1.bill_id)})
  end

  defp vendor_name(runs, vendor_id, reversed) do
    runs
    |> List.wrap()
    |> Enum.filter(&(status_of(&1) == :paid))
    |> Enum.reject(&MapSet.member?(reversed, field(&1, :id)))
    |> Enum.find_value(fn run ->
      if payment_vendor_id(%{}, run) == vendor_id do
        field(run, :vendor_name)
      end
    end)
  end

  defp vendor_ids(bills) do
    bills
    |> Enum.map(&vendor_of/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp vendor_of(bill) do
    Map.get(bill, :vendor_id) || Map.get(bill, "vendor_id")
  end

  defp payment_vendor_id(payment, run) do
    field(payment, :vendor_id) || field(run, :vendor_id)
  end

  defp status_of(map) do
    case field(map, :status) do
      status when status in [:draft, :approved, :paid, :void] -> status
      "draft" -> :draft
      "approved" -> :approved
      "paid" -> :paid
      "void" -> :void
      _other -> nil
    end
  end

  defp amount_of(map) do
    case field(map, :amount_cents) do
      amount when is_integer(amount) -> amount
      _other -> bill_total(map)
    end
  end

  defp bill_total(map) do
    case field(map, :lines) do
      lines when is_list(lines) ->
        Enum.reduce(lines, 0, fn line, total ->
          total + (field(line, :amount_cents) || 0)
        end)

      _other ->
        0
    end
  end

  defp field(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp field(_value, _key), do: nil

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

  defp date_key(nil), do: "9999-12-31"
  defp date_key(%Date{} = date), do: Date.to_iso8601(date)
  defp date_key(%DateTime{} = datetime), do: datetime |> DateTime.to_date() |> Date.to_iso8601()

  defp date_key(%NaiveDateTime{} = datetime),
    do: datetime |> NaiveDateTime.to_date() |> Date.to_iso8601()

  defp date_key(_other), do: "9999-12-31"

  defp date_of(%Date{} = date), do: date
  defp date_of(%DateTime{} = datetime), do: DateTime.to_date(datetime)
  defp date_of(%NaiveDateTime{} = datetime), do: NaiveDateTime.to_date(datetime)
  defp date_of(_), do: nil
end
