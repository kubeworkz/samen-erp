defmodule Samen.Scopes.Finance.LeasePaymentPosting do
  @moduledoc """
  The lease payment cascade: on `:pay`, post one month's lease entry and create
  the append-only payment fact in the SAME transaction.

  The entry is:

      Dr interest expense                 (the month's interest)
      Dr amortization expense             (the ROU asset's straight-line slice)
      Dr lease liability                  (the principal repaid)
        Cr accumulated ROU amortization   (the amortization slice)
        Cr cash                           (the fixed payment)

  The amounts are re-derived from the lease's schedule; a caller cannot choose
  them. The date must be the period's last day. The payment row names every
  account it used, so a later chart change cannot rewrite history.

  ## Draft first, then the governed post

  The draft is created first so `EntryLines` can materialize under the draft
  belt; the ordinary `:post` action then runs R1 (`PostBalance`), R6
  (`DimensionBalance`) and R10 (`PeriodGuard`) exactly as for a human entry.
  A closed period refuses the payment and leaves neither row.

  The payment id is minted before the entry, so the entry anchor
  `source_key: "lease_payment"`, `source_id: <payment id>` names the row that
  inserts with that id. A failure anywhere adds an error to the changeset, so
  the fact and its entry land together or not at all.
  """

  use Ash.Resource.Change

  alias Samen.Scopes.Finance.LeaseSchedule

  @source_key "lease_payment"

  @doc "The object-ref anchor every lease payment entry carries."
  def source_key, do: @source_key

  @impl true
  def change(changeset, opts, _context) do
    lease_mod = Keyword.fetch!(opts, :lease)
    entry_mod = Keyword.fetch!(opts, :entry)

    org_id = Ash.Changeset.get_attribute(changeset, :org_id)

    Ash.Changeset.before_action(changeset, fn changeset ->
      post(changeset, org_id, lease_mod, entry_mod)
    end)
  end

  defp post(changeset, org_id, lease_mod, entry_mod) do
    lease_id = Ash.Changeset.get_attribute(changeset, :lease_id)
    period_key = Ash.Changeset.get_attribute(changeset, :period_key)
    paid_on = Ash.Changeset.get_attribute(changeset, :paid_on)

    with {:ok, lease} <- load_lease(lease_mod, org_id, lease_id),
         {:ok, period} <- parse_period(period_key),
         {:ok, row} <- slice(lease, period_key),
         :ok <- ensure_period_end(period, paid_on),
         id <- Ash.UUID.generate(),
         {:ok, _entry} <- create_entry(entry_mod, org_id, id, lease, period_key, paid_on, row) do
      changeset
      |> Ash.Changeset.force_change_attribute(:id, id)
      |> Ash.Changeset.force_change_attribute(:payment_cents, row.payment_cents)
      |> Ash.Changeset.force_change_attribute(:interest_cents, row.interest_cents)
      |> Ash.Changeset.force_change_attribute(:principal_cents, row.principal_cents)
      |> Ash.Changeset.force_change_attribute(:amortization_cents, row.amortization_cents)
      |> Ash.Changeset.force_change_attribute(
        :lease_liability_account_id,
        lease.lease_liability_account_id
      )
      |> Ash.Changeset.force_change_attribute(
        :interest_expense_account_id,
        lease.interest_expense_account_id
      )
      |> Ash.Changeset.force_change_attribute(
        :amortization_expense_account_id,
        lease.amortization_expense_account_id
      )
      |> Ash.Changeset.force_change_attribute(
        :accumulated_amortization_account_id,
        lease.accumulated_amortization_account_id
      )
      |> Ash.Changeset.force_change_attribute(:cash_account_id, lease.cash_account_id)
    else
      {:error, reason} ->
        Ash.Changeset.add_error(changeset,
          field: :base,
          message: "the lease payment cannot be posted: #{format(reason)}"
        )
    end
  end

  defp load_lease(lease_mod, org_id, lease_id) do
    require Ash.Query

    case lease_mod
         |> Ash.Query.filter(id == ^lease_id and org_id == ^org_id)
         |> Ash.read_one(authorize?: false) do
      {:ok, nil} -> {:error, {:foreign_lease, lease_id}}
      {:ok, lease} -> {:ok, lease}
      {:error, reason} -> {:error, {:lease_unreadable, reason}}
    end
  end

  defp parse_period(key) do
    case LeaseSchedule.parse_period(key) do
      {:ok, period} -> {:ok, period}
      :error -> {:error, {:bad_period, key}}
    end
  end

  defp slice(lease, period_key) do
    case LeaseSchedule.slice(lease, period_key) do
      {:ok, row} -> {:ok, row}
      :outside_term -> {:error, {:outside_term, period_key}}
      {:error, :bad_period} -> {:error, {:bad_period, period_key}}
    end
  end

  defp ensure_period_end(_period, nil), do: {:error, :paid_on_missing}

  defp ensure_period_end(period, on) do
    expected = LeaseSchedule.period_end(period)

    if Date.compare(on, expected) == :eq,
      do: :ok,
      else: {:error, {:not_period_end, expected, on}}
  end

  defp create_entry(entry_mod, org_id, id, lease, period_key, entry_date, row) do
    lines =
      [
        line(lease.interest_expense_account_id, row.interest_cents, 0, lease),
        line(lease.amortization_expense_account_id, row.amortization_cents, 0, lease),
        line(lease.lease_liability_account_id, row.principal_cents, 0, lease),
        line(
          lease.accumulated_amortization_account_id,
          0,
          row.amortization_cents,
          lease
        ),
        line(lease.cash_account_id, 0, row.payment_cents, lease)
      ]
      |> Enum.reject(fn line -> line.debit_cents == 0 and line.credit_cents == 0 end)

    with {:ok, draft} <-
           entry_mod
           |> Ash.Changeset.for_create(
             :create,
             %{
               org_id: org_id,
               entry_date: entry_date,
               memo: "Lease payment #{lease.code} #{period_key}",
               source_key: @source_key,
               source_id: id,
               lines: lines
             },
             authorize?: false
           )
           |> Ash.create(authorize?: false),
         {:ok, posted} <-
           draft
           |> Ash.Changeset.for_update(:post, %{}, authorize?: false)
           |> Ash.update(authorize?: false) do
      {:ok, posted}
    end
  end

  defp line(account_id, debit, credit, lease) do
    %{
      account_id: account_id,
      debit_cents: debit,
      credit_cents: credit,
      dimension_refs: dimension_refs(lease)
    }
  end

  defp dimension_refs(%{cost_object_id: nil}), do: %{}

  defp dimension_refs(%{cost_object_id: cost_object_id, dimension_key: key}),
    do: %{to_string(key) => cost_object_id}

  defp format({:foreign_lease, id}), do: "lease #{id} does not belong to this org"

  defp format({:lease_unreadable, reason}),
    do: "the lease could not be read: #{inspect(reason)}"

  defp format({:outside_term, key}),
    do: "period #{key} is outside the lease term — there is no payment to post"

  defp format({:not_period_end, expected, got}),
    do: "the payment must be dated the period's last day (#{expected}), not #{got}"

  defp format({:bad_period, key}), do: "#{inspect(key)} is not a \"YYYY-MM\" period key"

  defp format(reason), do: inspect(reason)
end
