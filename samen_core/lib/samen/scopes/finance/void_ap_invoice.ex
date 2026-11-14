defmodule Samen.Scopes.Finance.VoidApInvoice do
  @moduledoc """
  The governance cascade behind an approved AP bill's `:void` transition.

  A posted AP bill is a fact, and the close's period-end FX revaluation is ONE
  posted entry shared by every revalued bill (`source_key: "fx_revaluation"`,
  `source_id: <close run>`). Voiding one bill therefore cannot void the shared
  revaluation entry without also reversing the other bills it covers, and the
  original entry may be in a closed period where a rewrite is not an option.

  This change posts ONE current-period clearing entry instead:

    * mirrors every line of the bill's posted approval entry (expense cleared,
      AP released); and
    * clears the bill's **cumulative** unrealized FX — `base_total_cents` minus
      the approval entry's AP amount — against
      `unrealized_fx_gain_loss` (Dr AP / Cr unrealized for a loss, the reverse
      for a gain).

  The original approval entry and the shared revaluation entry stay on the
  ledger as history; the clearing entry nets their effect on AP, expense, and
  unrealized P&L to zero. It is anchored `source_key: "ap_void"`,
  `source_id: <bill id>` so the bill remains traceable.

  The entry is dated TODAY, not the bill date: a bill void is a new economic
  event, and the original period may already be closed. `PeriodGuard` still
  owns the current period's window, so a hard-closed period refuses the void
  and the whole action (including the status write) rolls back.

  `Samen.Scopes.Finance.ApBillEntryVoidGuard` refuses a direct
  `JournalEntry.:void` on either the approval entry or this clearing entry, so
  this bill action is the only path that clears the two sides together.

  An open or applied `VendorCredit` bound to the bill refuses the void: the
  credit has already posted its AP and vendor-credit-clearing sides, and an
  applied credit is final at this layer. A draft credit has no posting, and a
  void credit's posting is already reversed, so neither blocks the bill.
  Resolve open/applied credits before voiding the bill.

  Only `:approved` bills have a posted entry to clear. `:paid` is refused —
  reverse the payment first; a draft has no ledger footprint and is voided by
  the caller's status write alone.
  """

  use Ash.Resource.Change

  require Ash.Query

  @source_key "ap_void"

  @impl true
  def change(changeset, opts, _context) do
    entry_resource = Keyword.fetch!(opts, :entry)
    posting_account_resource = Keyword.fetch!(opts, :posting_account)
    vendor_credit_resource = Keyword.fetch!(opts, :vendor_credit)

    Ash.Changeset.before_action(changeset, fn changeset ->
      void(changeset, entry_resource, posting_account_resource, vendor_credit_resource)
    end)
  end

  defp void(changeset, entry_resource, posting_account_resource, vendor_credit_resource) do
    # The caller's struct can be stale (a bill approved and then revalued by a
    # close after the caller loaded it). Lock and re-read the persisted row so
    # the clearing entry uses the CURRENT carrying amount and status; a stale
    # read here would under-clear unrealized FX.
    with {:ok, bill} <- lock_bill(changeset) do
      case bill.status do
        :draft ->
          Ash.Changeset.force_change_attribute(changeset, :status, :void)

        :approved ->
          void_approved(
            changeset,
            bill,
            entry_resource,
            posting_account_resource,
            vendor_credit_resource
          )

        :paid ->
          add_error(
            changeset,
            "the bill is :paid — reverse the payment before voiding the bill"
          )

        :void ->
          add_error(changeset, "the bill is already :void")

        other ->
          add_error(changeset, "the bill cannot be voided from status #{inspect(other)}")
      end
    else
      {:error, reason} -> add_error(changeset, format(reason))
    end
  end

  defp void_approved(
         changeset,
         bill,
         entry_resource,
         posting_account_resource,
         vendor_credit_resource
       ) do
    org_id = org_id(bill)

    with :ok <- ensure_no_bound_vendor_credits(vendor_credit_resource, org_id, bill),
         {:ok, entry} <- load_posted_entry(entry_resource, bill.posted_entry_id),
         {:ok, ap_clearing} <-
           posting_account(posting_account_resource, org_id, :ap_clearing),
         {:ok, lines} <- load_lines(entry),
         {:ok, original_base} <- approval_base(lines, ap_clearing.account_id),
         {:ok, carrying} <- carrying_cents(bill),
         {:ok, fx_lines} <-
           fx_clearance(
             carrying - original_base,
             ap_clearing,
             posting_account_resource,
             org_id,
             bill
           ),
         {:ok, _void_entry} <-
           create_void_entry(
             entry_resource,
             bill,
             org_id,
             mirror_lines(lines, bill),
             fx_lines
           ) do
      Ash.Changeset.force_change_attribute(changeset, :status, :void)
    else
      {:error, reason} -> add_error(changeset, format(reason))
    end
  end

  defp lock_bill(changeset) do
    changeset.resource
    |> Ash.Query.filter(id == ^changeset.data.id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, nil} -> {:error, :bill_not_found}
      {:ok, bill} -> {:ok, bill}
      {:error, reason} -> {:error, {:bill_lock_failed, reason}}
    end
  end

  defp load_posted_entry(_entry_resource, nil),
    do: {:error, :missing_posted_entry}

  defp load_posted_entry(entry_resource, entry_id) do
    case Ash.get(entry_resource, entry_id, authorize?: false) do
      {:ok, %{status: :posted} = entry} -> {:ok, entry}
      {:ok, %{status: status}} -> {:error, {:approval_entry_not_posted, status}}
      {:error, reason} -> {:error, {:approval_entry_unavailable, reason}}
    end
  end

  defp load_lines(entry) do
    case Ash.load(entry, [:lines], authorize?: false) do
      {:ok, %{lines: lines}} when is_list(lines) -> {:ok, lines}
      {:ok, _} -> {:error, :approval_entry_lines_missing}
      {:error, reason} -> {:error, {:approval_entry_lines_unavailable, reason}}
    end
  end

  defp approval_base(lines, ap_account_id) do
    amount =
      Enum.reduce(lines, 0, fn line, total ->
        if line.account_id == ap_account_id do
          total + (line.credit_cents || 0) - (line.debit_cents || 0)
        else
          total
        end
      end)

    if amount > 0,
      do: {:ok, amount},
      else: {:error, {:no_ap_liability_line, amount}}
  end

  defp carrying_cents(bill) do
    case bill.base_total_cents do
      cents when is_integer(cents) and cents > 0 -> {:ok, cents}
      other -> {:error, {:missing_carrying_amount, other}}
    end
  end

  defp ensure_no_bound_vendor_credits(resource, org_id, bill) do
    resource
    |> Ash.Query.filter(org_id == ^org_id and bill_id == ^bill.id and status in [:open, :applied])
    |> Ash.read(authorize?: false)
    |> case do
      {:ok, []} -> :ok
      {:ok, credits} -> {:error, {:bound_vendor_credits, credits}}
      {:error, reason} -> {:error, {:vendor_credit_read_failed, reason}}
    end
  end

  defp fx_clearance(0, _ap_clearing, _posting_account_resource, _org_id, _bill),
    do: {:ok, []}

  defp fx_clearance(delta, ap_clearing, posting_account_resource, org_id, bill) do
    with {:ok, unrealized} <-
           posting_account(
             posting_account_resource,
             org_id,
             :unrealized_fx_gain_loss
           ) do
      amount = abs(delta)
      memo = "Void of AP bill #{bill.number}"

      {ap_debit, ap_credit, fx_debit, fx_credit} =
        if delta > 0 do
          {amount, 0, 0, amount}
        else
          {0, amount, amount, 0}
        end

      {:ok,
       [
         %{
           account_id: ap_clearing.account_id,
           debit_cents: ap_debit,
           credit_cents: ap_credit,
           memo: memo
         },
         %{
           account_id: unrealized.account_id,
           debit_cents: fx_debit,
           credit_cents: fx_credit,
           memo: memo
         }
       ]}
    end
  end

  defp mirror_lines(lines, bill) do
    memo = "Void of AP bill #{bill.number}"

    Enum.map(lines, fn line ->
      %{
        account_id: line.account_id,
        debit_cents: line.credit_cents || 0,
        credit_cents: line.debit_cents || 0,
        dimension_refs: line.dimension_refs || %{},
        memo: memo
      }
    end)
  end

  defp create_void_entry(entry_resource, bill, org_id, mirrored_lines, fx_lines) do
    attrs = %{
      org_id: org_id,
      entry_date: Date.utc_today(),
      memo: "Void of AP bill #{bill.number}",
      source_key: @source_key,
      source_id: bill.id,
      lines: mirrored_lines ++ fx_lines
    }

    entry_resource
    |> Ash.Changeset.for_create(:create_reversal, attrs, authorize?: false)
    |> Ash.create(authorize?: false)
  end

  defp posting_account(resource, org_id, key) do
    case resource
         |> Ash.Query.filter(org_id == ^org_id and key == ^key)
         |> Ash.read_one(authorize?: false) do
      {:ok, nil} -> {:error, {:unmapped_posting_account, key}}
      {:ok, row} -> {:ok, row}
      {:error, reason} -> {:error, {:posting_account_unavailable, key, reason}}
    end
  end

  # The locked read does not select org_id, so resolve it lazily; the vendor
  # credit lookup and clearing entry both need it.
  defp org_id(%{org_id: %Ash.NotLoaded{}} = bill) do
    Ash.load!(bill, [:org_id], authorize?: false).org_id
  end

  defp org_id(%{org_id: org_id}), do: org_id

  defp add_error(changeset, message) do
    Ash.Changeset.add_error(changeset, field: :base, message: message)
  end

  defp format(:bill_not_found), do: "the bill no longer exists"

  defp format({:bill_lock_failed, reason}),
    do: "the bill could not be locked for its void: #{inspect(reason)}"

  defp format(:missing_posted_entry),
    do: "the bill has no posted approval entry — an approved bill must carry one"

  defp format({:approval_entry_not_posted, status}),
    do:
      "the bill's approval entry is #{inspect(status)} — only a posted entry can be " <>
        "cleared by a void"

  defp format({:approval_entry_unavailable, reason}),
    do: "the bill's approval entry could not be read: #{inspect(reason)}"

  defp format(:approval_entry_lines_missing),
    do: "the bill's approval entry carries no stored lines"

  defp format({:approval_entry_lines_unavailable, reason}),
    do: "the bill's approval entry lines could not be read: #{inspect(reason)}"

  defp format({:no_ap_liability_line, amount}),
    do:
      "the bill's approval entry has no positive AP liability to release " <>
        "(net AP amount: #{inspect(amount)})"

  defp format({:missing_carrying_amount, amount}),
    do:
      "the bill has no stored carrying amount — a void cannot clear unrealized FX " <>
        "without one (got: #{inspect(amount)})"

  defp format({:bound_vendor_credits, credits}) do
    numbers = Enum.map_join(credits, ", ", & &1.number)

    "the bill has open or applied vendor credit(s) bound to it (#{numbers}) — " <>
      "resolve those adjustments before voiding the bill"
  end

  defp format({:vendor_credit_read_failed, reason}),
    do: "the bill's vendor credits could not be checked: #{inspect(reason)}"

  defp format({:unmapped_posting_account, key}),
    do:
      "no PostingAccount row maps `#{key}` for this org — the void cannot clear " <>
        "the bill's AP/unrealized positions"

  defp format({:posting_account_unavailable, key, reason}),
    do: "the `#{key}` posting account could not be read: #{inspect(reason)}"

  defp format(reason), do: inspect(reason)
end
