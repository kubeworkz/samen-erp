defmodule Samen.Scopes.Finance.CostAllocationPosting do
  @moduledoc """
  The posting cascade for a cost allocation (WS-ACCT Phase 10; ADR-054
  decision 11).

  Runs in `:post`'s `before_action` — inside the action's transaction. It
  re-checks the draft against governed state and lands **ONE** journal entry
  for the whole split, never one entry per target:

      for every cost object share:
        Dr target account   share cents   dimension: <axis> => cost object
        Cr source account   share cents   dimension: <axis> => cost object

  The symmetric pair is what makes the entry R6-clean: each cost object's
  debits equal its credits, so the allocation is a reclass *within* every
  programme (mask expense → WIP for that programme), while the account totals
  move the invoice's cost exactly once. A loop of N one-sided reclasses would
  break R6b and, worse, be N posts where the fact is one.

  ## Why the checks repeat

  `:post` is a separate action from `:draft`; a caller may hold a stale row.
  The cascade therefore:

    * requires the PERSISTED status to still be `:draft` (a re-post is
      refused, never silently repeated);
    * requires the shares to sum to the header's amount, and the header to tie
      to the bill's own line for the source account — even though an approved
      bill is frozen, the belt is cheap and names `allocation_drift` instead of
      posting a number nobody can re-derive;
    * names both accounts from the header and refuses a same-account pair;
    * requires at least two shares (an allocation, not a reclass).

  The entry is created through the host's POSTED-born factory
  (`:create_reversal`), anchored `source_key: "cost_allocation"`,
  `source_id: <this header>`. Its own PostGuard owns the transaction-local
  marker; the header action carries `PostingMarker` so the marker is armed
  before the factory restores/inserts inside the same transaction (the AP/PO
  approve precedent).
  """

  use Ash.Resource.Change

  require Ash.Query

  @source_key "cost_allocation"

  @impl true
  def change(changeset, opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      post(changeset, org_id(changeset), opts)
    end)
  end

  defp post(changeset, org_id, opts) do
    header = changeset.data

    with :ok <- require_draft(header),
         {:ok, shares} <- shares_of(Keyword.fetch!(opts, :share), org_id, header.id),
         :ok <- require_two(shares),
         :ok <- tie_total(header, shares),
         {:ok, source} <- load_account(Keyword.fetch!(opts, :account), org_id, header.source_account_id),
         {:ok, target} <- load_account(Keyword.fetch!(opts, :account), org_id, header.target_account_id),
         :ok <- require_different(source, target),
         {:ok, invoice} <- load_invoice(Keyword.fetch!(opts, :invoice), org_id, header),
         :ok <- require_invoice_live(invoice),
         :ok <- tie_bill(header, invoice) do
      land(changeset, org_id, header, shares, source, target, invoice, Keyword.fetch!(opts, :entry))
    else
      {:error, reason} -> error(changeset, format(reason))
    end
  end

  # ── re-checked facts ───────────────────────────────────────────────────────

  defp require_draft(%{status: :draft}), do: :ok

  defp require_draft(%{status: other}) do
    {:error, {:not_draft, other}}
  end

  defp shares_of(share_mod, org_id, allocation_id) do
    # authz-scope: system posting cascade — the shares of THIS org's allocation,
    # read inside the approved action's transaction to rebuild the entry.
    rows =
      share_mod
      |> Ash.Query.filter(org_id == ^org_id and cost_allocation_id == ^allocation_id)
      |> Ash.Query.sort(cost_object_id: :asc)
      |> Ash.read!(authorize?: false)

    case rows do
      [] -> {:error, :no_shares}
      rows -> {:ok, rows}
    end
  end

  defp require_two(shares) when length(shares) >= 2, do: :ok
  defp require_two(_shares), do: {:error, :too_few_shares}

  defp tie_total(header, shares) do
    total = Enum.reduce(shares, 0, &(&1.allocated_cents + &2))

    cond do
      total <= 0 -> {:error, :zero_total}
      is_nil(header.amount_cents) -> {:error, :no_header_amount}
      header.amount_cents != total -> {:error, {:total_mismatch, header.amount_cents, total}}
      true -> :ok
    end
  end

  defp load_account(account_mod, org_id, account_id) do
    case Ash.get(account_mod, account_id, authorize?: false) do
      {:ok, account} ->
        account = Ash.load!(account, [:org_id], authorize?: false)

        if account.org_id == org_id do
          {:ok, account}
        else
          {:error, :foreign_account}
        end

      {:error, _reason} ->
        {:error, :missing_account}
    end
  end

  defp require_different(%{id: id}, %{id: id}), do: {:error, :same_account}
  defp require_different(_source, _target), do: :ok

  defp load_invoice(invoice_mod, org_id, header) do
    case Ash.get(invoice_mod, header.ap_invoice_id, authorize?: false) do
      {:ok, invoice} ->
        invoice = Ash.load!(invoice, [:org_id, :lines, :status, :number], authorize?: false)

        if invoice.org_id == org_id do
          {:ok, invoice}
        else
          {:error, :foreign_invoice}
        end

      {:error, _reason} ->
        {:error, :missing_invoice}
    end
  end

  defp require_invoice_live(%{status: status, posted_entry_id: entry_id})
       when status in [:approved, :paid] and not is_nil(entry_id),
       do: :ok

  defp require_invoice_live(%{status: :void}), do: {:error, :void_invoice}
  defp require_invoice_live(_invoice), do: {:error, :unposted_invoice}

  defp tie_bill(header, invoice) do
    amount =
      invoice.lines
      |> Enum.filter(&(line_account(&1) == header.source_account_id))
      |> Enum.reduce(0, fn line, acc -> acc + (line_amount(line) || 0) end)

    if amount == header.amount_cents do
      :ok
    else
      {:error, {:allocation_drift, header.amount_cents, amount}}
    end
  end

  defp line_account(line), do: Map.get(line, :account_id) || Map.get(line, "account_id")
  defp line_amount(line), do: Map.get(line, :amount_cents) || Map.get(line, "amount_cents")

  # ── the one entry ──────────────────────────────────────────────────────────

  defp land(changeset, org_id, header, shares, source, target, invoice, entry_mod) do
    axis = Atom.to_string(header.axis)

    entry_lines =
      Enum.flat_map(shares, fn share ->
        refs = %{axis => share.cost_object_id}

        [
          %{
            account_id: target.id,
            debit_cents: share.allocated_cents,
            credit_cents: 0,
            dimension_refs: refs
          },
          %{
            account_id: source.id,
            debit_cents: 0,
            credit_cents: share.allocated_cents,
            dimension_refs: refs
          }
        ]
      end)

    entry_attrs = %{
      org_id: org_id,
      entry_date: header.allocated_on,
      memo: "Cost allocation — #{invoice.number} (#{header.basis})",
      source_key: @source_key,
      source_id: header.id,
      lines: entry_lines
    }

    case entry_mod
         |> Ash.Changeset.for_create(:create_reversal, entry_attrs, authorize?: false)
         |> Ash.create(authorize?: false) do
      {:ok, entry} ->
        changeset
        |> Ash.Changeset.force_change_attribute(:status, :posted)
        |> Ash.Changeset.force_change_attribute(:entry_id, entry.id)
        |> Ash.Changeset.force_change_attribute(:posted_at, now())

      {:error, reason} ->
        error(changeset, "the allocation's posting entry failed to land: #{inspect(reason)}")
    end
  end

  # ── errors / plumbing ──────────────────────────────────────────────────────

  defp format({:not_draft, status}) do
    "this allocation is #{inspect(status)} — a posted allocation is final; a " <>
      "correction is a reversing entry, never a re-post"
  end

  defp format(:no_shares), do: "the allocation carries no shares"
  defp format(:too_few_shares), do: "an allocation needs at least two cost objects"
  defp format(:zero_total), do: "the allocation total is zero — that is not a fact"
  defp format(:no_header_amount), do: "the allocation header has no amount"
  defp format(:foreign_account), do: "an allocation account does not belong to this org"
  defp format(:missing_account), do: "an allocation account no longer exists"
  defp format(:same_account), do: "the source and target accounts are the same — nothing would move"

  defp format({:total_mismatch, header, shares}) do
    "the allocation header says #{header} cents but its shares sum to #{shares} — a " <>
      "post must tie to the split it was drafted from"
  end

  defp format({:allocation_drift, header, bill}) do
    "the bill's cost on that account is now #{bill} cents, not #{header} — the draft " <>
      "no longer describes the invoice (allocation drift); re-draft instead of posting " <>
      "a split that does not tie"
  end

  defp format(:void_invoice), do: "the AP bill is void — there is no cost to allocate"
  defp format(:unposted_invoice), do: "the AP bill is no longer posted — there is no cost to allocate"
  defp format(:foreign_invoice), do: "the AP bill does not belong to this org"
  defp format(:missing_invoice), do: "the AP bill no longer exists"

  defp error(changeset, message) do
    Ash.Changeset.add_error(changeset, field: :base, message: message)
  end

  defp org_id(changeset) do
    case Ash.Changeset.get_attribute(changeset, :org_id) do
      %Ash.NotLoaded{} -> persisted_org_id(changeset.data)
      nil -> persisted_org_id(changeset.data)
      value -> value
    end
  end

  defp persisted_org_id(record) do
    case record.org_id do
      %Ash.NotLoaded{} -> Ash.load!(record, [:org_id], authorize?: false).org_id
      value -> value
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
