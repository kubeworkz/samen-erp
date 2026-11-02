defmodule Samenerp.KubeworkzAllocationTest do
  @moduledoc """
  WS-ACCT Phase 10 (ADR-054 decision 11) on the real host: one MPW mask
  invoice — the manual's policy §3.3, "allocate the cost of a single shuttle
  across the chip designs that shared it" — is split across the three
  programme cost objects by die-area share, and posts as ONE dimensioned
  entry, never one reclass per design.

  The figures are deliberately awkward: 120 000.01 split 52/31/17 floors to
  6 240 000 + 3 720 000 + 2 040 000, leaving one cent that must land on the
  52% programme. A naive per-share rounding loses or invents that cent; the
  allocation step's red path is exactly this.
  """
  use Samenerp.DataCase, async: false

  require Ash.Query

  alias Samen.Scopes.Finance.DimensionReconcile
  alias Samenerp.Erp
  alias Samenerp.Kubeworkz.Books
  alias Samenerp.Operator, as: Op

  @mask_cents 12_000_001

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

  defp account!(org, code) do
    Erp.Account
    |> Ash.Query.filter(org_id == ^org and code == ^code)
    |> Ash.read_one!(authorize?: false)
  end

  defp cost_object!(org, code) do
    Erp.CostObject
    |> Ash.Query.filter(org_id == ^org and code == ^code)
    |> Ash.read_one!(authorize?: false)
  end

  defp new_bill(scope, org, mask_account, amount_cents) do
    Erp.ApInvoice
    |> Ash.Changeset.for_create(
      :create,
      %{
        org_id: org,
        vendor_id: Ash.UUID.generate(),
        number: "MPW-MASK-" <> binary_part(Ash.UUID.generate(), 0, 6),
        bill_date: ~D[2026-09-15],
        memo: "MPW mask set — shared shuttle",
        lines: [%{account_id: mask_account.id, amount_cents: amount_cents, memo: "Mask set"}]
      },
      scope: scope
    )
    |> Ash.create!(scope: scope)
  end

  defp gate(bill, scope) do
    case bill
         |> Ash.Changeset.for_update(:approve, %{}, scope: scope)
         |> Ash.update() do
      {:error, %Ash.Error.Forbidden{errors: errors}} ->
        case Enum.find(errors, &match?(%{__struct__: Samen.Approvals.ApprovalRequired}, &1)) do
          nil -> flunk("expected ApprovalRequired, got: #{inspect(errors)}")
          found -> {:gated, found.approval_id}
        end

      {:ok, _} ->
        flunk("the :approve action succeeded WITHOUT the Gate")

      {:error, other} ->
        flunk("unexpected :approve failure: #{inspect(other)}")
    end
  end

  defp draft(member, org, bill, wip, shares) do
    Erp.CostAllocation
    |> Ash.Changeset.for_create(
      :draft,
      %{
        org_id: org,
        ap_invoice_id: bill.id,
        basis: :die_area,
        allocated_on: ~D[2026-09-30],
        target_account_id: wip.id,
        shares: shares
      },
      scope: member
    )
    |> Ash.create()
  end

  defp shares(org, allocation_id) do
    Erp.CostAllocationShare
    |> Ash.Query.filter(org_id == ^org and cost_allocation_id == ^allocation_id)
    |> Ash.Query.sort(cost_object_id: :asc)
    |> Ash.read!(authorize?: false)
  end

  defp lines(org, entry_id) do
    Erp.JournalLine
    |> Ash.Query.filter(org_id == ^org and entry_id == ^entry_id)
    |> Ash.read!(authorize?: false)
  end

  test "the MPW mask invoice splits across RISC-V64/GPU/PTA and posts one entry" do
    org = create_org!("Kubeworkz MPW Allocation")
    member = member_scope(org.id)

    assert %{cost_objects: %{created: 9}} = Books.seed!(org.id)

    mask = account!(org.id, "6000")
    wip = account!(org.id, "1300")

    riscv64 = cost_object!(org.id, "riscv64-soc")
    gpu = cost_object!(org.id, "gpu")
    pta = cost_object!(org.id, "pta")

    bill = new_bill(member, org.id, mask, @mask_cents)

    # The AP bill posts first — the allocation moves cost that is already on
    # the books, never cost a draft claims.
    assert {:gated, approval_id} = gate(bill, member)

    assert {:ok, _approved, _meta} =
             Samen.Approvals.approve(approval_id, "a2:#{org.id}",
               approval_resource: Samenerp.Approvals.Approval,
               repo: Samenerp.Repo
             )

    bill = Ash.get!(Erp.ApInvoice, bill.id, authorize?: false)
    assert bill.status == :approved

    # The manual's stated basis: die-area share of the shared shuttle.
    assert {:ok, header} =
             draft(member, org.id, bill, wip, [
               %{cost_object_id: riscv64.id, driver: 52},
               %{cost_object_id: gpu.id, driver: 31},
               %{cost_object_id: pta.id, driver: 17}
             ])

    assert header.status == :draft
    assert header.amount_cents == @mask_cents

    # Drafting posts NOTHING: the only entry so far is the AP bill's own.
    assert [%{source_key: "ap_invoice"}] = all_entries(org.id)

    rows = shares(org.id, header.id)

    assert Map.new(rows, &{&1.cost_object_id, &1.allocated_cents}) == %{
             riscv64.id => 6_240_001,
             gpu.id => 3_720_000,
             pta.id => 2_040_000
           }

    assert Enum.reduce(rows, 0, &(&1.allocated_cents + &2)) == @mask_cents

    assert {:ok, posted} =
             header
             |> Ash.Changeset.for_update(:post, %{}, scope: member)
             |> Ash.update()

    assert posted.status == :posted

    # ONE entry, six legs — not three small reclasses.
    allocation_entries = entries(org.id)
    assert [entry] = allocation_entries
    assert entry.id == posted.entry_id
    assert entry.source_key == "cost_allocation"

    entry_lines = lines(org.id, entry.id)
    assert length(entry_lines) == 6

    by_programme = Enum.group_by(entry_lines, & &1.dimension_refs["project"])

    for {programme, cents} <- %{
          riscv64.id => 6_240_001,
          gpu.id => 3_720_000,
          pta.id => 2_040_000
        } do
      assert Enum.sort(Enum.map(by_programme[programme], &{&1.account_id, &1.debit_cents, &1.credit_cents})) ==
               Enum.sort([{wip.id, cents, 0}, {mask.id, 0, cents}])
    end

    # R1/R6 hold with the real host's line resource.
    assert {:ok, true} =
             DimensionReconcile.balanced?(org.id, Samenerp.Repo, line_resource: Erp.JournalLine)
  end

  defp all_entries(org) do
    Erp.JournalEntry
    |> Ash.Query.filter(org_id == ^org)
    |> Ash.read!(authorize?: false)
  end

  defp entries(org) do
    Erp.JournalEntry
    |> Ash.Query.filter(org_id == ^org and source_key == "cost_allocation")
    |> Ash.read!(authorize?: false)
  end
end
