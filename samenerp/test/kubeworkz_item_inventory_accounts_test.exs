defmodule Samenerp.KubeworkzItemInventoryAccountsTest do
  @moduledoc """
  B0 host repair: existing items that predate the COGS requirement are found
  read-only, then linked only from an explicit per-item assignment map. No
  blanket default is inferred, existing links are never overwritten, and the
  writes are validated and transactional.
  """

  use Samenerp.DataCase, async: false

  require Ash.Query

  alias Samenerp.Erp.{Account, Item}
  alias Samenerp.Kubeworkz.{Books, ItemInventoryAccounts}
  alias Samenerp.Operator, as: Op

  setup do
    org =
      Op.Org
      |> Ash.Changeset.for_create(:create, %{name: "Kubeworkz Item Account Backfill"},
        authorize?: false
      )
      |> Ash.create!(authorize?: false)

    Books.seed!(org.id)
    {:ok, org: org.id}
  end

  test "audit finds unlinked items and backfill links explicit assignments", %{org: org} do
    board = account!(org, "1430")
    chip = account!(org, "1400")

    linked = item!(org, "A-LINKED", board.id)
    missing_board = item!(org, "B-PDB")
    missing_chip = item!(org, "C-CHIP")

    foreign_org = Ash.UUID.generate()
    foreign_item = item!(foreign_org, "FOREIGN")

    assert Enum.map(ItemInventoryAccounts.audit(org), & &1.id) ==
             [missing_board.id, missing_chip.id]

    audit_all_ids = Enum.map(ItemInventoryAccounts.audit_all(), & &1.id)
    assert missing_board.id in audit_all_ids
    assert missing_chip.id in audit_all_ids
    refute Enum.any?(ItemInventoryAccounts.audit(org), &(&1.id == linked.id))
    assert Enum.map(ItemInventoryAccounts.audit(foreign_org), & &1.id) == [foreign_item.id]

    result =
      ItemInventoryAccounts.backfill!(org, %{
        missing_board.id => board.id,
        missing_chip.id => chip.id
      })

    assert result == %{linked: 2, already_linked: 0, conflicts: []}
    assert reload!(missing_board).default_inventory_account_id == board.id
    assert reload!(missing_chip).default_inventory_account_id == chip.id
    assert reload!(linked).default_inventory_account_id == board.id
    assert reload!(foreign_item).default_inventory_account_id == nil
    assert ItemInventoryAccounts.audit(org) == []

    # A replay is a no-op, and a different requested account is reported
    # rather than overwriting the operator's existing link.
    assert ItemInventoryAccounts.backfill!(org, %{missing_board.id => board.id}) ==
             %{linked: 0, already_linked: 1, conflicts: []}

    assert %{linked: 0, already_linked: 0, conflicts: [conflict]} =
             ItemInventoryAccounts.backfill!(org, %{linked.id => chip.id})

    assert conflict == %{
             item_id: linked.id,
             current_account_id: board.id,
             requested_account_id: chip.id
           }

    assert reload!(linked).default_inventory_account_id == board.id
  end

  test "unsafe assignments are refused before any write", %{org: org} do
    board = account!(org, "1430")
    cogs = account!(org, "5000")
    item = item!(org, "D-NEW")

    foreign_org = Ash.UUID.generate()
    Books.seed!(foreign_org)
    foreign_account = account!(foreign_org, "1430")
    foreign_item = item!(foreign_org, "FOREIGN-BACKFILL")

    assert_raise ArgumentError, ~r/asset debit/, fn ->
      ItemInventoryAccounts.backfill!(org, %{item.id => cogs.id})
    end

    assert reload!(item).default_inventory_account_id == nil

    assert_raise ArgumentError, ~r/items not found in org/, fn ->
      ItemInventoryAccounts.backfill!(org, %{foreign_item.id => board.id})
    end

    assert_raise ArgumentError, ~r/accounts not found in org/, fn ->
      ItemInventoryAccounts.backfill!(org, %{item.id => foreign_account.id})
    end

    assert reload!(item).default_inventory_account_id == nil
    assert reload!(foreign_item).default_inventory_account_id == nil
  end

  defp item!(org, sku, inventory_account_id \\ nil) do
    Item
    |> Ash.Changeset.for_create(
      :create,
      %{
        org_id: org,
        sku: sku,
        name: sku,
        kind: :stocked,
        uom: :unit,
        default_inventory_account_id: inventory_account_id
      },
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end

  defp account!(org, code) do
    Account
    |> Ash.Query.filter(org_id == ^org and code == ^code)
    |> Ash.read_one!(authorize?: false)
  end

  defp reload!(item), do: Ash.get!(Item, item.id, authorize?: false)
end
