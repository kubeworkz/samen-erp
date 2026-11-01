defmodule Samen.Scopes.Finance.DepreciationPosting do
  @moduledoc """
  The depreciation cascade (WS-ACCT Phase 8; ADR-054 D9): on `:depreciate`,
  land the period's journal entry — debit the asset-kind's expense account by
  `amount_cents`, credit its accumulated contra account — anchored
  `source_key: "asset_posting"`, `source_id: <posting id>`, in the SAME
  transaction as the posting row.

  ## The amount is checked against the DERIVED schedule

  The caller does not get to say what a period costs. The cascade re-derives
  the slice from the asset's contract (`AssetSchedule.slice/2`) and refuses any
  other number (`{:amount_not_the_schedule, …}`), any period outside the term,
  and any date other than the period's last day. That is what makes the
  no-schedule-table discipline safe: the only persisted fact carries exactly
  the value the contract derives, so a register rebuilt from `{cost, life,
  salvage}` and the postings can never disagree.

  ## The posting pair

  * `:intangible` — Dr `amortization_expense` / Cr `accumulated_amortization`
    (the PDK licence: 7000 / 1510 in the Kubeworkz books);
  * `:equipment` — Dr `depreciation_expense` / Cr `accumulated_depreciation`
    (lab gear: 6030 / 1520).

  Both meanings are resolved fail-honest: an unmapped account refuses the
  posting, exactly like every other Finance flow. Accounts are a host decision.

  ## Draft first, then the governed `:post`

  A create-born-POSTED entry cannot insert its own lines — `PostGuard`'s marker
  restore unwinds before `EntryLines` materializes them — so the cascade creates
  a draft and then calls the ordinary `:post` action. That also means R1
  (`PostBalance`), R6 (`DimensionBalance`) and R10 (`PeriodGuard`) evaluate the
  entry exactly as they would a human posting: a closed period still refuses,
  and a dimensioned asset's two legs must agree on the cost object.

  ## The id is minted BEFORE the entry

  The posting row and its entry reference each other through the ADR-041
  anchor, so the entry's `source_id` must be the posting's id. A
  `before_action` runs before Ash assigns the primary key, so this change mints
  the id (`Ash.UUID.generate/0`), posts the entry against it, and forces it
  onto the changeset. The alternative (insert, then create the entry, then
  update the row) would need an UPDATE on an append-only fact, which the table
  refuses — correctly.

  A failure anywhere in the cascade adds an error to the changeset, so the
  posting row does not land either. There is no state in which a posting exists
  without its entry.
  """

  use Ash.Resource.Change

  @source_key "asset_posting"

  @doc "The object-ref anchor every depreciation entry carries."
  def source_key, do: @source_key

  @impl true
  def change(changeset, opts, _context) do
    asset_mod = Keyword.fetch!(opts, :asset)
    entry_mod = Keyword.fetch!(opts, :entry)
    pa_mod = Keyword.fetch!(opts, :posting_account)

    org_id = Ash.Changeset.get_attribute(changeset, :org_id)

    Ash.Changeset.before_action(changeset, fn changeset ->
      post(changeset, org_id, asset_mod, entry_mod, pa_mod)
    end)
  end

  defp post(changeset, org_id, asset_mod, entry_mod, pa_mod) do
    asset_id = Ash.Changeset.get_attribute(changeset, :asset_id)
    amount = Ash.Changeset.get_attribute(changeset, :amount_cents)
    period_key = Ash.Changeset.get_attribute(changeset, :period_key)
    depreciated_on = Ash.Changeset.get_attribute(changeset, :depreciated_on)

    with {:ok, asset} <- load_asset(asset_mod, org_id, asset_id),
         {:ok, period} <- parse_period(period_key),
         {:ok, expected} <- slice(asset, period_key),
         :ok <- ensure_amount(expected, amount),
         :ok <- ensure_period_end(period, depreciated_on),
         {:ok, expense} <- posting_account(pa_mod, org_id, expense_meaning(asset.kind)),
         {:ok, contra} <- posting_account(pa_mod, org_id, contra_meaning(asset.kind)),
         id <- Ash.UUID.generate(),
         {:ok, _entry} <-
           create_entry(
             entry_mod,
             org_id,
             id,
             asset,
             period_key,
             depreciated_on,
             amount,
             expense,
             contra
           ) do
      changeset
      |> Ash.Changeset.force_change_attribute(:id, id)
      |> Ash.Changeset.force_change_attribute(:expense_account_id, expense.account_id)
      |> Ash.Changeset.force_change_attribute(:contra_account_id, contra.account_id)
    else
      {:error, reason} ->
        Ash.Changeset.add_error(changeset,
          field: :base,
          message: "the depreciation cannot be posted: #{format(reason)}"
        )
    end
  end

  # Read the asset PINNED to this org (authorize?: false — this is the system
  # cascade): an asset from another tenant is invisible, so it cannot be posted
  # against, and the refusal is a nil read rather than a comparison over
  # attributes the select does not carry.
  defp load_asset(asset_mod, org_id, asset_id) do
    require Ash.Query

    case asset_mod
         |> Ash.Query.filter(id == ^asset_id and org_id == ^org_id)
         |> Ash.read_one(authorize?: false) do
      {:ok, nil} -> {:error, {:foreign_asset, asset_id}}
      {:ok, asset} -> {:ok, asset}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_period(key) do
    case Samen.Scopes.Finance.AssetSchedule.parse_period(key) do
      {:ok, period} -> {:ok, period}
      :error -> {:error, {:bad_period, key}}
    end
  end

  defp slice(asset, period_key) do
    case Samen.Scopes.Finance.AssetSchedule.slice(asset, period_key) do
      {:ok, amount} -> {:ok, amount}
      :outside_term -> {:error, {:outside_term, period_key}}
      {:error, :bad_period} -> {:error, {:bad_period, period_key}}
    end
  end

  # The cascade re-derives the slice; a caller-supplied number is only accepted
  # when it IS the schedule.
  defp ensure_amount(expected, expected), do: :ok

  defp ensure_amount(expected, got),
    do: {:error, {:amount_not_the_schedule, expected, got}}

  # The posting's date is the period end, not an arbitrary day inside it. The
  # run always passes it; this refuses a crafted caller that would date the
  # entry somewhere nobody reviewed.
  defp ensure_period_end(period, on) do
    expected = Samen.Scopes.Finance.AssetSchedule.period_end(period)

    if Date.compare(on, expected) == :eq,
      do: :ok,
      else: {:error, {:not_period_end, expected, on}}
  end

  defp expense_meaning(:intangible), do: :amortization_expense
  defp expense_meaning(:equipment), do: :depreciation_expense

  defp contra_meaning(:intangible), do: :accumulated_amortization
  defp contra_meaning(:equipment), do: :accumulated_depreciation

  defp label(:intangible), do: "Amortization"
  defp label(:equipment), do: "Depreciation"

  defp posting_account(pa_mod, org_id, key) do
    require Ash.Query

    case pa_mod
         |> Ash.Query.filter(org_id == ^org_id and key == ^key)
         |> Ash.read_one(authorize?: false) do
      {:ok, nil} -> {:error, {:unmapped_posting_account, key}}
      {:ok, row} -> {:ok, row}
      {:error, reason} -> {:error, reason}
    end
  end

  # Draft first (so EntryLines can materialize under the draft belt), then the
  # governed `:post` (so R1/R6/R10 run). Both steps are inside the posting's
  # transaction: a refusal on either leaves neither row.
  defp create_entry(
         entry_mod,
         org_id,
         id,
         asset,
         period_key,
         entry_date,
         amount,
         expense,
         contra
       ) do
    with {:ok, draft} <-
           entry_mod
           |> Ash.Changeset.for_create(
             :create,
             %{
               org_id: org_id,
               entry_date: entry_date,
               memo: "#{label(asset.kind)} #{asset.code} #{period_key}",
               source_key: @source_key,
               source_id: id,
               lines: [
                 %{
                   account_id: expense.account_id,
                   debit_cents: amount,
                   dimension_refs: dimension_refs(asset)
                 },
                 %{
                   account_id: contra.account_id,
                   credit_cents: amount,
                   dimension_refs: dimension_refs(asset)
                 }
               ]
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

  # Both legs carry the asset's dimension or neither does (R6a). An
  # undimensioned asset stays undimensioned, which is a vacuous pass exactly
  # like a base-system posting.
  defp dimension_refs(%{cost_object_id: nil}), do: %{}

  defp dimension_refs(%{cost_object_id: cost_object_id, dimension_key: key}),
    do: %{to_string(key) => cost_object_id}

  defp format({:unmapped_posting_account, key}),
    do:
      "no PostingAccount row maps `#{key}` for this org (fail-honest — accounts are a " <>
        "host decision; seed the org's posting accounts first)"

  defp format({:foreign_asset, id}), do: "asset #{id} does not belong to this org"

  defp format({:amount_not_the_schedule, expected, got}),
    do:
      "the asset's derived schedule says #{expected} cents for this period, but the " <>
        "posting carries #{got} — the schedule is the only source of the amount"

  defp format({:outside_term, key}),
    do: "period #{key} is outside the asset's term — there is no slice to post"

  defp format({:not_period_end, expected, got}),
    do: "the posting must be dated the period's last day (#{expected}), not #{got}"

  defp format({:bad_period, key}), do: "#{inspect(key)} is not a \"YYYY-MM\" period key"

  defp format(reason), do: inspect(reason)
end
