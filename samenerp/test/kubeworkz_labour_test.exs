defmodule Samenerp.KubeworkzLabourTest do
  @moduledoc """
  WS-ACCT Unit 10.2 (ADR-054 D17) on the real host: Kubeworkz design
  engineering's September payroll (6020) is allocated across the RISC-V64,
  GPU and PTA programmes by the ACTUAL approved timesheet minutes, and posts as
  ONE dimensioned entry. No ratio is declared, and an unapproved hour cannot
  move a cent.

  This is the host proof that the Work and Finance scope mounts wire together
  on `Samenerp` — `Samenerp.Work.Timesheet`'s entries name real
  `Samenerp.Erp.CostObject` rows, and `Samenerp.Erp.LabourAllocation` reads
  them through the `labour:` mount option.
  """
  use Samenerp.DataCase, async: false

  require Ash.Query

  alias Samen.Scopes.Finance.DimensionReconcile
  alias Samen.Scopes.Finance.LabourDriver
  alias Samenerp.Erp
  alias Samenerp.Kubeworkz.Books
  alias Samenerp.Operator, as: Op
  alias Samenerp.Work

  @employee "00000000-0000-4000-8000-000000000042"

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

  defp cost_object!(org, code) do
    Erp.CostObject
    |> Ash.Query.filter(org_id == ^org and code == ^code)
    |> Ash.read_one!(authorize?: false)
  end

  defp timesheet!(scope, org) do
    Work.Timesheet
    |> Ash.Changeset.for_create(
      :create,
      %{
        org_id: org,
        employee_id: @employee,
        period_start: ~D[2026-09-01],
        period_end: ~D[2026-09-30]
      },
      scope: scope
    )
    |> Ash.create!()
  end

  defp entry!(scope, org, sheet, cost_object, day, minutes) do
    Work.TimesheetEntry
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

  defp approve!(sheet, member, admin) do
    {:ok, submitted} =
      sheet |> Ash.Changeset.for_update(:submit, %{}, scope: member) |> Ash.update()

    {:ok, approved} =
      submitted |> Ash.Changeset.for_update(:approve, %{}, scope: admin) |> Ash.update()

    approved
  end

  test "September design-engineering payroll follows approved hours into one entry" do
    org = create_org!("Kubeworkz Labour Allocation")
    member = member_scope(org.id)
    admin = admin_scope(org.id)

    assert %{cost_objects: %{created: 9}} = Books.seed!(org.id)

    labour = account!(org.id, "6020")
    wip = account!(org.id, "1300")

    riscv64 = cost_object!(org.id, "riscv64-soc")
    gpu = cost_object!(org.id, "gpu")
    pta = cost_object!(org.id, "pta")

    sheet = timesheet!(member, org.id)

    _ =
      entry!(member, org.id, sheet, riscv64, ~D[2026-09-02], 480)

    _ = entry!(member, org.id, sheet, gpu, ~D[2026-09-03], 240)
    _ = entry!(member, org.id, sheet, pta, ~D[2026-09-04], 240)

    # The capture is a draft; the driver must not see a single minute yet.
    assert {:ok, %{shares: []}} =
             LabourDriver.driver(org.id, ~D[2026-09-01], ~D[2026-09-30],
               timesheet: Work.Timesheet,
               timesheet_entry: Work.TimesheetEntry
             )

    approved = approve!(sheet, member, admin)
    assert approved.status == :approved

    assert {:ok, driver} =
             LabourDriver.driver(org.id, ~D[2026-09-01], ~D[2026-09-30],
               timesheet: Work.Timesheet,
               timesheet_entry: Work.TimesheetEntry
             )

    assert driver.total_minutes == 960

    assert Map.new(driver.shares, &{&1.cost_object_id, &1.minutes}) == %{
             riscv64.id => 480,
             gpu.id => 240,
             pta.id => 240
           }

    # 1 000.00 of design-engineering payroll for the month.
    assert {:ok, header} =
             Erp.LabourAllocation
             |> Ash.Changeset.for_create(
               :draft,
               %{
                 org_id: org.id,
                 period_start: ~D[2026-09-01],
                 period_end: ~D[2026-09-30],
                 total_cents: 100_000,
                 source_account_id: labour.id,
                 target_account_id: wip.id
               },
               scope: member
             )
             |> Ash.create()

    assert header.status == :draft
    assert all_entries(org.id) == []

    rows =
      Erp.LabourAllocationShare
      |> Ash.Query.filter(org_id == ^org.id and labour_allocation_id == ^header.id)
      |> Ash.Query.sort(cost_object_id: :asc)
      |> Ash.read!(authorize?: false)

    assert Map.new(rows, &{&1.cost_object_id, {&1.minutes, &1.allocated_cents}}) == %{
             riscv64.id => {480, 50_000},
             gpu.id => {240, 25_000},
             pta.id => {240, 25_000}
           }

    assert {:ok, posted} =
             header |> Ash.Changeset.for_update(:post, %{}, scope: member) |> Ash.update()

    assert posted.status == :posted

    [entry] = entries(org.id)
    assert entry.id == posted.entry_id
    assert entry.source_key == "labour_allocation"
    assert entry.entry_date == ~D[2026-09-30]

    entry_lines = lines(org.id, entry.id)
    assert length(entry_lines) == 6

    by_programme = Enum.group_by(entry_lines, & &1.dimension_refs["project"])

    for {programme, cents} <- %{
          riscv64.id => 50_000,
          gpu.id => 25_000,
          pta.id => 25_000
        } do
      assert Enum.sort(
               Enum.map(by_programme[programme], &{&1.account_id, &1.debit_cents, &1.credit_cents})
             ) ==
               Enum.sort([{wip.id, cents, 0}, {labour.id, 0, cents}])
    end

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
    |> Ash.Query.filter(org_id == ^org and source_key == "labour_allocation")
    |> Ash.read!(authorize?: false)
  end

  defp lines(org, entry_id) do
    Erp.JournalLine
    |> Ash.Query.filter(org_id == ^org and entry_id == ^entry_id)
    |> Ash.read!(authorize?: false)
  end
end
