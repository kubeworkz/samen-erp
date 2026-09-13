defmodule Samen.Scopes.Finance.ReceiptPosting do
  @moduledoc """
  The AR intake cascade (WS-ERP E2; design §2.2): on `:post_receipt`, create
  the cash+AR-clearing `JournalEntry` — debit the org's `cash` account by the
  receipt's `amount_cents`, credit its `ar_clearing` account — anchored
  `source_key: "billing_payment"`, `source_id: <receipt id>`, in ONE
  transaction with the receipt's own status flip to `:posted`. R1 comes free
  (the entry's guard stack runs; the two-sided construction balances by
  construction).

  **Exactly-once per anchor** — two layers:

  * the migration's partial unique index `prc_anchor_unique` on the anchor
    columns is a DRAFT-agnostic table-level guard against duplicate receipts
    of the same upstream event (`{org, invoice_key, invoice_id, amount}` —
    hmm: the index keys the receipt table itself, refusing a SECOND receipt
    row for the same upstream anchor outright), and
  * this change's in-transaction re-read re-checks the receipt's own status
    over the persisted row before writing: a receipt flips `draft → posted`
    exactly once; the second `:post_receipt` hits the status guard here (and
    the belt behind it).

  The posted-entry anchor (`source_key: "billing_payment"`) is what
  `Samen.Scopes.Finance.ReconcilePayments` sums over — the R2 GL side.
  Posting accounts resolve from the org's `PostingAccount` rows, fail-honest
  (`ar_clearing`, `cash` must be mapped). A zero-amount receipt is refused.
  """
  use Ash.Resource.Change

  @source_key "billing_payment"

  @impl true
  def change(changeset, opts, _context) do
    entry_resource = Keyword.fetch!(opts, :entry)
    pa_resource = Keyword.fetch!(opts, :posting_account)

    org_id =
      case Ash.Changeset.get_attribute(changeset, :org_id) do
        %Ash.NotLoaded{} -> Ash.load!(changeset.data, [:org_id], authorize?: false).org_id
        value -> value
      end

    Ash.Changeset.before_action(changeset, fn changeset ->
      do_post(changeset, org_id, entry_resource, pa_resource)
    end)
  end

  defp do_post(changeset, org_id, entry_resource, pa_resource) do
    receipt = changeset.data

    with :ok <- refuse_posted(changeset),
         {:ok, amount} <- amount_of(receipt),
         {:ok, cash} <- posting_account(pa_resource, org_id, :cash),
         {:ok, ar_clearing} <- posting_account(pa_resource, org_id, :ar_clearing) do
      entry_attrs = %{
        org_id: org_id,
        entry_date: DateTime.to_date(receipt.paid_at),
        memo: "Payment receipt #{receipt.invoice_key}:#{receipt.invoice_id}" <>
                memo_suffix(receipt.memo),
        source_key: @source_key,
        source_id: receipt.id,
        lines: [
          %{account_id: cash.account_id, debit_cents: amount, credit_cents: 0},
          %{account_id: ar_clearing.account_id, debit_cents: 0, credit_cents: amount}
        ]
      }

      case entry_resource
           # The posted-born internal factory (the reversal cascade's shape):
           # UnbalancedEntry + EntryLines + PostGuard run resource-wide, so the
           # receipt's entry lands POSTED immediately — R2's posted_cash_total
           # sums posted rows only, and a draft would silently diverge from
           # the intake total. The belt-marker arm/restore is PostGuard's.
           |> Ash.Changeset.for_create(:create_reversal, entry_attrs, authorize?: false)
           |> Ash.create(authorize?: false) do
        {:ok, entry} ->
          changeset
          |> Ash.Changeset.force_change_attribute(:status, :posted)
          |> Ash.Changeset.force_change_attribute(:posted_entry_id, entry.id)
          |> Ash.Changeset.force_change_attribute(:posted_at, receipt.paid_at)

        {:error, reason} ->
          Ash.Changeset.add_error(changeset,
            field: :base,
            message: "the payment receipt's posting entry failed to land: #{inspect(reason)}"
          )
      end
    else
      {:error, reason} ->
        Ash.Changeset.add_error(changeset,
          field: :base,
          message: "the payment receipt cannot be posted: #{format(reason)}"
        )
    end
  end

  # The exactly-once condition, re-checked over the PERSISTED row inside the
  # transaction (a caller may hold a stale draft record). `status` is never
  # caller-supplied — the only writer is this flip, so a persisted `:posted`
  # row can only mean "already posted".
  defp refuse_posted(changeset) do
    case changeset.data.status do
      :draft -> :ok
      other -> {:error, {:already_posted, other}}
    end
  end

  defp amount_of(receipt) do
    if is_integer(receipt.amount_cents) and receipt.amount_cents > 0,
      do: {:ok, receipt.amount_cents},
      else: {:error, {:non_positive_amount, receipt.amount_cents}}
  end

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

  defp format({:already_posted, status}),
    do: "the receipt is #{inspect(status)} — a receipt posts exactly once per anchor"

  defp format({:non_positive_amount, amount}),
    do: "amount_cents must be a positive integer — got: #{inspect(amount)}"

  defp format({:unmapped_posting_account, key}),
    do: "no PostingAccount row maps `#{key}` for this org (fail-honest — accounts are a " <>
          "host decision; seed the org's posting accounts first)"

  defp format(reason), do: inspect(reason)

  defp memo_suffix(nil), do: ""
  defp memo_suffix(""), do: ""
  defp memo_suffix(memo), do: " — " <> memo
end
