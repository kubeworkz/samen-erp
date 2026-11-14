defmodule Samen.Scopes.Finance.AssetDisposal do
  @moduledoc """
  The one-way disposal of an `Asset` (WS-ACCT Phase 8; ADR-054 D9).

  `:dispose` records the retirement date AND posts the disposal entry in the
  same transaction. The standard entry is:

      Dr cash / proceeds account                 proceeds
      Dr accumulated amortization/depreciation   accumulated
      Cr asset cost account                      cost
      Cr disposal gain                           gain   (when proceeds > NBV)
      Dr disposal loss                           loss   (when proceeds < NBV)

  where `NBV = cost - accumulated` and `gain/loss = proceeds - NBV`. The cost
  account is the kind's `asset_cost_intangible` / `asset_cost_equipment`; a
  construction-in-progress asset is removed from `construction_in_progress`
  instead. All meanings are resolved fail-honest. The entry is anchored
  `source_key: "asset_disposal"`, `source_id: <asset id>`.

  The disposal month is still the first month the schedule stops; no
  catch-up depreciation is posted. Proceeds are the one amount the caller must
  supply. A nil proceeds value means zero (a scrap write-off), not an
  invention: the resulting loss is the remaining NBV.

  Disposal clears cost and accumulated on the asset's CURRENT dimension. That is
  complete because `AssetTransfer` refuses a transfer once the asset has any
  ledger history (a posted slice or an in-service reclassification): every
  asset-owned cost/contra entry therefore carries the same dimension. Moving an
  in-service asset between cost objects cannot be represented as a subledger
  transfer under R6; it needs its own accounting decision.

  Legacy assets transferred under the earlier permissive behavior are not
  assumed safe: `:dispose` reads the asset-owned entry lines and refuses when any
  carries a dimension different from the asset's current dimension. The refusal
  happens before accounts are resolved or an entry is posted, so the mixed state
  is not silently cleared on one side.

  Refusals, all inside the update's transaction:

    * disposing an already-disposed asset (the transition is one-way);
    * a disposal dated before acquisition, or before an active asset was placed
      in service;
    * a disposal dated before the latest posted depreciation period — those
      slices are facts and cannot be pulled into the disposal or unposted;
    * a legacy asset whose posted depreciation or in-service entry carries a
      different cost object from its current dimension;
    * a negative proceeds value;
    * a disposal whose entry cannot land (closed period, unmapped account).
  """

  require Ash.Query

  alias Samen.Scopes.Finance.AssetEntry
  alias Samen.Scopes.Finance.AssetSchedule

  use Ash.Resource.Change

  @source_key "asset_disposal"

  @doc "The object-ref anchor every disposal entry carries."
  def source_key, do: @source_key

  @impl true
  def change(changeset, opts, _context) do
    asset_mod = Keyword.fetch!(opts, :asset)
    posting_mod = Keyword.fetch!(opts, :posting)
    entry_mod = Keyword.fetch!(opts, :entry)
    pa_mod = Keyword.fetch!(opts, :posting_account)

    Ash.Changeset.before_action(changeset, fn changeset ->
      dispose(changeset, asset_mod, posting_mod, entry_mod, pa_mod)
    end)
  end

  defp dispose(changeset, asset_mod, posting_mod, entry_mod, pa_mod) do
    with {:ok, asset} <- load_asset(asset_mod, changeset.data.id) do
      do_dispose(changeset, asset, posting_mod, entry_mod, pa_mod)
    else
      {:error, reason} ->
        add_error(changeset, :base, "the asset cannot be loaded for disposal: #{format(reason)}")
    end
  end

  defp load_asset(asset_mod, id) do
    case asset_mod
         |> Ash.Query.filter(id == ^id)
         |> Ash.Query.ensure_selected([:org_id])
         |> Ash.read_one(authorize?: false) do
      {:ok, nil} -> {:error, {:asset_not_found, id}}
      {:ok, asset} -> {:ok, asset}
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_dispose(changeset, asset, posting_mod, entry_mod, pa_mod) do
    on = Ash.Changeset.get_argument(changeset, :disposed_on)
    proceeds = Ash.Changeset.get_argument(changeset, :proceeds_cents) || 0

    cond do
      asset.status == :disposed ->
        add_error(
          changeset,
          :base,
          "asset #{asset.code} is already disposed (#{Date.to_iso8601(asset.disposed_on)}) — " <>
            "a disposal is one-way; a correction is a journal entry, not an un-disposal"
        )

      is_nil(on) ->
        add_error(changeset, :disposed_on, "a disposal must be dated")

      Date.compare(on, asset.acquired_on) == :lt ->
        add_error(
          changeset,
          :disposed_on,
          "the disposal date (#{Date.to_iso8601(on)}) is before the acquisition " <>
            "(#{Date.to_iso8601(asset.acquired_on)}) — an asset cannot be retired before it exists"
        )

      not is_integer(proceeds) or proceeds < 0 ->
        add_error(changeset, :proceeds_cents, "proceeds must be a non-negative integer")

      active_before_service?(asset, on) ->
        add_error(
          changeset,
          :disposed_on,
          "the disposal date (#{Date.to_iso8601(on)}) is before the asset was placed in " <>
            "service (#{Date.to_iso8601(asset.in_service_on)})"
        )

      true ->
        post_disposal(changeset, asset, on, proceeds, posting_mod, entry_mod, pa_mod)
    end
  end

  defp active_before_service?(%{status: :active, in_service_on: %Date{} = in_service}, on),
    do: Date.compare(on, in_service) == :lt

  defp active_before_service?(_asset, _on), do: false

  defp post_disposal(changeset, asset, on, proceeds, posting_mod, entry_mod, pa_mod) do
    with {:ok, postings} <- asset_postings(asset, posting_mod),
         accumulated = Enum.reduce(postings, 0, &(&1.amount_cents + &2)),
         :ok <- ensure_cip_has_no_slices(asset, accumulated),
         :ok <- ensure_disposal_not_before_latest_posting(asset, on, postings),
         :ok <- ensure_one_dimension(asset, postings, entry_mod),
         {:ok, accounts} <- accounts(asset, pa_mod, proceeds, accumulated),
         gain_loss = proceeds + accumulated - asset.cost_cents,
         {:ok, entry} <-
           post_entry(asset, on, proceeds, accumulated, gain_loss, entry_mod, accounts) do
      changeset
      |> Ash.Changeset.force_change_attribute(:status, :disposed)
      |> Ash.Changeset.force_change_attribute(:disposed_on, on)
      |> Ash.Changeset.force_change_attribute(:disposal_proceeds_cents, proceeds)
      |> Ash.Changeset.force_change_attribute(:disposal_gain_loss_cents, gain_loss)
      |> Ash.Changeset.force_change_attribute(:disposal_entry_id, entry.id)
    else
      {:error, reason} ->
        add_error(
          changeset,
          :base,
          "the disposal cannot be posted: #{format(reason)}"
        )
    end
  end

  defp asset_postings(asset, posting_mod) do
    case posting_mod
         |> Ash.Query.filter(org_id == ^asset.org_id and asset_id == ^asset.id)
         |> Ash.read(authorize?: false) do
      {:ok, postings} -> {:ok, postings}
      {:error, reason} -> {:error, {:postings_unreadable, reason}}
    end
  end

  # A disposal is a prospective event: the posted slices are facts it cannot
  # rewrite. If the latest posted month is after the disposal month, summing
  # every posting into the disposal would carry a future slice into
  # accumulated/gain-loss while leaving that slice posted. Refuse instead; a
  # correction is a reversal, not an un-disposal.
  defp ensure_disposal_not_before_latest_posting(_asset, _on, []), do: :ok

  defp ensure_disposal_not_before_latest_posting(asset, on, postings) do
    latest = Enum.max_by(postings, & &1.period_key)

    case AssetSchedule.parse_period(latest.period_key) do
      {:ok, {year, month}} ->
        period_start = Date.new!(year, month, 1)

        if Date.compare(on, period_start) == :lt do
          {:error, {:disposal_before_latest_posting, asset.code, latest.period_key, on}}
        else
          :ok
        end

      :error ->
        {:error, {:invalid_posting_period, asset.code, latest.period_key}}
    end
  end

  defp ensure_cip_has_no_slices(%{status: :under_construction}, accumulated)
       when accumulated > 0,
       do: {:error, {:cip_has_depreciation, accumulated}}

  defp ensure_cip_has_no_slices(_asset, _accumulated), do: :ok

  # A transfer made under the pre-restriction behavior could leave posted cost
  # or accumulated on the old cost object. Disposal clears only the current
  # dimension, so read the asset-owned entries themselves and refuse a mixed
  # state. `transfer_history` alone is not enough: a transfer before any
  # posting is safe and leaves one dimension on every entry.
  defp ensure_one_dimension(asset, postings, entry_mod) do
    current = AssetEntry.dimension_refs(asset)

    with {:ok, entries} <- asset_entries(asset, postings, entry_mod) do
      mismatched =
        entries
        |> Enum.flat_map(fn entry ->
          entry.lines
          |> List.wrap()
          |> Enum.map(&normalize_dimensions(&1.dimension_refs))
          |> Enum.reject(&(&1 == current))
          |> Enum.map(&{entry.id, &1})
        end)
        |> Enum.uniq()

      case mismatched do
        [] ->
          :ok

        [{entry_id, dims} | _] ->
          {:error, {:mixed_dimensions, asset.code, current, entry_id, dims, length(mismatched)}}
      end
    end
  end

  defp asset_entries(asset, postings, entry_mod) do
    posting_ids = Enum.map(postings, & &1.id)

    with {:ok, posting_entries} <- posting_entries(asset, posting_ids, entry_mod),
         {:ok, in_service_entries} <- in_service_entries(asset, entry_mod) do
      {:ok, posting_entries ++ in_service_entries}
    end
  end

  defp posting_entries(_asset, [], _entry_mod), do: {:ok, []}

  defp posting_entries(asset, posting_ids, entry_mod) do
    entry_mod
    |> Ash.Query.filter(
      org_id == ^asset.org_id and source_key == "asset_posting" and source_id in ^posting_ids
    )
    |> Ash.Query.load(:lines)
    |> Ash.read(authorize?: false)
    |> entries_result()
  end

  defp in_service_entries(%{in_service_entry_id: nil}, _entry_mod), do: {:ok, []}

  defp in_service_entries(asset, entry_mod) do
    entry_mod
    |> Ash.Query.filter(org_id == ^asset.org_id and id == ^asset.in_service_entry_id)
    |> Ash.Query.load(:lines)
    |> Ash.read(authorize?: false)
    |> entries_result()
  end

  defp entries_result({:ok, entries}), do: {:ok, entries}
  defp entries_result({:error, reason}), do: {:error, {:asset_entries_unreadable, reason}}

  defp normalize_dimensions(nil), do: %{}

  defp normalize_dimensions(refs) when is_map(refs),
    do: Map.new(refs, fn {key, value} -> {to_string(key), value} end)

  defp normalize_dimensions(_refs), do: %{}

  defp accounts(asset, pa_mod, proceeds, accumulated) do
    gain_or_loss? = proceeds + accumulated - asset.cost_cents != 0

    with {:ok, cost} <- AssetEntry.posting_account(pa_mod, asset.org_id, cost_key(asset)),
         {:ok, cash} <- optional_account(pa_mod, asset.org_id, :cash, proceeds > 0),
         {:ok, contra} <-
           optional_account(pa_mod, asset.org_id, contra_key(asset), accumulated > 0),
         {:ok, gain_loss} <-
           optional_account(pa_mod, asset.org_id, :disposal_gain_loss, gain_or_loss?) do
      {:ok, %{cost: cost, cash: cash, contra: contra, gain_loss: gain_loss}}
    end
  end

  defp optional_account(_pa_mod, _org_id, _key, false), do: {:ok, nil}

  defp optional_account(pa_mod, org_id, key, true) do
    AssetEntry.posting_account(pa_mod, org_id, key)
  end

  defp post_entry(asset, on, proceeds, accumulated, gain_loss, entry_mod, accounts) do
    dims = AssetEntry.dimension_refs(asset)

    lines =
      []
      |> add_line(proceeds > 0, accounts.cash, proceeds, 0, dims)
      |> add_line(accumulated > 0, accounts.contra, accumulated, 0, dims)
      |> add_line(true, accounts.cost, 0, asset.cost_cents, dims)
      |> add_line(gain_loss > 0, accounts.gain_loss, 0, gain_loss, dims)
      |> add_line(gain_loss < 0, accounts.gain_loss, -gain_loss, 0, dims)

    AssetEntry.post(entry_mod, %{
      org_id: asset.org_id,
      entry_date: on,
      memo: "Disposal #{asset.code}",
      source_key: @source_key,
      source_id: asset.id,
      lines: lines
    })
  end

  defp add_line(lines, false, _account, _debit, _credit, _dims), do: lines

  defp add_line(lines, true, account, debit, credit, dims) do
    lines ++
      [
        %{
          account_id: account.account_id,
          debit_cents: debit,
          credit_cents: credit,
          dimension_refs: dims
        }
      ]
  end

  defp cost_key(%{status: :under_construction}), do: :construction_in_progress
  defp cost_key(%{kind: :intangible}), do: :asset_cost_intangible
  defp cost_key(%{kind: :equipment}), do: :asset_cost_equipment

  defp contra_key(%{kind: :intangible}), do: :accumulated_amortization
  defp contra_key(%{kind: :equipment}), do: :accumulated_depreciation

  defp add_error(changeset, field, message),
    do: Ash.Changeset.add_error(changeset, field: field, message: message)

  defp format({:unmapped_posting_account, key}),
    do:
      "no PostingAccount row maps `#{key}` for this org (fail-honest — accounts are a " <>
        "host decision; seed the org's posting accounts first)"

  defp format({:cip_has_depreciation, accumulated}),
    do:
      "a construction-in-progress asset has #{accumulated} cents of depreciation postings; " <>
        "correct those facts before disposing of the asset"

  defp format({:disposal_before_latest_posting, code, period_key, on}),
    do:
      "asset #{code} has depreciation posted for #{period_key}, after the disposal date " <>
        "#{Date.to_iso8601(on)} — posted slices are facts; reverse them before disposing"

  defp format({:invalid_posting_period, code, period_key}),
    do:
      "asset #{code} has a depreciation posting with an invalid period key " <>
        "#{inspect(period_key)}"

  defp format({:mixed_dimensions, code, current, entry_id, dims, count}) do
    "asset #{code} has #{count} legacy dimension group(s) different from its current " <>
      "dimension (current #{format_dimensions(current)}; entry #{entry_id} uses " <>
      "#{format_dimensions(dims)}) — a pre-restriction transfer left cost/accumulated on " <>
      "the old cost object, and disposal clears only the current dimension. Correct those " <>
      "ledger facts before disposing."
  end

  defp format({:asset_entries_unreadable, reason}),
    do: "asset entries are unreadable for the dimension check: #{inspect(reason)}"

  defp format({:postings_unreadable, reason}),
    do: "asset postings are unreadable: #{inspect(reason)}"

  defp format({:asset_not_found, id}), do: "asset #{id} was not found"
  defp format(%{__exception__: true} = error), do: Exception.message(error)
  defp format(reason), do: inspect(reason)

  defp format_dimensions(dims) when dims == %{}, do: "undimensioned"

  defp format_dimensions(dims) do
    dims
    |> Enum.sort()
    |> Enum.map_join(", ", fn {key, value} -> "#{key}=#{value}" end)
  end
end
