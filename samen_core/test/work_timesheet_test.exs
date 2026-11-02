defmodule Samen.WorkTimesheetTest do
  @moduledoc """
  WS-ACCT Unit 10.2 (ADR-054 D17) — Work timesheet capture, mounted via
  `test/support/work_fixture.ex` with the fixture's Finance cost objects.

  Every refusal is paired with a positive control:

    * t1 capture — a draft sheet with entries, org-scoped reads, minutes > 0;
    * t2 lifecycle — a blank sheet cannot be submitted, draft → submitted
      stamps `submitted_at`, a member cannot approve, an admin can, and a
      second submit of an approved sheet is refused;
    * t3 freeze — once a sheet leaves draft, entry create/update/destroy are
      refused in Ash AND by the DB trigger (the belt under the guard);
    * t4 window — an entry outside the sheet's period is refused, and a
      backwards window is refused;
    * t5 identity — one sheet per {employee, period_start}, and the identity
      columns are immutable at the DB;
    * t6 same-org — a foreign cost object and a foreign sheet are refused;
    * t7 DB finality — an approved sheet cannot be rewritten by raw SQL.
  """
  use ExUnit.Case, async: false

  require Ash.Query

  alias SamenCore.Support.FinanceFixture.CostObject

  alias SamenCore.Support.WorkFixture.{Timesheet, TimesheetEntry}

  @repo SamenCore.TestRepo

  # Opaque HR ids (the scope stores a plain uuid, never a person record).
  @emp1 "00000000-0000-4000-8000-000000000001"
  @emp2 "00000000-0000-4000-8000-000000000002"
  @emp9 "00000000-0000-4000-8000-000000000009"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(@repo)
    org = Ash.UUID.generate()

    {:ok, org: org, admin: admin_scope(org), tenant: tenant_scope(org)}
  end

  # ── t1: capture ────────────────────────────────────────────────────────────

  describe "t1 — capture" do
    test "a draft sheet captures minutes against cost objects", %{
      org: org,
      admin: admin,
      tenant: tenant
    } do
      chip = cost_object!(admin, org, "riscv64")
      gpu = cost_object!(admin, org, "gpu")

      sheet = sheet!(tenant, org, @emp1, ~D[2026-09-01], ~D[2026-09-30])
      assert sheet.status == :draft
      assert sheet.submitted_at == nil
      assert sheet.approved_at == nil

      _ = entry!(tenant, org, sheet, chip, ~D[2026-09-02], 480)
      _ = entry!(tenant, org, sheet, gpu, ~D[2026-09-02], 240)

      entries = entries(org, sheet.id)

      assert Map.new(entries, &{&1.cost_object_id, &1.minutes}) == %{
               chip.id => 480,
               gpu.id => 240
             }

      # Org-scoped: another org sees nothing.
      assert Timesheet |> Ash.read!(scope: tenant_scope(Ash.UUID.generate())) == []
      assert TimesheetEntry |> Ash.read!(scope: tenant_scope(Ash.UUID.generate())) == []

      assert [%{id: id}] = Timesheet |> Ash.read!(scope: tenant)
      assert id == sheet.id
    end

    test "minutes must be positive", %{org: org, admin: admin, tenant: tenant} do
      chip = cost_object!(admin, org, "riscv64")
      sheet = sheet!(tenant, org, @emp1, ~D[2026-09-01], ~D[2026-09-30])

      assert {:error, %Ash.Error.Invalid{}} =
               TimesheetEntry
               |> Ash.Changeset.for_create(
                 :create,
                 %{
                   org_id: org,
                   timesheet_id: sheet.id,
                   worked_on: ~D[2026-09-02],
                   minutes: 0,
                   cost_object_id: chip.id
                 },
                 scope: tenant
               )
               |> Ash.create()

      # CONTROL: one minute is accepted.
      assert %{minutes: 1} = entry!(tenant, org, sheet, chip, ~D[2026-09-02], 1)
    end
  end

  # ── t2: lifecycle ──────────────────────────────────────────────────────────

  describe "t2 — draft → submitted → approved" do
    test "a blank sheet cannot be submitted", %{org: org, tenant: tenant} do
      sheet = sheet!(tenant, org, @emp1, ~D[2026-09-01], ~D[2026-09-30])

      assert {:error, %Ash.Error.Invalid{} = err} = submit(sheet, tenant)
      assert Exception.message(err) =~ "no entries"
      assert reload(sheet).status == :draft
    end

    test "submission stamps the time; approval is admin-only and final", %{
      org: org,
      admin: admin,
      tenant: tenant
    } do
      chip = cost_object!(admin, org, "riscv64")
      sheet = sheet!(tenant, org, @emp1, ~D[2026-09-01], ~D[2026-09-30])
      _ = entry!(tenant, org, sheet, chip, ~D[2026-09-02], 480)

      assert {:ok, submitted} = submit(sheet, tenant)
      assert submitted.status == :submitted
      assert %DateTime{} = submitted.submitted_at
      assert submitted.approved_at == nil

      # A member cannot approve (the manager rung).
      assert {:error, %Ash.Error.Forbidden{}} = approve(submitted, tenant)

      assert {:ok, approved} = approve(submitted, admin)
      assert approved.status == :approved
      assert %DateTime{} = approved.approved_at

      # One-way: a second submit is refused and leaves it approved.
      assert {:error, %Ash.Error.Invalid{} = err} = submit(approved, admin)
      assert Exception.message(err) =~ "approved"
      assert reload(approved).status == :approved
    end
  end

  # ── t3: freeze ─────────────────────────────────────────────────────────────

  describe "t3 — entries freeze once the sheet leaves draft" do
    test "create/update/destroy are refused after submission", %{
      org: org,
      admin: admin,
      tenant: tenant
    } do
      chip = cost_object!(admin, org, "riscv64")
      gpu = cost_object!(admin, org, "gpu")
      sheet = sheet!(tenant, org, @emp1, ~D[2026-09-01], ~D[2026-09-30])
      entry = entry!(tenant, org, sheet, chip, ~D[2026-09-02], 480)
      {:ok, _submitted} = submit(sheet, tenant)

      assert {:error, %Ash.Error.Invalid{} = create_err} =
               entry_attrs(tenant, org, sheet, gpu, ~D[2026-09-03], 60)
               |> then(fn changeset -> Ash.create(changeset) end)

      assert Exception.message(create_err) =~ "draft"

      assert {:error, %Ash.Error.Invalid{} = update_err} =
               entry
               |> Ash.Changeset.for_update(:update, %{minutes: 10}, scope: tenant)
               |> Ash.update()

      assert Exception.message(update_err) =~ "draft"

      assert {:error, %Ash.Error.Invalid{} = delete_err} =
               entry
               |> Ash.Changeset.for_destroy(:destroy, %{}, scope: tenant)
               |> Ash.destroy()

      assert Exception.message(delete_err) =~ "draft"
      assert [%{minutes: 480}] = entries(org, sheet.id)
    end

    test "the DB trigger refuses a raw entry write after submission", %{
      org: org,
      admin: admin,
      tenant: tenant
    } do
      chip = cost_object!(admin, org, "riscv64")
      sheet = sheet!(tenant, org, @emp1, ~D[2026-09-01], ~D[2026-09-30])
      entry = entry!(tenant, org, sheet, chip, ~D[2026-09-02], 480)
      {:ok, _submitted} = submit(sheet, tenant)

      assert {:error, %Postgrex.Error{postgres: %{message: message}}} =
               @repo.query(
                 "UPDATE tsw_timesheet_entry SET tsw_minutes = 1 WHERE tsw_id = $1::text::uuid",
                 [entry.id]
               )

      assert message =~ "draft"
    end
  end

  # ── t4: window ─────────────────────────────────────────────────────────────

  describe "t4 — the capture window" do
    test "an entry outside the period is refused; inside is accepted", %{
      org: org,
      admin: admin,
      tenant: tenant
    } do
      chip = cost_object!(admin, org, "riscv64")
      sheet = sheet!(tenant, org, @emp1, ~D[2026-09-01], ~D[2026-09-30])

      assert {:error, %Ash.Error.Invalid{} = err} =
               entry_attrs(tenant, org, sheet, chip, ~D[2026-10-01], 60)
               |> then(&Ash.create/1)

      assert Exception.message(err) =~ "outside"

      # CONTROL: both boundary days are inside.
      assert %{worked_on: ~D[2026-09-01]} =
               entry!(tenant, org, sheet, chip, ~D[2026-09-01], 30)

      assert %{worked_on: ~D[2026-09-30]} =
               entry!(tenant, org, sheet, chip, ~D[2026-09-30], 30)
    end

    test "a backwards window is refused", %{org: org, tenant: tenant} do
      assert {:error, %Ash.Error.Invalid{} = err} =
               Timesheet
               |> Ash.Changeset.for_create(
                 :create,
                 %{
                   org_id: org,
                   employee_id: @emp1,
                   period_start: ~D[2026-09-30],
                   period_end: ~D[2026-09-01]
                 },
                 scope: tenant
               )
               |> Ash.create()

      assert Exception.message(err) =~ "period_end"
    end
  end

  # ── t5: identity ───────────────────────────────────────────────────────────

  describe "t5 — identity" do
    test "one sheet per employee and period_start", %{org: org, tenant: tenant} do
      _first = sheet!(tenant, org, @emp1, ~D[2026-09-01], ~D[2026-09-30])

      assert {:error, %Ash.Error.Invalid{}} =
               Timesheet
               |> Ash.Changeset.for_create(
                 :create,
                 %{
                   org_id: org,
                   employee_id: @emp1,
                   period_start: ~D[2026-09-01],
                   period_end: ~D[2026-09-30]
                 },
                 scope: tenant
               )
               |> Ash.create()

      # CONTROL: a different employee — and a different start — are allowed.
      _other = sheet!(tenant, org, @emp2, ~D[2026-09-01], ~D[2026-09-30])
      _next = sheet!(tenant, org, @emp1, ~D[2026-10-01], ~D[2026-10-31])
      assert length(all_sheets(org)) == 3
    end

    test "the status cannot be smuggled through create", %{org: org, tenant: tenant} do
      assert {:error, %Ash.Error.Invalid{}} =
               Timesheet
               |> Ash.Changeset.for_create(
                 :create,
                 %{
                   org_id: org,
                   employee_id: @emp1,
                   period_start: ~D[2026-09-01],
                   period_end: ~D[2026-09-30],
                   status: :approved
                 },
                 scope: tenant
               )
               |> Ash.create()

      assert sheet!(tenant, org, @emp1, ~D[2026-09-01], ~D[2026-09-30]).status == :draft
    end
  end

  # ── t6: same-org ───────────────────────────────────────────────────────────

  describe "t6 — same-org" do
    test "a foreign cost object is refused", %{org: org, admin: _admin, tenant: tenant} do
      foreign_org = Ash.UUID.generate()
      foreign = cost_object!(admin_scope(foreign_org), foreign_org, "foreign")
      sheet = sheet!(tenant, org, @emp1, ~D[2026-09-01], ~D[2026-09-30])

      assert {:error, %Ash.Error.Invalid{} = err} =
               entry_attrs(tenant, org, sheet, foreign, ~D[2026-09-02], 60)
               |> then(&Ash.create/1)

      assert Exception.message(err) =~ "cross-org"
      assert entries(org, sheet.id) == []
    end

    test "an entry cannot join a sheet from another org", %{
      org: org,
      admin: admin,
      tenant: tenant
    } do
      foreign_org = Ash.UUID.generate()
      foreign_sheet = sheet!(admin_scope(foreign_org), foreign_org, @emp9, ~D[2026-09-01], ~D[2026-09-30])
      chip = cost_object!(admin, org, "riscv64")

      assert {:error, %Ash.Error.Invalid{}} =
               entry_attrs(tenant, org, foreign_sheet, chip, ~D[2026-09-02], 60)
               |> then(&Ash.create/1)

      assert entries(org, foreign_sheet.id) == []
    end
  end

  # ── t7: DB finality ────────────────────────────────────────────────────────

  describe "t7 — DB finality" do
    test "an approved sheet can never be rewritten", %{
      org: org,
      admin: admin,
      tenant: tenant
    } do
      chip = cost_object!(admin, org, "riscv64")
      sheet = sheet!(tenant, org, @emp1, ~D[2026-09-01], ~D[2026-09-30])
      _ = entry!(tenant, org, sheet, chip, ~D[2026-09-02], 480)
      {:ok, submitted} = submit(sheet, tenant)
      {:ok, approved} = approve(submitted, admin)

      assert {:error, %Postgrex.Error{postgres: %{message: message}}} =
               @repo.query(
                 "UPDATE wts_timesheet SET wts_status = 'draft' WHERE wts_id = $1::text::uuid",
                 [approved.id]
               )

      assert message =~ "final"

      # The identity columns are immutable on the way through the lifecycle:
      # a legal draft→submitted update that also changes the employee is refused.
      draft = sheet!(tenant, org, @emp2, ~D[2026-09-01], ~D[2026-09-30])

      assert {:error, %Postgrex.Error{postgres: %{message: identity_message}}} =
               @repo.query(
                 "UPDATE wts_timesheet SET wts_status = 'submitted', wts_employee_id = '#{@emp1}' WHERE wts_id = $1::text::uuid",
                 [draft.id]
               )

      assert identity_message =~ "immutable"
      assert reload(draft).status == :draft
      assert reload(draft).employee_id == @emp2
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

  defp entry_attrs(scope, org, sheet, cost_object, day, minutes) do
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
  end

  defp entry!(scope, org, sheet, cost_object, day, minutes) do
    entry_attrs(scope, org, sheet, cost_object, day, minutes) |> Ash.create!()
  end

  defp submit(sheet, scope) do
    sheet |> Ash.Changeset.for_update(:submit, %{}, scope: scope) |> Ash.update()
  end

  defp approve(sheet, scope) do
    sheet |> Ash.Changeset.for_update(:approve, %{}, scope: scope) |> Ash.update()
  end

  defp reload(sheet), do: Ash.get!(Timesheet, sheet.id, authorize?: false)

  defp entries(org, sheet_id) do
    TimesheetEntry
    |> Ash.Query.filter(org_id == ^org and timesheet_id == ^sheet_id)
    |> Ash.read!(authorize?: false)
  end

  defp all_sheets(org) do
    Timesheet
    |> Ash.Query.filter(org_id == ^org)
    |> Ash.read!(authorize?: false)
  end
end
