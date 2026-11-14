defmodule Samen.Scopes.Finance.AssetCreate do
  @moduledoc """
  The create-time lifecycle decision (WS-ACCT Phase 8; ADR-054 D9).

  An ordinary asset is born `:active` with `in_service_on = acquired_on`.
  `under_construction: true` instead creates a CIP: no depreciation schedule
  starts until a dated `:place_in_service` transfer. The status is not a
  caller-supplied field — it follows from this one explicit choice.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    acquired = Ash.Changeset.get_attribute(changeset, :acquired_on)
    under_construction = Ash.Changeset.get_argument(changeset, :under_construction) == true
    in_service_on = Ash.Changeset.get_argument(changeset, :in_service_on)

    cond do
      is_nil(acquired) ->
        changeset

      under_construction and not is_nil(in_service_on) ->
        Ash.Changeset.add_error(changeset,
          field: :in_service_on,
          message:
            "a construction-in-progress asset has no in-service date yet; " <>
              "use :place_in_service when the asset is ready"
        )

      under_construction ->
        changeset
        |> Ash.Changeset.force_change_attribute(:status, :under_construction)
        |> Ash.Changeset.force_change_attribute(:in_service_on, nil)

      not is_nil(in_service_on) and Date.compare(in_service_on, acquired) == :lt ->
        Ash.Changeset.add_error(changeset,
          field: :in_service_on,
          message:
            "the in-service date (#{Date.to_iso8601(in_service_on)}) is before the acquisition " <>
              "(#{Date.to_iso8601(acquired)})"
        )

      true ->
        changeset
        |> Ash.Changeset.force_change_attribute(:status, :active)
        |> Ash.Changeset.force_change_attribute(:in_service_on, in_service_on || acquired)
    end
  end
end

defmodule Samen.Scopes.Finance.AssetTransfer do
  @moduledoc """
  A dated cost-object transfer (WS-ACCT Phase 8; ADR-054 D9).

  The asset's current `cost_object_id` / `dimension_key` govern FUTURE
  depreciation entries. The action appends a bounded transfer record — from/to
  ids and the date — so the register can explain why a later slice carries a
  different cost object.

  **A transfer is available only before the asset has any ledger history.**
  Once a depreciation slice has posted or a CIP has been placed in service,
  moving the asset would leave the already-posted cost/accumulated balance on
  the old dimension, and a later disposal clears only the current dimension.
  That balance cannot be moved between cost objects: R6 requires every entry to
  balance per cost object, so a one-sided reclassification is refused. Refusing
  the transfer is the honest boundary; changing the cost object of an in-service
  asset is a new-asset or correcting-entry decision, not a subledger edit.

  A transfer before any ledger history posts no journal entry: it changes which
  dimension future entries will carry, and no balance exists to reclassify.
  """

  require Ash.Query

  use Ash.Resource.Change

  @impl true
  def change(changeset, opts, _context) do
    asset_mod = Keyword.fetch!(opts, :asset)
    posting_mod = Keyword.fetch!(opts, :posting)

    Ash.Changeset.before_action(changeset, fn changeset ->
      transfer(changeset, asset_mod, posting_mod)
    end)
  end

  defp transfer(changeset, asset_mod, posting_mod) do
    with {:ok, asset} <- load_asset(asset_mod, changeset.data.id) do
      do_transfer(changeset, asset, posting_mod)
    else
      {:error, reason} ->
        add_error(changeset, :base, "the asset cannot be loaded for transfer: #{inspect(reason)}")
    end
  end

  defp do_transfer(changeset, asset, posting_mod) do
    on = Ash.Changeset.get_argument(changeset, :transferred_on)
    cost_object_id = Ash.Changeset.get_argument(changeset, :cost_object_id)
    dimension_key = Ash.Changeset.get_argument(changeset, :dimension_key)

    cond do
      asset.status == :disposed ->
        add_error(changeset, :base, "a disposed asset cannot be transferred")

      is_nil(on) ->
        add_error(changeset, :transferred_on, "a transfer must be dated")

      Date.compare(on, asset.acquired_on) == :lt ->
        add_error(
          changeset,
          :transferred_on,
          "the transfer date (#{Date.to_iso8601(on)}) is before the acquisition " <>
            "(#{Date.to_iso8601(asset.acquired_on)})"
        )

      is_nil(cost_object_id) or is_nil(dimension_key) ->
        add_error(changeset, :cost_object_id, "a transfer must name the target cost object")

      asset.cost_object_id == cost_object_id and asset.dimension_key == dimension_key ->
        add_error(changeset, :cost_object_id, "the asset is already assigned to that cost object")

      true ->
        case ensure_no_ledger_history(asset, posting_mod) do
          :ok ->
            record = %{
              "transferred_on" => Date.to_iso8601(on),
              "from_cost_object_id" => asset.cost_object_id,
              "from_dimension_key" => to_string(asset.dimension_key),
              "to_cost_object_id" => cost_object_id,
              "to_dimension_key" => to_string(dimension_key)
            }

            changeset
            |> Ash.Changeset.force_change_attribute(
              :transfer_history,
              (asset.transfer_history || []) ++ [record]
            )
            |> Ash.Changeset.force_change_attribute(:cost_object_id, cost_object_id)
            |> Ash.Changeset.force_change_attribute(:dimension_key, dimension_key)

          {:error, {:postings_unreadable, reason}} ->
            add_error(
              changeset,
              :base,
              "the asset's postings cannot be checked before transfer: #{inspect(reason)}"
            )

          {:error, history} ->
            add_error(
              changeset,
              :base,
              "asset #{asset.code} already has #{history}; a transfer only moves future " <>
                "depreciation, but the cost and accumulated already posted cannot be " <>
                "reclassified between cost objects (R6). A later disposal would clear only " <>
                "the current dimension and leave the old balances behind. Transfer the " <>
                "asset before it is placed in service or depreciated."
            )
        end
    end
  end

  defp ensure_no_ledger_history(%{in_service_entry_id: entry_id}, _posting_mod)
       when not is_nil(entry_id),
       do: {:error, "an in-service reclassification entry"}

  defp ensure_no_ledger_history(asset, posting_mod) do
    case posting_mod
         |> Ash.Query.filter(org_id == ^asset.org_id and asset_id == ^asset.id)
         |> Ash.Query.limit(1)
         |> Ash.read(authorize?: false) do
      {:ok, []} -> :ok
      {:ok, [_posting]} -> {:error, "depreciation postings"}
      {:error, reason} -> {:error, {:postings_unreadable, reason}}
    end
  end

  defp load_asset(asset_mod, id) do
    case asset_mod
         |> Ash.Query.filter(id == ^id)
         |> Ash.Query.ensure_selected([:org_id])
         |> Ash.read_one(authorize?: false) do
      {:ok, nil} -> {:error, :asset_not_found}
      {:ok, asset} -> {:ok, asset}
      {:error, reason} -> {:error, reason}
    end
  end

  defp add_error(changeset, field, message),
    do: Ash.Changeset.add_error(changeset, field: field, message: message)
end

defmodule Samen.Scopes.Finance.AssetInService do
  @moduledoc """
  The CIP-to-in-service transfer (WS-ACCT Phase 8; ADR-054 D9).

  A construction-in-progress asset does not depreciate. `:place_in_service`
  records the date, reclassifies the accumulated cost from
  `construction_in_progress` to the asset-kind cost account, and only then
  starts the derived schedule. The reclassification is anchored
  `source_key: "asset_in_service"`, `source_id: <asset id>`.
  """

  require Ash.Query

  use Ash.Resource.Change

  @source_key "asset_in_service"

  @doc "The object-ref anchor every in-service entry carries."
  def source_key, do: @source_key

  @impl true
  def change(changeset, opts, _context) do
    asset_mod = Keyword.fetch!(opts, :asset)
    entry_mod = Keyword.fetch!(opts, :entry)
    pa_mod = Keyword.fetch!(opts, :posting_account)

    Ash.Changeset.before_action(changeset, fn changeset ->
      place_in_service(changeset, asset_mod, entry_mod, pa_mod)
    end)
  end

  defp place_in_service(changeset, asset_mod, entry_mod, pa_mod) do
    with {:ok, asset} <- load_asset(asset_mod, changeset.data.id) do
      do_place_in_service(changeset, asset, entry_mod, pa_mod)
    else
      {:error, reason} ->
        add_error(changeset, :base, "the asset cannot be loaded: #{format(reason)}")
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

  defp do_place_in_service(changeset, asset, entry_mod, pa_mod) do
    on = Ash.Changeset.get_argument(changeset, :in_service_on)

    cond do
      asset.status == :disposed ->
        add_error(changeset, :base, "a disposed asset cannot be placed in service")

      asset.status != :under_construction ->
        add_error(changeset, :base, "asset #{asset.code} is already in service")

      is_nil(on) ->
        add_error(changeset, :in_service_on, "an in-service date is required")

      Date.compare(on, asset.acquired_on) == :lt ->
        add_error(
          changeset,
          :in_service_on,
          "the in-service date (#{Date.to_iso8601(on)}) is before the acquisition " <>
            "(#{Date.to_iso8601(asset.acquired_on)})"
        )

      true ->
        post_entry(changeset, asset, on, entry_mod, pa_mod)
    end
  end

  defp post_entry(changeset, asset, on, entry_mod, pa_mod) do
    with {:ok, cost} <-
           Samen.Scopes.Finance.AssetEntry.posting_account(
             pa_mod,
             asset.org_id,
             cost_key(asset.kind)
           ),
         {:ok, cip} <-
           Samen.Scopes.Finance.AssetEntry.posting_account(
             pa_mod,
             asset.org_id,
             :construction_in_progress
           ),
         {:ok, entry} <-
           Samen.Scopes.Finance.AssetEntry.post(entry_mod, %{
             org_id: asset.org_id,
             entry_date: on,
             memo: "In service #{asset.code}",
             source_key: @source_key,
             source_id: asset.id,
             lines: [
               %{
                 account_id: cost.account_id,
                 debit_cents: asset.cost_cents,
                 dimension_refs: Samen.Scopes.Finance.AssetEntry.dimension_refs(asset)
               },
               %{
                 account_id: cip.account_id,
                 credit_cents: asset.cost_cents,
                 dimension_refs: Samen.Scopes.Finance.AssetEntry.dimension_refs(asset)
               }
             ]
           }) do
      changeset
      |> Ash.Changeset.force_change_attribute(:status, :active)
      |> Ash.Changeset.force_change_attribute(:in_service_on, on)
      |> Ash.Changeset.force_change_attribute(:in_service_entry_id, entry.id)
    else
      {:error, reason} ->
        add_error(
          changeset,
          :base,
          "the asset cannot be placed in service: #{format(reason)}"
        )
    end
  end

  defp cost_key(:intangible), do: :asset_cost_intangible
  defp cost_key(:equipment), do: :asset_cost_equipment

  defp add_error(changeset, field, message),
    do: Ash.Changeset.add_error(changeset, field: field, message: message)

  defp format({:unmapped_posting_account, key}),
    do:
      "no PostingAccount row maps `#{key}` for this org (fail-honest — accounts are a " <>
        "host decision; seed the org's posting accounts first)"

  defp format({:asset_not_found, id}), do: "asset #{id} was not found"
  defp format(%{__exception__: true} = error), do: Exception.message(error)
  defp format(reason), do: inspect(reason)
end
