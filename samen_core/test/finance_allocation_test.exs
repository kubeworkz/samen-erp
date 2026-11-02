defmodule Samen.FinanceAllocationTest do
  @moduledoc """
  WS-ACCT Phase 10 (ADR-054 decision 11) — the reusable allocation step,
  mounted via `test/support/finance_fixture.ex`.

  Every refusal is paired with a positive control (`Samen.RedPath` discipline):

    * a1 the arithmetic — largest remainder follows the drivers and the shares
      sum to the amount EXACTLY (the phase's red path: no lost or invented
      cent); a single target, a duplicate target and a non-positive driver are
      refused;
    * a2 drafting — the amount is derived from the bill's own line, nothing
      posts, a draft/unposted bill is refused, and one bill+account can be
      allocated once;
    * a3 the one entry — N cost objects land as ONE post, each with a
      debit/credit pair tagged to that cost object (R6), never N posts;
    * a4 R10 — a closed period refuses the post and leaves the draft alone;
    * a5 the state machine — a posted allocation cannot be re-posted;
    * a6 fail-honest — a zero-cent share, a same-account pair and a foreign
      bill/cost object are refused;
    * a7 DB belts — shares are append-only, a posted header is final.
  """
  use ExUnit.Case, async: false

  require Ash.Query

  alias Samen.Scopes.Finance.AllocationMath
  alias Samen.Scopes.Finance.DimensionReconcile
  alias Samen.Scopes.Finance.Reconcile

  alias SamenCore.Support.FinanceFixture.{
    Account,
    ApInvoice,
    CostAllocation,
    CostAllocationShare,
    CostObject,
    FiscalPeriod,
    JournalEntry,
    JournalLine,
    PostingAccount
  }

  @repo SamenCore.TestRepo
  @approval_resource SamenCore.Support.ApprovalsFixture.Approval

  # 120 000.01 in cents, split 52/31/17: the floors sum to 12 000 000, so the
  # last cent must go to the 52% target (remainder 52) — exactly the manual's
  # die-area shape, and a split a naive round/1 would get wrong.
  @mask_cents 12_000_001

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(@repo)
    org = Ash.UUID.generate()

    {:ok, org: org, admin: admin_scope(org), tenant: tenant_scope(org)}
  end

  # ── a1: the arithmetic ─────────────────────────────────────────────────────

  describe "a1 — the arithmetic" do
    test "the shares follow the declared drivers and sum to the amount exactly" do
      shares = [
        %{cost_object_id: "a", driver: 52},
        %{cost_object_id: "b", driver: 31},
        %{cost_object_id: "c", driver: 17}
      ]

      assert {:ok, split} = AllocationMath.allocate(@mask_cents, shares)

      assert Enum.map(split, & &1.allocated_cents) == [6_240_001, 3_720_000, 2_040_000]
      assert Enum.reduce(split, 0, &(&1.allocated_cents + &2)) == @mask_cents
    end

    test "largest remainder cannot lose or invent a cent (the red path)" do
      # 100 across three equal drivers: 33/33/33 would lose a cent; 34/33/33
      # does not, and the id tie-break makes WHICH target gets it stable.
      assert {:ok, even} =
               AllocationMath.allocate(100, [
                 %{cost_object_id: "a", driver: 1},
                 %{cost_object_id: "b", driver: 1},
                 %{cost_object_id: "c", driver: 1}
               ])

      assert Enum.map(even, & &1.allocated_cents) == [34, 33, 33]
      assert Enum.reduce(even, 0, &(&1.allocated_cents + &2)) == 100

      # A clean proportional split is untouched by the remainder step.
      assert {:ok, clean} =
               AllocationMath.allocate(1_000, [
                 %{cost_object_id: "a", driver: 50},
                 %{cost_object_id: "b", driver: 30},
                 %{cost_object_id: "c", driver: 20}
               ])

      assert Enum.map(clean, & &1.allocated_cents) == [500, 300, 200]

      # A one-cent shortfall lands on the larger remainder, not arbitrarily.
      assert {:ok, tiny} =
               AllocationMath.allocate(10, [
                 %{cost_object_id: "a", driver: 1},
                 %{cost_object_id: "b", driver: 1},
                 %{cost_object_id: "c", driver: 1}
               ])

      assert Enum.map(tiny, & &1.allocated_cents) == [4, 3, 3]
    end

    test "a single target, a duplicate target and a non-positive driver are refused" do
      one = [%{cost_object_id: "a", driver: 1}]
      assert {:error, :too_few_shares} = AllocationMath.allocate(100, one)

      duplicated = [
        %{cost_object_id: "a", driver: 1},
        %{cost_object_id: "a", driver: 2}
      ]

      assert {:error, :duplicate_cost_object} = AllocationMath.allocate(100, duplicated)

      zero = [
        %{cost_object_id: "a", driver: 0},
        %{cost_object_id: "b", driver: 1}
      ]

      assert {:error, :invalid_driver} = AllocationMath.allocate(100, zero)

      negative = [
        %{cost_object_id: "a", driver: -1},
        %{cost_object_id: "b", driver: 1}
      ]

      assert {:error, :invalid_driver} = AllocationMath.allocate(100, negative)
      assert {:error, :invalid_amount} = AllocationMath.allocate(0, duplicated)
    end
  end

  # ── a2: drafting ───────────────────────────────────────────────────────────

  describe "a2 — drafting is a proposal, never a posting" do
    test "drafting derives the bill's amount and posts NOTHING", %{
      org: org,
      admin: admin,
      tenant: tenant
    } do
      ctx = books!(admin, org)
      bill = approved_mask_bill!(tenant, org, ctx.mask)

      assert {:ok, draft} =
               draft(tenant, org, bill, ctx.wip, [
                 share(ctx.riscv64, 52),
                 share(ctx.gpu, 31),
                 share(ctx.pta, 17)
               ])

      assert draft.status == :draft
      assert draft.amount_cents == @mask_cents
      assert draft.source_account_id == ctx.mask.id
      assert draft.entry_id == nil
      assert draft.posted_at == nil

      shares = shares(org, draft.id)

      assert Map.new(shares, &{&1.cost_object_id, {&1.driver, &1.allocated_cents}}) == %{
               ctx.riscv64.id => {52, 6_240_001},
               ctx.gpu.id => {31, 3_720_000},
               ctx.pta.id => {17, 2_040_000}
             }

      # NOTHING hit the GL: the sole entry is the AP bill's own posting.
      assert [%{source_key: "ap_invoice"}] = all_entries(org)
      assert entries(org) == []
    end

    test "a bill must have posted before its cost can be allocated", %{
      org: org,
      admin: admin,
      tenant: tenant
    } do
      ctx = books!(admin, org)

      draft_bill =
        new_bill(tenant, org, [%{account_id: ctx.mask.id, amount_cents: 500}])

      assert {:error, %Ash.Error.Invalid{} = err} =
               draft(tenant, org, draft_bill, ctx.wip, [
                 share(ctx.riscv64, 1),
                 share(ctx.gpu, 1)
               ])

      assert Exception.message(err) =~ "still a draft"
      assert CostAllocation |> Ash.read!(authorize?: false) == []
    end

    test "one allocation per bill and source account (a second draft is refused)", %{
      org: org,
      admin: admin,
      tenant: tenant
    } do
      ctx = books!(admin, org)
      bill = approved_mask_bill!(tenant, org, ctx.mask)
      shares = [share(ctx.riscv64, 1), share(ctx.gpu, 1)]

      assert {:ok, _draft} = draft(tenant, org, bill, ctx.wip, shares)

      assert {:error, %Ash.Error.Invalid{} = err} =
               draft(tenant, org, bill, ctx.wip, shares)

      assert Exception.message(err) =~ "already allocated"
      assert length(all_allocations(org)) == 1
    end
  end

  # ── a3: the one entry ──────────────────────────────────────────────────────

  describe "a3 — the allocation is ONE dimensioned entry" do
    test "N cost objects post as one entry, never N posts", %{
      org: org,
      admin: admin,
      tenant: tenant
    } do
      ctx = books!(admin, org)
      bill = approved_mask_bill!(tenant, org, ctx.mask)

      {:ok, header} =
        draft(tenant, org, bill, ctx.wip, [
          share(ctx.riscv64, 52),
          share(ctx.gpu, 31),
          share(ctx.pta, 17)
        ])

      assert {:ok, posted} = post(header, tenant)
      assert posted.status == :posted
      assert posted.entry_id != nil
      assert posted.posted_at != nil

      [entry] = entries(org)
      assert entry.id == posted.entry_id
      assert entry.status == :posted
      assert entry.source_key == "cost_allocation"
      assert entry.source_id == posted.id
      assert entry.entry_date == posted.allocated_on

      lines = entry_lines(org, entry.id)
      assert length(lines) == 6

      # Every line carries the SAME axis, tagged to one of the three targets.
      assert Enum.all?(lines, &(Map.keys(&1.dimension_refs) == ["project"]))
      assert lines |> Enum.map(& &1.dimension_refs["project"]) |> Enum.uniq() |> length() == 3

      # Per target: one debit to WIP, one credit to mask expense, same cents.
      by_target = Enum.group_by(lines, & &1.dimension_refs["project"])

      expected = %{
        ctx.riscv64.id => 6_240_001,
        ctx.gpu.id => 3_720_000,
        ctx.pta.id => 2_040_000
      }

      assert Map.keys(by_target) |> Enum.sort() == expected |> Map.keys() |> Enum.sort()

      for {target, cents} <- expected do
        legs = by_target[target]

        assert Enum.sort(Enum.map(legs, &{&1.account_id, &1.debit_cents, &1.credit_cents})) ==
                 Enum.sort([
                   {ctx.wip.id, cents, 0},
                   {ctx.mask.id, 0, cents}
                 ])
      end

      # The invoice's cost moved exactly once, and only dimensions were used.
      assert Enum.reduce(lines, 0, &(&1.debit_cents + &2)) == @mask_cents
      assert Enum.reduce(lines, 0, &(&1.credit_cents + &2)) == @mask_cents
      assert Enum.all?(lines, &(&1.dimension_refs != %{}))

      # R1 and R6: the org balance stays zero and every cost object nets zero.
      assert {:ok, 0} = Reconcile.org_balance(org, @repo, line_resource: JournalLine)
      assert {:ok, true} = DimensionReconcile.balanced?(org, @repo, line_resource: JournalLine)
    end
  end

  # ── a4: R10 ────────────────────────────────────────────────────────────────

  describe "a4 — the period guard" do
    test "a closed period refuses the post and leaves the draft alone", %{
      org: org,
      admin: admin,
      tenant: tenant
    } do
      ctx = books!(admin, org)
      bill = approved_mask_bill!(tenant, org, ctx.mask)

      {:ok, header} =
        draft(tenant, org, bill, ctx.wip, [
          share(ctx.riscv64, 1),
          share(ctx.gpu, 1)
        ])

      # The allocation is dated inside a month that is now closed.
      period = period!(admin, org, header.allocated_on.year, header.allocated_on.month)
      _closed = period |> Ash.Changeset.for_update(:close, %{}, scope: admin) |> Ash.update!()

      assert {:error, %Ash.Error.Invalid{} = err} = post(header, tenant)
      assert Exception.message(err) =~ "CLOSED"

      assert entries(org) == []
      assert reload(header).status == :draft
    end
  end

  # ── a5: one-way state machine ──────────────────────────────────────────────

  describe "a5 — a posted allocation is final" do
    test "a second :post is refused", %{org: org, admin: admin, tenant: tenant} do
      ctx = books!(admin, org)
      bill = approved_mask_bill!(tenant, org, ctx.mask)

      {:ok, header} =
        draft(tenant, org, bill, ctx.wip, [
          share(ctx.riscv64, 1),
          share(ctx.gpu, 1)
        ])

      assert {:ok, posted} = post(header, tenant)
      assert {:error, %Ash.Error.Invalid{} = err} = post(posted, tenant)

      assert Exception.message(err) =~ "posted"
      assert length(entries(org)) == 1
    end
  end

  # ── a6: fail-honest ────────────────────────────────────────────────────────

  describe "a6 — fail-honest refusals" do
    test "an amount too small for the number of targets is refused, not zero-lined", %{
      org: org,
      admin: admin,
      tenant: tenant
    } do
      ctx = books!(admin, org)
      bill = approved_mask_bill!(tenant, org, ctx.mask, 2)

      assert {:error, %Ash.Error.Invalid{} = err} =
               draft(tenant, org, bill, ctx.wip, [
                 share(ctx.riscv64, 1),
                 share(ctx.gpu, 1),
                 share(ctx.pta, 1)
               ])

      assert Exception.message(err) =~ "too small"
      assert all_allocations(org) == []
    end

    test "the source and target accounts must differ", %{org: org, admin: admin, tenant: tenant} do
      ctx = books!(admin, org)
      bill = approved_mask_bill!(tenant, org, ctx.mask)

      assert {:error, %Ash.Error.Invalid{} = err} =
               draft(tenant, org, bill, ctx.mask, [
                 share(ctx.riscv64, 1),
                 share(ctx.gpu, 1)
               ])

      assert Exception.message(err) =~ "same"
    end

    test "a foreign cost object is refused by the same-org rule", %{
      org: org,
      admin: admin,
      tenant: tenant
    } do
      ctx = books!(admin, org)
      bill = approved_mask_bill!(tenant, org, ctx.mask)

      foreign_org = Ash.UUID.generate()
      foreign = cost_object!(admin_scope(foreign_org), foreign_org, "foreign", :chip)

      assert {:error, %Ash.Error.Invalid{} = err} =
               draft(tenant, org, bill, ctx.wip, [
                 share(foreign, 1),
                 share(ctx.gpu, 1)
               ])

      assert Exception.message(err) =~ "cross-org"
      assert all_allocations(org) == []
    end
  end

  # ── a7: DB belts ───────────────────────────────────────────────────────────

  describe "a7 — DB belts" do
    test "shares are append-only and a posted header is final", %{
      org: org,
      admin: admin,
      tenant: tenant
    } do
      ctx = books!(admin, org)
      bill = approved_mask_bill!(tenant, org, ctx.mask)

      {:ok, header} =
        draft(tenant, org, bill, ctx.wip, [
          share(ctx.riscv64, 1),
          share(ctx.gpu, 1)
        ])

      assert {:ok, posted} = post(header, tenant)
      [share_row | _] = shares(org, posted.id)

      assert {:error, %Postgrex.Error{postgres: %{message: share_message}}} =
               @repo.query(
                 "UPDATE csf_cost_allocation_share SET csf_allocated_cents = 1 WHERE csf_id = $1::text::uuid",
                 [share_row.id]
               )

      assert share_message =~ "append-only"

      assert {:error, %Postgrex.Error{postgres: %{message: header_message}}} =
               @repo.query(
                 "UPDATE fcs_cost_allocation SET fcs_amount_cents = 1 WHERE fcs_id = $1::text::uuid",
                 [posted.id]
               )

      assert header_message =~ "final"
    end
  end

  # ── fixture ────────────────────────────────────────────────────────────────

  defp tenant_scope(org_id) do
    %Samen.Scope{
      actor: %{id: "u:#{org_id}", org_id: org_id, role: :member, kind: :tenant, plane: :tenant}
    }
  end

  defp admin_scope(org_id) do
    %Samen.Scope{
      actor: %{id: "a:#{org_id}", org_id: org_id, role: :admin, kind: :tenant, plane: :tenant}
    }
  end

  defp books!(admin, org) do
    mask = new_account(admin, org, "6000", "Mask & Reticle", :expense)
    wip = new_account(admin, org, "1300", "WIP – Foundry", :asset)
    ap = new_account(admin, org, "2000", "Accounts Payable", :liability)
    map_posting!(admin, org, :ap_clearing, ap)

    %{
      mask: mask,
      wip: wip,
      ap: ap,
      riscv64: cost_object!(admin, org, "riscv64", :chip),
      gpu: cost_object!(admin, org, "gpu", :chip),
      pta: cost_object!(admin, org, "pta", :chip)
    }
  end

  defp new_account(scope, org, code, name, kind) do
    Account
    |> Ash.Changeset.for_create(
      :create,
      %{
        org_id: org,
        code: code,
        name: name,
        kind: kind,
        normal_side: if(kind in [:asset, :expense], do: :debit, else: :credit)
      },
      scope: scope
    )
    |> Ash.create!()
  end

  defp map_posting!(admin, org, key, account) do
    PostingAccount
    |> Ash.Changeset.for_create(:create, %{org_id: org, key: key, account_id: account.id},
      scope: admin
    )
    |> Ash.create!()
  end

  defp cost_object!(admin, org, code, kind) do
    CostObject
    |> Ash.Changeset.for_create(
      :create,
      %{org_id: org, code: code, name: "Programme #{code}", kind: kind},
      scope: admin
    )
    |> Ash.create!()
  end

  defp new_bill(scope, org, lines) do
    ApInvoice
    |> Ash.Changeset.for_create(
      :create,
      %{
        org_id: org,
        vendor_id: Ash.UUID.generate(),
        number: "V-" <> binary_part(Ash.UUID.generate(), 0, 8),
        bill_date: ~D[2026-09-15],
        lines: lines
      },
      scope: scope
    )
    |> Ash.create!(scope: scope)
  end

  defp approved_mask_bill!(scope, org, mask, amount \\ @mask_cents) do
    bill = new_bill(scope, org, [%{account_id: mask.id, amount_cents: amount}])
    {:gated, approval_id} = gate(bill, scope)

    {:ok, _approved, _meta} =
      Samen.Approvals.approve(approval_id, "a2:#{org}",
        approval_resource: @approval_resource,
        repo: @repo
      )

    Ash.get!(ApInvoice, bill.id, authorize?: false)
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

  defp share(cost_object, driver) do
    %{cost_object_id: cost_object.id, driver: driver}
  end

  defp draft(scope, org, bill, target, shares) do
    CostAllocation
    |> Ash.Changeset.for_create(
      :draft,
      %{
        org_id: org,
        ap_invoice_id: bill.id,
        basis: :die_area,
        allocated_on: ~D[2026-09-30],
        target_account_id: target.id,
        shares: shares
      },
      scope: scope
    )
    |> Ash.create()
  end

  defp post(header, scope) do
    header
    |> Ash.Changeset.for_update(:post, %{}, scope: scope)
    |> Ash.update()
  end

  defp period!(scope, org, year, month) do
    FiscalPeriod
    |> Ash.Changeset.for_create(:create, %{org_id: org, year: year, month: month}, scope: scope)
    |> Ash.create!()
  end

  defp reload(header), do: Ash.get!(CostAllocation, header.id, authorize?: false)

  defp shares(org, allocation_id) do
    CostAllocationShare
    |> Ash.Query.filter(org_id == ^org and cost_allocation_id == ^allocation_id)
    |> Ash.Query.sort(cost_object_id: :asc)
    |> Ash.read!(authorize?: false)
  end

  defp all_allocations(org) do
    CostAllocation
    |> Ash.Query.filter(org_id == ^org)
    |> Ash.read!(authorize?: false)
  end

  defp all_entries(org) do
    JournalEntry
    |> Ash.Query.filter(org_id == ^org)
    |> Ash.read!(authorize?: false)
  end

  defp entries(org) do
    JournalEntry
    |> Ash.Query.filter(org_id == ^org and source_key == "cost_allocation")
    |> Ash.read!(authorize?: false)
  end

  defp entry_lines(org, entry_id) do
    JournalLine
    |> Ash.Query.filter(org_id == ^org and entry_id == ^entry_id)
    |> Ash.read!(authorize?: false)
  end
end
