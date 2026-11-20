defmodule Samenerp.Kubeworkz.ItemInventoryAccounts do
  @moduledoc """
  Host-side audit and backfill for the item seam the B0 COGS leg requires.

  `FulfillOrder` refuses an item without `default_inventory_account_id` before
  it writes stock or an invoice. Existing host items may predate that
  requirement, so this module provides the safe repair path:

    * `audit/1` is READ-ONLY and returns every item in the org whose link is
      nil (ordered by SKU), so an operator can review the population first;
    * `audit_all/0` sweeps every tenant org in this host (plus the operator
      org), so the pre-deployment check does not depend on remembering which
      orgs have inventory;
    * `backfill!/2` takes an EXPLICIT `%{item_id => account_id}` assignment
      map. There is deliberately no default account: Kubeworkz has several
      inventory accounts (WIP, chip and board finished goods), and guessing one
      would silently misstate the inventory credit;
    * only nil links are filled. An item already linked to a different
      account is reported as a conflict and left untouched;
    * every account must belong to the same org and be an asset debit account,
      and every item must belong to that org. Validation happens before the
      write loop, and the writes run in one transaction.

  Run `audit/1`, prepare the assignments, then run `backfill!/2` before
  deploying/enabling the COGS refusal. The operation is idempotent: replaying
  the same assignments reports `already_linked` and writes nothing.
  """

  require Ash.Query

  alias Samenerp.Erp.{Account, Item}
  alias Samenerp.Repo

  @doc """
  Return the org's items whose `default_inventory_account_id` is nil.

  This is the audit half: it never writes and never guesses an account. The
  caller reviews the returned item rows and decides the account for each one.
  """
  @spec audit(String.t()) :: [struct()]
  def audit(org_id) do
    Item
    |> Ash.Query.filter(org_id == ^org_id and is_nil(default_inventory_account_id))
    |> Ash.Query.sort(sku: :asc)
    |> Ash.read!(authorize?: false)
  end

  @doc """
  Sweep every host org for unlinked items. Read-only; use the returned rows to
  prepare the per-org assignment maps for `backfill!/2`.
  """
  @spec audit_all() :: [struct()]
  def audit_all do
    [Samenerp.Seeds.operator_org_id() | Enum.map(Samenerp.Directory.orgs(), &elem(&1, 0))]
    |> Enum.uniq()
    |> Enum.flat_map(&audit/1)
  end

  @doc """
  Fill nil inventory-account links from an explicit `%{item_id => account_id}`
  assignment map.

  Returns `%{linked: n, already_linked: n, conflicts: [...]}`. Conflicts are
  `%{item_id, current_account_id, requested_account_id}`; they are reported,
  never overwritten.
  """
  @spec backfill!(String.t(), map()) :: %{
          linked: non_neg_integer(),
          already_linked: non_neg_integer(),
          conflicts: [map()]
        }
  def backfill!(org_id, assignments) when is_map(assignments) do
    assignments =
      Map.new(assignments, fn {item_id, account_id} ->
        {to_string(item_id), to_string(account_id)}
      end)

    items = load_items!(org_id, Map.keys(assignments))
    accounts = load_accounts!(org_id, assignments |> Map.values() |> Enum.uniq())

    validate_accounts!(accounts)

    {:ok, result} =
      Repo.transaction(fn ->
        Enum.reduce(items, %{linked: 0, already_linked: 0, conflicts: []}, fn item, acc ->
          account_id = Map.fetch!(assignments, item.id)

          case item.default_inventory_account_id do
            nil ->
              update_item!(item, account_id)
              %{acc | linked: acc.linked + 1}

            ^account_id ->
              %{acc | already_linked: acc.already_linked + 1}

            current_account_id ->
              conflict = %{
                item_id: item.id,
                current_account_id: current_account_id,
                requested_account_id: account_id
              }

              %{acc | conflicts: acc.conflicts ++ [conflict]}
          end
        end)
      end)

    result
  end

  defp load_items!(_org_id, []), do: []

  defp load_items!(org_id, item_ids) do
    items =
      Item
      |> Ash.Query.filter(org_id == ^org_id and id in ^item_ids)
      |> Ash.read!(authorize?: false)

    ensure_complete!(items, item_ids, "items not found in org #{org_id}")
    items
  end

  defp load_accounts!(_org_id, []), do: []

  defp load_accounts!(org_id, account_ids) do
    accounts =
      Account
      |> Ash.Query.filter(org_id == ^org_id and id in ^account_ids)
      |> Ash.read!(authorize?: false)

    ensure_complete!(accounts, account_ids, "accounts not found in org #{org_id}")
    accounts
  end

  defp ensure_complete!(rows, ids, label) do
    found = MapSet.new(rows, & &1.id)
    missing = Enum.reject(ids, &MapSet.member?(found, &1))

    if missing != [] do
      raise ArgumentError, "#{label}: #{Enum.join(missing, ", ")}"
    end
  end

  defp validate_accounts!(accounts) do
    invalid =
      Enum.reject(accounts, fn account ->
        account.kind == :asset and account.normal_side == :debit
      end)

    if invalid != [] do
      raise ArgumentError,
            "inventory accounts must be asset debit accounts; refused: " <>
              Enum.map_join(invalid, ", ", &"#{&1.code} (#{&1.kind}/#{&1.normal_side})")
    end
  end

  defp update_item!(item, account_id) do
    item
    |> Ash.Changeset.for_update(
      :update,
      %{default_inventory_account_id: account_id},
      authorize?: false
    )
    |> Ash.update!(authorize?: false)
  end
end
