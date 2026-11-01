defmodule Samenerp.KubeworkzReserveTest do
  @moduledoc """
  WS-ACCT Phase 9 (ADR-054 D10) on the real host: the seeded books carry the
  manual's own obsolescence rule ("chips older than 18 months with no expected
  sales are written down to NRV"), an assessment drafts the write-down, and a
  distinct approver clears it through the ADR-040 Gate.

  The reproduced entry is JE-062's shape: one debit to `8000`, one credit per
  finished-goods account (`1400` RISC-V64 SoC, `1410` GPU). The figures are the
  manual's placeholders; what the test pins is the MECHANISM — age eligibility,
  the Gate, and the two-legged posting.
  """
  use Samenerp.DataCase, async: false

  require Ash.Query

  alias Samenerp.Erp
  alias Samenerp.Kubeworkz.Books
  alias Samenerp.Operator, as: Op

  defp create_org!(name) do
    Op.Org
    |> Ash.Changeset.for_create(:create, %{name: name}, authorize?: false)
    |> Ash.create!(authorize?: false)
  end

  defp member_scope(org) do
    %Samen.Scope{
      actor: %{id: "u:#{org}", org_id: org, role: :member, kind: :tenant, plane: :tenant}
    }
  end

  defp admin_scope(org) do
    %Samen.Scope{
      actor: %{id: "a:#{org}", org_id: org, role: :admin, kind: :tenant, plane: :tenant}
    }
  end

  defp account!(org, code) do
    Erp.Account
    |> Ash.Query.filter(org_id == ^org and code == ^code)
    |> Ash.read_one!(authorize?: false)
  end

  defp item!(admin, org, sku, name, inventory_account) do
    Erp.Item
    |> Ash.Changeset.for_create(
      :create,
      %{
        org_id: org,
        sku: sku,
        name: name,
        kind: :stocked,
        default_inventory_account_id: inventory_account.id
      },
      scope: admin
    )
    |> Ash.create!()
  end

  defp warehouse!(admin, org) do
    Erp.Warehouse
    |> Ash.Changeset.for_create(
      :create,
      %{org_id: org, code: "WH-KUB", name: "Kubeworkz Finished Goods"},
      scope: admin
    )
    |> Ash.create!()
  end

  defp stock!(org, item, warehouse, qty, unit_cost_cents) do
    Erp.StockLedger
    |> Ash.Changeset.for_create(
      :record,
      %{
        org_id: org,
        kind: :receipt,
        qty: qty,
        unit_cost_cents: unit_cost_cents,
        item_id: item.id,
        warehouse_id: warehouse.id
      },
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end

  defp gate(record, scope) do
    case record
         |> Ash.Changeset.for_update(:post, %{}, scope: scope)
         |> Ash.update() do
      {:error, %Ash.Error.Forbidden{errors: errors}} ->
        case Enum.find(errors, &match?(%{__struct__: Samen.Approvals.ApprovalRequired}, &1)) do
          nil -> flunk("expected ApprovalRequired, got: #{inspect(errors)}")
          found -> {:gated, found.approval_id}
        end

      {:ok, _} ->
        flunk("the :post action succeeded WITHOUT the Gate")

      {:error, other} ->
        flunk("unexpected :post failure: #{inspect(other)}")
    end
  end

  test "the seeded 18-month rule reproduces JE-062 through the Gate" do
    org = create_org!("Kubeworkz Obsolescence")
    admin = admin_scope(org.id)
    member = member_scope(org.id)

    summary = Books.seed!(org.id)

    # The seed opens the manual's rule, idempotently, and verify() sees it.
    assert summary.reserve_policies.created == 1
    assert Books.seed!(org.id).reserve_policies.created == 0
    assert {:ok, %{reserve_policies: 1}} = Books.verify(org.id)

    [spec] = Books.reserve_policies()
    assert spec.basis == :age
    assert spec.age_months == 18
    assert spec.pct == 100

    policy =
      Erp.InventoryReserve
      |> Ash.Query.filter(org_id == ^org.id and name == ^spec.name)
      |> Ash.read_one!(authorize?: false)

    soc_account = account!(org.id, "1400")
    gpu_account = account!(org.id, "1410")
    write_down = account!(org.id, "8000")

    warehouse = warehouse!(admin, org.id)

    # JE-062's two lines: 1 000 units of SoC at 1.00 and 1 000 of GPU at 1.50.
    soc = item!(admin, org.id, "SOC-JE062", "RISC-V64 SoC", soc_account)
    gpu = item!(admin, org.id, "GPU-JE062", "GPU", gpu_account)

    _ = stock!(org.id, soc, warehouse, 1_000, 100)
    _ = stock!(org.id, gpu, warehouse, 1_000, 150)

    # A 2028 review date: today's receipts are older than the 18-month cut.
    assert {:ok, draft} =
             Erp.ReserveWriteDown
             |> Ash.Changeset.for_create(
               :draft,
               %{org_id: org.id, policy_id: policy.id, assessed_on: ~D[2028-06-01]},
               scope: member
             )
             |> Ash.create()

    assert draft.status == :draft
    assert draft.amount_cents == 250_000

    # Drafting posts NOTHING.
    assert entries(org.id) == []

    assert {:gated, approval_id} = gate(draft, member)

    assert {:ok, _approved, %{executed: "post"}} =
             Samen.Approvals.approve(approval_id, "a2:reserve-decider")

    posted = Ash.get!(Erp.ReserveWriteDown, draft.id, authorize?: false)
    assert posted.status == :posted

    [entry] = entries(org.id)
    assert entry.status == :posted
    assert entry.source_key == "reserve_write_down"

    legs =
      Erp.JournalLine
      |> Ash.Query.filter(org_id == ^org.id and entry_id == ^entry.id)
      |> Ash.read!(authorize?: false)
      |> Enum.map(&{&1.account_id, &1.debit_cents, &1.credit_cents})
      |> Enum.sort()

    assert legs ==
             Enum.sort([
               {write_down.id, 250_000, 0},
               {soc_account.id, 0, 100_000},
               {gpu_account.id, 0, 150_000}
             ])

    # A second review has nothing left to propose: the value is already expensed.
    assert {:error, %Ash.Error.Invalid{} = err} =
             Erp.ReserveWriteDown
             |> Ash.Changeset.for_create(
               :draft,
               %{org_id: org.id, policy_id: policy.id, assessed_on: ~D[2028-06-01]},
               scope: member
             )
             |> Ash.create()

    assert Exception.message(err) =~ "nothing to draft"
  end

  defp entries(org) do
    Erp.JournalEntry
    |> Ash.Query.filter(org_id == ^org and source_key == "reserve_write_down")
    |> Ash.read!(authorize?: false)
  end
end
