defmodule Samen.Scopes.Finance.ApPosting do
  @moduledoc """
  The AP posting cascade (WS-ERP E2; design §2.2): on `:approve`, land the
  expense+liability `JournalEntry` — debit each line's expense `account_id`
  by the line's `amount_cents`, credit the org's `ap_clearing` account for the
  bill total — anchored `source_key: "ap_invoice"`, `source_id: <bill id>`.
  R1 comes free: the entry's own guard stack (UnbalancedEntry → EntryLines →
  DB belt) runs over the created entry, and the two-sided construction means
  it balances by construction.

  Runs in `:approve`'s `before_action` — INSIDE the action's transaction, which
  (via the Gate) is the ADR-040 decision transaction: a posting failure rolls
  back the approval transition AND the audit (an approval that could not post
  is not an approval). The Gate's ungated abort runs `before_transaction` —
  ALWAYS before any transaction — so this hook cannot fire on an ungated call.

  The posting accounts resolve from the org's `PostingAccount` rows — wired at compile
  time by the scope macro (`entry:` / `posting_account:` change opts) — and an
  unmapped `ap_clearing` refuses the posting FAIL-HONEST: accounts are a host
  decision, never invented by the scope. A zero-total bill is refused (an AP
  posting of nothing is not a fact). The reversal shape for a later AP void is
  the P2 credit-note carry (E4's payment flow completes the lifecycle).
  """
  use Ash.Resource.Change

  @source_key "ap_invoice"

  @impl true
  def change(changeset, opts, _context) do
    entry_resource = Keyword.fetch!(opts, :entry)
    pa_resource = Keyword.fetch!(opts, :posting_account)

    # The tenant capture happens at change-build time (attributes still
    # pending — the EntryLines posture): inside after_action the record's
    # org_id may be an Ash.NotLoaded placeholder.
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
    bill = changeset.data

    with :ok <- refuse_non_draft(changeset),
         {:ok, lines} <- lines_of(bill),
         :ok <- refuse_zero_total(lines),
         {:ok, ap_clearing} <- posting_account(pa_resource, org_id, :ap_clearing) do
      entry_lines =
        (Enum.map(lines, fn line ->
           %{account_id: line.account_id, debit_cents: line.amount_cents, credit_cents: 0}
         end) ++
           [%{
              account_id: ap_clearing.account_id,
              debit_cents: 0,
              credit_cents: total(lines)
            }])
        |> Enum.reject(&(&1.debit_cents == 0 and &1.credit_cents == 0))

      entry_attrs = %{
        org_id: org_id,
        entry_date: bill.bill_date,
        memo: "AP bill #{bill.number}" <> memo_suffix(bill.memo),
        source_key: @source_key,
        source_id: bill.id,
        lines: entry_lines
      }

      case entry_resource
           # The posted-born internal factory (the same governed shape the
           # reversal cascade uses): UnbalancedEntry + EntryLines + PostGuard
           # run resource-wide, so the AP entry lands POSTED (the approval IS
           # the posting act — a draft would hide the expense from the GL and
           # from every reconciliation sum) with the belt-marker arm/restore
           # owned by its own PostGuard.
           |> Ash.Changeset.for_create(:create_reversal, entry_attrs, authorize?: false)
           |> Ash.create(authorize?: false) do
        {:ok, entry} ->
          # The bill's OWN state flip — the whole point of the transition:
          # draft → approved. (E1's PostGuard stamps ENTRIES; the bill stamps
          # itself here, in the same transaction, riding the PostingMarker
          # arm the action carries.) posted_entry_id/posted_at anchor the
          # posting for the read side and any later audit.
          changeset
          |> Ash.Changeset.force_change_attribute(:status, :approved)
          |> Ash.Changeset.force_change_attribute(:posted_entry_id, entry.id)
          |> Ash.Changeset.force_change_attribute(:posted_at, now())

        {:error, reason} ->
          Ash.Changeset.add_error(changeset,
            field: :base,
            message: "the AP bill's posting entry failed to land: #{inspect(reason)}"
          )
      end
    else
      {:error, reason} ->
        Ash.Changeset.add_error(changeset,
          field: :base,
          message: "the AP bill cannot be approved: #{format(reason)}"
        )
    end
  end

  # The exactly-once condition re-checked over the PERSISTED row inside the
  # decision transaction (the caller may hold a stale record; ApLines' own
  # state check ran at build time against that possibly-stale data).
  defp refuse_non_draft(changeset) do
    case Ash.Changeset.get_attribute(changeset, :status) || changeset.data.status do
      :draft -> :ok
      other -> {:error, {:not_draft, other}}
    end
  end

  defp lines_of(bill) do
    case bill.lines do
      lines when is_list(lines) and lines != [] -> {:ok, lines}
      _ -> {:error, :no_lines}
    end
  end

  defp refuse_zero_total(lines) do
    if total(lines) > 0, do: :ok, else: {:error, :zero_total}
  end

  defp total(lines), do: Enum.sum(Enum.map(lines, &(&1.amount_cents || 0)))

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

  defp format({:unmapped_posting_account, key}),
    do: "no PostingAccount row maps `#{key}` for this org (fail-honest — accounts are a " <>
          "host decision; seed the org's posting accounts first)"

  defp format({:not_draft, status}),
    do: "the bill is #{inspect(status)} — only a :draft bill can be approved"

  defp format(:no_lines), do: "the bill carries no lines"
  defp format(:zero_total), do: "the bill total is zero — an AP posting of nothing is not a fact"
  defp format(reason), do: inspect(reason)

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp memo_suffix(nil), do: ""
  defp memo_suffix(""), do: ""
  defp memo_suffix(memo), do: " — " <> memo
end
