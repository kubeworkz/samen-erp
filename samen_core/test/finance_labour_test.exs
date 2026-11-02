defmodule Samen.FinanceLabourTest do
  @moduledoc """
  WS-ACCT Unit 10.2 (ADR-054 D17) — payroll allocated by **approved timesheet
  minutes**, using the Work and Finance fixtures together.

  Every refusal is paired with a positive control:

    * l1 the driver — only APPROVED sheets count, only entries inside the pay
      period count, overlapping sheets are included, and an unwired mount
      refuses (`:timesheets_not_wired`) instead of inventing a ratio;
    * l2 drafting — the split follows minutes exactly, posts nothing, and
      refuses no-driver / one-target / same-account / duplicate / zero-cent;
    * l3 the one entry — N cost objects land as ONE dimensioned post (R1 + R6);
    * l4 drift — hours approved after drafting refuse the post, the draft is
      discarded (kept as evidence), and a re-draft of the same period posts;
    * l5 R10 — a closed period refuses the post and leaves the draft alone;
    * l6 finality — a posted allocation cannot be re-posted or discarded, and
      its shares are append-only in the DB.
  """
  use ExUnit.Case, async: false

  require Ash.Query

  alias Samen.Scopes.Finance.DimensionReconcile
  alias Samen.Scopes.Finance.LabourDriver
  alias Samen.Scopes.Finance.Reconcile

  alias SamenCore.Support.FinanceFixture.{
    Account,
    CostObject,
    FiscalPeriod,
    JournalEntry,
    JournalLine,
    LabourAllocation,
    LabourAllocationShare
  }

  alias SamenCore.Support.WorkFixture.{Timesheet, TimesheetEntry}

  @repo SamenCore.TestRepo

  # Opaque HR ids (the scope stores a plain uuid, never a person record).
  @emp1 "00000000-0000-4000-8000-000000000001"
  @emp2 "00000000-0000-4000-8000-000000000002"
  @emp3 "00000000-0000-4000-8000-000000000003"
  @emp4 "00000000-0000-4000-8000-000000000004"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(@repo)
    org = Ash.UUID.generate()

    {:ok, org: org, admin: admin_scope(org), tenant: tenant_scope(org)}
  end

  # ── l1: the driver ─────────────────────────────────────────────────────────

  describe "l1 — only approved minutes inside the pay period count" do
    test "approved sheets drive; draft and submitted sheets contribute zero", %{
      org: org,
      admin: admin,
      tenant: tenant
    } do
      ctx = books!(admin, org)

      _approved =
        approved_sheet!(admin, tenant, org, @emp1, ~D[2026-09-01], ~D[2026-09-30], [
          {ctx.riscv64, ~D[2026-09-02], 480},
          {ctx.gpu, ~D[2026-09-03], 240}
        ])

      # Draft sheet: recorded but not approved.
      draft = sheet!(tenant, org, @emp2, ~D[2026-09-01], ~D[2026-09-30])
      _ = entry!(tenant, org, draft, ctx.pta, ~D[2026-09-04], 600)

      # Submitted sheet: still not a labour fact.
      submitted = sheet!(tenant, org, @emp3, ~D[2026-09-01], ~D[2026-09-30])
      _ = entry!(tenant, org, submitted, ctx.pta, ~D[2026-09-05], 300)
      {:ok, _} = submit(submitted, tenant)

      # Approved, but its entry is outside the September pay period.
      _august =
        approved_sheet!(admin, tenant, org, @emp4, ~D[2026-08-01], ~D[2026-08-31], [
          {ctx.pta, ~D[2026-08-20], 120}
        ])

      assert {:ok, driver} = driver(org, ~D[2026-09-01], ~D[2026-09-30])

      assert driver.total_minutes == 720
      assert driver.timesheets == 1

      assert Map.new(driver.shares, &{&1.cost_object_id, &1.minutes}) == %{
               ctx.riscv64.id => 480,
               ctx.gpu.id => 240
             }

      # The same driver is what the allocation freezes.
      assert {:ok, draft_header} =
               draft(tenant, org, ctx, ~D[2026-09-01], ~D[2026-09-30], 100_000)

      assert Map.new(shares(org, draft_header.id), &{&1.cost_object_id, &1.minutes}) == %{
               ctx.riscv64.id => 480,
               ctx.gpu.id => 240
             }
    end

    test "a sheet that OVERLAPS the period contributes its in-period entries", %{
      org: org,
      admin: admin,
      tenant: tenant
    } do
      ctx = books!(admin, org)

      _overlap =
        approved_sheet!(admin, tenant, org, @emp1, ~D[2026-08-15], ~D[2026-09-15], [
          {ctx.riscv64, ~D[2026-09-10], 300},
          {ctx.gpu, ~D[2026-08-20], 999}
        ])

      assert {:ok, driver} = driver(org, ~D[2026-09-01], ~D[2026-09-30])
      assert driver.total_minutes == 300

      assert [%{cost_object_id: riscv64, minutes: 300}] = driver.shares
      assert riscv64 == ctx.riscv64.id
    end

    test "an unwired Finance mount refuses fail-honest", %{org: org} do
      assert {:error, :timesheets_not_wired} =
               LabourDriver.driver(org, ~D[2026-09-01], ~D[2026-09-30], [])
    end
  end

  # ── l2: drafting ───────────────────────────────────────────────────────────

  describe "l2 — drafting freezes the split and posts nothing" do
    test "the cents follow the approved minutes exactly", %{
      org: org,
      admin: admin,
      tenant: tenant
    } do
      ctx = books!(admin, org)

      _sheet =
        approved_sheet!(admin, tenant, org, @emp1, ~D[2026-09-01], ~D[2026-09-30], [
          {ctx.riscv64, ~D[2026-09-02], 480},
          {ctx.gpu, ~D[2026-09-03], 240},
          {ctx.pta, ~D[2026-09-04], 240}
        ])

      assert {:ok, header} = draft(tenant, org, ctx, ~D[2026-09-01], ~D[2026-09-30], 100_000)
      assert header.status == :draft
      assert header.total_cents == 100_000
      assert header.entry_id == nil
      assert header.posted_at == nil

      rows = shares(org, header.id)

      assert Map.new(rows, &{&1.cost_object_id, {&1.minutes, &1.allocated_cents}}) == %{
               ctx.riscv64.id => {480, 50_000},
               ctx.gpu.id => {240, 25_000},
               ctx.pta.id => {240, 25_000}
             }

      assert Enum.reduce(rows, 0, &(&1.allocated_cents + &2)) == 100_000

      # NOTHING posted: the labour allocation has no entry.
      assert entries(org) == []
    end

    test "a period with no approved minutes is refused", %{
      org: org,
      admin: admin,
      tenant: tenant
    } do
      ctx = books!(admin, org)

      assert {:error, %Ash.Error.Invalid{} = err} =
               draft(tenant, org, ctx, ~D[2026-10-01], ~D[2026-10-31], 100_000)

      assert Exception.message(err) =~ "no approved timesheet minutes"
      assert all_allocations(org) == []
    end

    test "one cost object is a reclass, not an allocation", %{
      org: org,
      admin: admin,
      tenant: tenant
    } do
      ctx = books!(admin, org)

      _sheet =
        approved_sheet!(admin, tenant, org, @emp1, ~D[2026-09-01], ~D[2026-09-30], [
          {ctx.riscv64, ~D[2026-09-02], 480}
        ])

      assert {:error, %Ash.Error.Invalid{} = err} =
               draft(tenant, org, ctx, ~D[2026-09-01], ~D[2026-09-30], 100_000)

      assert Exception.message(err) =~ "fewer than two"
    end

    test "the accounts must differ", %{org: org, admin: admin, tenant: tenant} do
      ctx = books!(admin, org)

      _sheet =
        approved_sheet!(admin, tenant, org, @emp1, ~D[2026-09-01], ~D[2026-09-30], [
          {ctx.riscv64, ~D[2026-09-02], 480},
          {ctx.gpu, ~D[2026-09-03], 240}
        ])

      assert {:error, %Ash.Error.Invalid{} = err} =
               LabourAllocation
               |> Ash.Changeset.for_create(
                 :draft,
                 %{
                   org_id: org,
                   period_start: ~D[2026-09-01],
                   period_end: ~D[2026-09-30],
                   total_cents: 100_000,
                   source_account_id: ctx.payroll.id,
                   target_account_id: ctx.payroll.id
                 },
                 scope: tenant
               )
               |> Ash.create()

      assert Exception.message(err) =~ "same"
    end

    test "one live allocation per period and source account", %{
      org: org,
      admin: admin,
      tenant: tenant
    } do
      ctx = books!(admin, org)

      _sheet =
        approved_sheet!(admin, tenant, org, @emp1, ~D[2026-09-01], ~D[2026-09-30], [
          {ctx.riscv64, ~D[2026-09-02], 480},
          {ctx.gpu, ~D[2026-09-03], 240}
        ])

      assert {:ok, _} = draft(tenant, org, ctx, ~D[2026-09-01], ~D[2026-09-30], 100_000)

      assert {:error, %Ash.Error.Invalid{} = err} =
               draft(tenant, org, ctx, ~D[2026-09-01], ~D[2026-09-30], 100_000)

      assert Exception.message(err) =~ "already allocated"
      assert length(all_allocations(org)) == 1
    end

    test "a total too small for the number of targets is refused, not zero-lined", %{
      org: org,
      admin: admin,
      tenant: tenant
    } do
      ctx = books!(admin, org)

      _sheet =
        approved_sheet!(admin, tenant, org, @emp1, ~D[2026-09-01], ~D[2026-09-30], [
          {ctx.riscv64, ~D[2026-09-02], 480},
          {ctx.gpu, ~D[2026-09-03], 240},
          {ctx.pta, ~D[2026-09-04], 240}
        ])

      assert {:error, %Ash.Error.Invalid{} = err} =
               draft(tenant, org, ctx, ~D[2026-09-01], ~D[2026-09-30], 2)

      assert Exception.message(err) =~ "too small"
      assert all_allocations(org) == []
    end
  end

  # ── l3: the one entry ──────────────────────────────────────────────────────

  describe "l3 — the payroll split is ONE dimensioned entry" do
    test "N cost objects post as one entry, each pair tagged to its cost object", %{
      org: org,
      admin: admin,
      tenant: tenant
    } do
      ctx = books!(admin, org)

      _sheet =
        approved_sheet!(admin, tenant, org, @emp1, ~D[2026-09-01], ~D[2026-09-30], [
          {ctx.riscv64, ~D[2026-09-02], 480},
          {ctx.gpu, ~D[2026-09-03], 240},
          {ctx.pta, ~D[2026-09-04], 240}
        ])

      {:ok, header} = draft(tenant, org, ctx, ~D[2026-09-01], ~D[2026-09-30], 100_000)
      assert {:ok, posted} = post(header, tenant)
      assert posted.status == :posted
      assert posted.entry_id != nil

      [entry] = entries(org)
      assert entry.id == posted.entry_id
      assert entry.source_key == "labour_allocation"
      assert entry.source_id == posted.id
      assert entry.entry_date == ~D[2026-09-30]

      lines = entry_lines(org, entry.id)
      assert length(lines) == 6

      assert Enum.all?(lines, &(Map.keys(&1.dimension_refs) == ["project"]))

      expected = %{
        ctx.riscv64.id => 50_000,
        ctx.gpu.id => 25_000,
        ctx.pta.id => 25_000
      }

      by_target = Enum.group_by(lines, & &1.dimension_refs["project"])
      assert Map.keys(by_target) |> Enum.sort() == expected |> Map.keys() |> Enum.sort()

      for {target, cents} <- expected do
        assert Enum.sort(
                 Enum.map(by_target[target], &{&1.account_id, &1.debit_cents, &1.credit_cents})
               ) ==
                 Enum.sort([
                   {ctx.wip.id, cents, 0},
                   {ctx.payroll.id, 0, cents}
                 ])
      end

      # R1 and R6: the org balances and every cost object nets to zero.
      assert {:ok, 0} = Reconcile.org_balance(org, @repo, line_resource: JournalLine)
      assert {:ok, true} = DimensionReconcile.balanced?(org, @repo, line_resource: JournalLine)
    end
  end

  # ── l4: drift ──────────────────────────────────────────────────────────────

  describe "l4 — hours approved after drafting refuse the post" do
    test "labour_drift blocks the post; discard frees the period and the re-draft posts", %{
      org: org,
      admin: admin,
      tenant: tenant
    } do
      ctx = books!(admin, org)

      _first =
        approved_sheet!(admin, tenant, org, @emp1, ~D[2026-09-01], ~D[2026-09-30], [
          {ctx.riscv64, ~D[2026-09-02], 480},
          {ctx.gpu, ~D[2026-09-03], 480}
        ])

      {:ok, stale} = draft(tenant, org, ctx, ~D[2026-09-01], ~D[2026-09-30], 100_000)
      assert Map.new(shares(org, stale.id), &{&1.cost_object_id, &1.minutes}) == %{
               ctx.riscv64.id => 480,
               ctx.gpu.id => 480
             }

      # A second employee's hours are approved after the draft froze the split:
      # equal minutes to both programmes, so the CURRENT driver is 50/50.
      _second =
        approved_sheet!(admin, tenant, org, @emp2, ~D[2026-09-01], ~D[2026-09-30], [
          {ctx.riscv64, ~D[2026-09-10], 480},
          {ctx.gpu, ~D[2026-09-10], 480}
        ])

      assert {:error, %Ash.Error.Invalid{} = err} = post(stale, tenant)
      assert Exception.message(err) =~ "labour drift"
      assert entries(org) == []
      assert reload(stale).status == :draft

      # The stale proposal is withdrawn (kept as evidence; the slot is freed)…
      assert {:ok, discarded} = discard(stale, tenant)
      assert discarded.status == :discarded

      # …and the re-draft follows the CURRENT driver: 480 / 960, exactly half.
      assert {:ok, fresh} = draft(tenant, org, ctx, ~D[2026-09-01], ~D[2026-09-30], 100_000)

      assert Map.new(shares(org, fresh.id), &{&1.cost_object_id, &1.allocated_cents}) == %{
               ctx.riscv64.id => 50_000,
               ctx.gpu.id => 50_000
             }

      assert {:ok, posted} = post(fresh, tenant)
      assert posted.status == :posted
      assert length(entries(org)) == 1

      # The withdrawn proposal's shares are still there as evidence.
      assert length(shares(org, stale.id)) == 2
    end
  end

  # ── l5: R10 ────────────────────────────────────────────────────────────────

  describe "l5 — the period guard" do
    test "a closed period refuses the post and leaves the draft alone", %{
      org: org,
      admin: admin,
      tenant: tenant
    } do
      ctx = books!(admin, org)

      _sheet =
        approved_sheet!(admin, tenant, org, @emp1, ~D[2026-09-01], ~D[2026-09-30], [
          {ctx.riscv64, ~D[2026-09-02], 480},
          {ctx.gpu, ~D[2026-09-03], 240}
        ])

      {:ok, header} = draft(tenant, org, ctx, ~D[2026-09-01], ~D[2026-09-30], 100_000)

      period = period!(admin, org, 2026, 9)
      _closed = period |> Ash.Changeset.for_update(:close, %{}, scope: admin) |> Ash.update!()

      assert {:error, %Ash.Error.Invalid{} = err} = post(header, tenant)
      assert Exception.message(err) =~ "CLOSED"
      assert entries(org) == []
      assert reload(header).status == :draft
    end
  end

  # ── l6: finality ───────────────────────────────────────────────────────────

  describe "l6 — a posted allocation is final" do
    test "re-post and discard are refused; shares are append-only in the DB", %{
      org: org,
      admin: admin,
      tenant: tenant
    } do
      ctx = books!(admin, org)

      _sheet =
        approved_sheet!(admin, tenant, org, @emp1, ~D[2026-09-01], ~D[2026-09-30], [
          {ctx.riscv64, ~D[2026-09-02], 480},
          {ctx.gpu, ~D[2026-09-03], 240}
        ])

      {:ok, header} = draft(tenant, org, ctx, ~D[2026-09-01], ~D[2026-09-30], 100_000)
      {:ok, posted} = post(header, tenant)

      assert {:error, %Ash.Error.Invalid{}} = post(posted, tenant)
      assert {:error, %Ash.Error.Invalid{} = discard_err} = discard(posted, tenant)
      assert Exception.message(discard_err) =~ "final"

      [share_row | _] = shares(org, posted.id)

      assert {:error, %Postgrex.Error{postgres: %{message: share_message}}} =
               @repo.query(
                 "UPDATE slf_labour_allocation_share SET slf_allocated_cents = 1 WHERE slf_id = $1::text::uuid",
                 [share_row.id]
               )

      assert share_message =~ "append-only"

      # The header belt refuses any rewrite after posting.
      assert {:error, %Postgrex.Error{postgres: %{message: header_message}}} =
               @repo.query(
                 "UPDATE sfl_labour_allocation SET sfl_total_cents = 1 WHERE sfl_id = $1::text::uuid",
                 [posted.id]
               )

      assert header_message =~ "final"
      assert length(entries(org)) == 1
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
    payroll = new_account(admin, org, "6100", "Payroll Expense", :expense)
    wip = new_account(admin, org, "1300", "WIP – Foundry", :asset)
    ap = new_account(admin, org, "2000", "Accounts Payable", :liability)

    %{
      payroll: payroll,
      wip: wip,
      ap: ap,
      riscv64: cost_object!(admin, org, "riscv64"),
      gpu: cost_object!(admin, org, "gpu"),
      pta: cost_object!(admin, org, "pta")
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

  defp cost_object!(scope, org, code) do
    CostObject
    |> Ash.Changeset.for_create(
      :create,
      %{org_id: org, code: code, name: "Programme #{code}", kind: :chip},
      scope: scope
    )
    |> Ash.create!()
  end

  defp sheet!(scope, org, employee, from, to) do
    Timesheet
    |> Ash.Changeset.for_create(
      :create,
      %{org_id: org, employee_id: employee, period_start: from, period_end: to},
      scope: scope
    )
    |> Ash.create!()
  end

  defp entry!(scope, org, sheet, cost_object, day, minutes) do
    TimesheetEntry
    |> Ash.Changeset.for_create(
      :create,
      %{
        org_id: org,
        timesheet_id: sheet.id,
        worked_on: day,
        minutes: minutes,
        cost_object_id: cost_object.id
      },
      scope: scope
    )
    |> Ash.create!()
  end

  defp submit(sheet, scope) do
    sheet |> Ash.Changeset.for_update(:submit, %{}, scope: scope) |> Ash.update()
  end

  defp approve(sheet, scope) do
    sheet |> Ash.Changeset.for_update(:approve, %{}, scope: scope) |> Ash.update()
  end

  defp approved_sheet!(admin, tenant, org, employee, from, to, rows) do
    sheet = sheet!(tenant, org, employee, from, to)

    Enum.each(rows, fn {cost_object, day, minutes} ->
      _ = entry!(tenant, org, sheet, cost_object, day, minutes)
    end)

    {:ok, submitted} = submit(sheet, tenant)
    {:ok, approved} = approve(submitted, admin)
    approved
  end

  defp driver(org, from, to) do
    LabourDriver.driver(org, from, to,
      timesheet: Timesheet,
      timesheet_entry: TimesheetEntry
    )
  end

  defp draft(scope, org, ctx, from, to, total) do
    LabourAllocation
    |> Ash.Changeset.for_create(
      :draft,
      %{
        org_id: org,
        period_start: from,
        period_end: to,
        total_cents: total,
        source_account_id: ctx.payroll.id,
        target_account_id: ctx.wip.id
      },
      scope: scope
    )
    |> Ash.create()
  end

  defp post(header, scope) do
    header |> Ash.Changeset.for_update(:post, %{}, scope: scope) |> Ash.update()
  end

  defp discard(header, scope) do
    header |> Ash.Changeset.for_update(:discard, %{}, scope: scope) |> Ash.update()
  end

  defp period!(scope, org, year, month) do
    FiscalPeriod
    |> Ash.Changeset.for_create(:create, %{org_id: org, year: year, month: month}, scope: scope)
    |> Ash.create!()
  end

  defp reload(header), do: Ash.get!(LabourAllocation, header.id, authorize?: false)

  defp shares(org, allocation_id) do
    LabourAllocationShare
    |> Ash.Query.filter(org_id == ^org and labour_allocation_id == ^allocation_id)
    |> Ash.Query.sort(cost_object_id: :asc)
    |> Ash.read!(authorize?: false)
  end

  defp all_allocations(org) do
    LabourAllocation
    |> Ash.Query.filter(org_id == ^org)
    |> Ash.read!(authorize?: false)
  end

  defp entries(org) do
    JournalEntry
    |> Ash.Query.filter(org_id == ^org and source_key == "labour_allocation")
    |> Ash.read!(authorize?: false)
  end

  defp entry_lines(org, entry_id) do
    JournalLine
    |> Ash.Query.filter(org_id == ^org and entry_id == ^entry_id)
    |> Ash.read!(authorize?: false)
  end
end
