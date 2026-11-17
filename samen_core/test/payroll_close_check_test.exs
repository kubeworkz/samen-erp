defmodule Samen.PayrollCloseCheckTest do
  @moduledoc """
  The close-run precondition for imported payroll: the read is honest and
  bounded, a named hold is attributable, and the kernel refuses to finish the
  run while payroll is unresolved.
  """

  use ExUnit.Case, async: false

  alias Samen.Scopes.Finance.{ClosePhases, PayrollCloseCheck}

  alias SamenCore.Support.FinanceFixture.{
    Account,
    CloseRun,
    CostObject,
    FiscalPeriod,
    JournalEntry,
    LabourAllocation,
    PayrollImport
  }

  alias SamenCore.Support.WorkFixture.{Timesheet, TimesheetEntry}

  @repo SamenCore.TestRepo
  @employee "00000000-0000-4000-8000-000000000001"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(@repo)
    org = Ash.UUID.generate()
    admin = admin_scope(org)
    member = member_scope(org)
    expense = account!(admin, org, "6000", :expense, :debit)
    payable = account!(admin, org, "2100", :liability, :credit)
    period = period!(admin, org, 2026, 9)

    {:ok,
     org: org, admin: admin, member: member, expense: expense, payable: payable, period: period}
  end

  describe "the payroll close check" do
    test "an empty payroll inbox is clear", %{org: org, period: period} do
      report = report(org, period)

      assert report.status == :clear
      assert report.clear?
      refute report.blocking?
      assert report.counts.total == 0
    end

    test "reads only the caller's org", %{org: org, period: period} do
      foreign_org = Ash.UUID.generate()
      foreign_admin = admin_scope(foreign_org)
      foreign_expense = account!(foreign_admin, foreign_org, "6000", :expense, :debit)
      foreign_payable = account!(foreign_admin, foreign_org, "2100", :liability, :credit)

      foreign_entry =
        entry!(
          foreign_admin,
          foreign_org,
          foreign_expense,
          foreign_payable,
          ~D[2026-09-30],
          :draft
        )

      _foreign_import = import!(foreign_admin, foreign_org, foreign_entry)

      report = report(org, period)

      assert report.clear?
      assert report.counts.total == 0
    end

    test "an unposted imported draft blocks the close", %{
      org: org,
      admin: admin,
      period: period,
      expense: expense,
      payable: payable
    } do
      entry = entry!(admin, org, expense, payable, ~D[2026-09-30], :draft)
      _import = import!(admin, org, entry)

      report = report(org, period)

      assert report.status == :blocked
      assert report.blocking?
      refute report.clear?
      assert [row] = report.entries
      assert row.disposition == :draft
      refute row.accepted?
      assert [unresolved] = report.unresolved
      assert unresolved.provider == "acme_payroll"
      assert report.counts.draft == 1
    end

    test "a posted imported entry is clear", %{
      org: org,
      admin: admin,
      period: period,
      expense: expense,
      payable: payable
    } do
      entry = entry!(admin, org, expense, payable, ~D[2026-09-30], :posted)
      _import = import!(admin, org, entry)

      report = report(org, period)

      assert report.clear?
      assert [row] = report.entries
      assert row.disposition == :posted
      assert report.counts.posted == 1
    end

    test "an explicitly voided imported entry is clear", %{
      org: org,
      admin: admin,
      period: period,
      expense: expense,
      payable: payable
    } do
      entry = entry!(admin, org, expense, payable, ~D[2026-09-30], :void)
      _import = import!(admin, org, entry)

      report = report(org, period)

      assert report.clear?
      assert [row] = report.entries
      assert row.disposition == :voided
      assert report.counts.voided == 1
    end

    test "an unresolved conflict blocks even when the linked entry is posted", %{
      org: org,
      admin: admin,
      period: period,
      expense: expense,
      payable: payable
    } do
      entry = entry!(admin, org, expense, payable, ~D[2026-09-30], :posted)
      _imported = import!(admin, org, entry, %{external_id: "run-conflict"})

      _conflict =
        import!(admin, org, entry, %{
          external_id: "run-conflict",
          line_set_hash: String.duplicate("b", 64),
          status: :conflict
        })

      report = report(org, period)

      assert report.blocking?
      assert report.counts.posted == 1
      assert report.counts.conflict == 1
      assert [conflict] = report.unresolved
      assert conflict.disposition == :conflict
    end

    test "a named hold clears a draft and remains visible with its exception", %{
      org: org,
      admin: admin,
      period: period,
      expense: expense,
      payable: payable
    } do
      entry = entry!(admin, org, expense, payable, ~D[2026-09-30], :draft)
      import = import!(admin, org, entry)

      held =
        import
        |> Ash.Changeset.for_update(
          :hold,
          %{exception: "Payment run arrives after the close; controller approved the hold"},
          scope: admin
        )
        |> Ash.update!()

      assert held.exception ==
               "Payment run arrives after the close; controller approved the hold"

      assert held.held_at != nil
      assert held.held_by == admin.actor.id

      report = report(org, period)

      assert report.clear?
      assert [row] = report.entries
      assert row.disposition == :held
      assert row.held?
      assert [held_row] = report.held
      assert held_row.exception == held.exception
    end

    test "a hold needs an admin, a named exception, and is final", %{
      org: org,
      admin: admin,
      member: member,
      period: period,
      expense: expense,
      payable: payable
    } do
      entry = entry!(admin, org, expense, payable, ~D[2026-09-30], :draft)
      import = import!(admin, org, entry)

      assert {:error, %Ash.Error.Forbidden{}} = hold(import, member, "member hold")
      assert {:error, _} = hold(import, admin, "   ")
      assert {:error, _} = hold(import, admin, "controller@example.com")

      held = hold!(import, admin, "Approved by the controller")

      assert {:error, _} = hold(held, admin, "A second exception")

      assert Ash.get!(PayrollImport, held.id, authorize?: false).exception ==
               "Approved by the controller"

      report = report(org, period)
      assert report.clear?
    end

    test "another month's payroll does not leak into this period", %{
      org: org,
      admin: admin,
      expense: expense,
      payable: payable,
      period: september
    } do
      october = period!(admin, org, 2026, 10)
      entry = entry!(admin, org, expense, payable, ~D[2026-10-01], :draft)
      _import = import!(admin, org, entry)

      report = report(org, october)
      assert report.blocking?
      assert report.counts.total == 1

      assert report(org, september).clear?
    end

    test "an unwired or unreadable check fails closed", %{org: org, period: period} do
      assert %{status: :unavailable, blocking?: true, clear?: false} =
               PayrollCloseCheck.report(org, period, import_module: nil)
    end

    test "a drifted labour allocation is visible and blocks the close", %{
      org: org,
      admin: admin,
      member: member,
      period: period,
      expense: expense,
      payable: payable
    } do
      _allocation = labour_allocation!(admin, member, org, expense)

      entry = entry!(admin, org, expense, payable, ~D[2026-09-30], :posted)
      _import = import!(admin, org, entry, %{total_cents: 125_000})

      report = report(org, period, labour_allocation_module: LabourAllocation)

      assert report.status == :blocked
      assert report.blocking?
      refute report.clear?
      assert report.reason == :labour_allocation_drift

      assert %{status: :drift, counts: %{total: 1, reconciled: 0, drift: 1}} =
               report.labour_tie_out

      assert [drift] = report.labour_tie_out.drift
      assert drift.source_account_code == "6000"
      assert drift.allocated_cents == 100_000
      assert drift.register_debit_cents == 125_000
      assert drift.variance_cents == 25_000

      run = signed_run!(admin, org, period)

      assert {:error, error} = finish(run, admin)
      assert inspect(error) =~ "labour allocation header"
      assert inspect(error) =~ "25000"

      assert Ash.get!(CloseRun, run.id, authorize?: false).status == :in_progress
    end
  end

  describe "the close-run finish guard" do
    test "refuses an unposted payroll draft, then accepts the same run once posted", %{
      org: org,
      admin: admin,
      period: period,
      expense: expense,
      payable: payable
    } do
      entry = entry!(admin, org, expense, payable, ~D[2026-09-30], :draft)
      _import = import!(admin, org, entry)
      run = signed_run!(admin, org, period)

      assert {:error, error} = finish(run, admin)
      assert inspect(error) =~ "imported payroll entry is unresolved"
      assert inspect(error) =~ "acme_payroll"
      assert inspect(error) =~ "unposted draft"

      entry
      |> Ash.Changeset.for_update(:post, %{}, scope: admin)
      |> Ash.update!()

      assert {:ok, completed} = finish(run, admin)
      assert completed.status == :completed
    end

    test "accepts a named hold instead of a posting", %{
      org: org,
      admin: admin,
      period: period,
      expense: expense,
      payable: payable
    } do
      entry = entry!(admin, org, expense, payable, ~D[2026-09-30], :draft)
      import = import!(admin, org, entry)
      _held = hold!(import, admin, "Approved close exception")

      run = signed_run!(admin, org, period)

      assert {:ok, completed} = finish(run, admin)
      assert completed.status == :completed
    end
  end

  defp report(org, period, opts \\ []) do
    PayrollCloseCheck.report(
      org,
      period,
      Keyword.merge([import_module: PayrollImport, authorize?: false], opts)
    )
  end

  defp hold(import, scope, exception) do
    import
    |> Ash.Changeset.for_update(:hold, %{exception: exception}, scope: scope)
    |> Ash.update()
  end

  defp hold!(import, scope, exception), do: hold(import, scope, exception) |> elem(1)

  defp labour_allocation!(admin, member, org, expense) do
    target = account!(admin, org, "1300", :asset, :debit)
    first = cost_object!(admin, org, "tie-a")
    second = cost_object!(admin, org, "tie-b")

    sheet =
      Timesheet
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: org,
          employee_id: @employee,
          period_start: ~D[2026-09-01],
          period_end: ~D[2026-09-30]
        },
        scope: member
      )
      |> Ash.create!()

    Enum.each([{first, ~D[2026-09-02], 480}, {second, ~D[2026-09-03], 240}], fn {cost_object, day,
                                                                                 minutes} ->
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
        scope: member
      )
      |> Ash.create!()
    end)

    {:ok, submitted} =
      sheet |> Ash.Changeset.for_update(:submit, %{}, scope: member) |> Ash.update()

    {:ok, _approved} =
      submitted |> Ash.Changeset.for_update(:approve, %{}, scope: admin) |> Ash.update()

    LabourAllocation
    |> Ash.Changeset.for_create(
      :draft,
      %{
        org_id: org,
        period_start: ~D[2026-09-01],
        period_end: ~D[2026-09-30],
        total_cents: 100_000,
        source_account_id: expense.id,
        target_account_id: target.id
      },
      scope: admin
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

  defp finish(run, scope) do
    run
    |> Ash.Changeset.for_update(:finish, %{}, scope: scope)
    |> Ash.update()
  end

  defp signed_run!(admin, org, period) do
    run = start_run!(admin, org, period.id)

    Enum.reduce(ClosePhases.keys(), run, fn key, run ->
      run
      |> review!(reviewer_scope(org), key)
      |> then(fn reviewed ->
        reviewed
        |> Ash.Changeset.for_update(:complete_phase, %{phase: key}, scope: admin)
        |> Ash.update!()
      end)
    end)
  end

  defp start_run!(scope, org, period_id) do
    CloseRun
    |> Ash.Changeset.for_create(:start, %{org_id: org, period_id: period_id}, scope: scope)
    |> Ash.create!()
  end

  defp review!(run, scope, key) do
    run
    |> Ash.Changeset.for_update(
      :review_phase,
      %{phase: key, evidence_files: [Ash.UUID.generate()]},
      scope: scope
    )
    |> Ash.update!()
  end

  defp entry!(scope, org, expense, payable, date, status) do
    entry =
      JournalEntry
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: org,
          entry_date: date,
          memo: "Payroll register",
          lines: [
            %{account_id: expense.id, debit_cents: 125_000},
            %{account_id: payable.id, credit_cents: 125_000}
          ]
        },
        scope: scope
      )
      |> Ash.create!()

    case status do
      :draft ->
        entry

      :posted ->
        entry
        |> Ash.Changeset.for_update(:post, %{}, scope: scope)
        |> Ash.update!()

      :void ->
        posted =
          entry
          |> Ash.Changeset.for_update(:post, %{}, scope: scope)
          |> Ash.update!()

        posted
        |> Ash.Changeset.for_update(:void, %{}, scope: scope)
        |> Ash.update!()
    end
  end

  defp import!(scope, org, entry, overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          org_id: org,
          provider: "acme_payroll",
          external_id: "run-#{Ash.UUID.generate()}",
          line_set_hash: String.duplicate("a", 64),
          total_cents: 125_000,
          entry_date: entry.entry_date,
          imported_at: DateTime.utc_now() |> DateTime.truncate(:second),
          imported_by: "u:payroll-importer",
          status: :imported,
          entry_id: entry.id
        },
        overrides
      )

    PayrollImport
    |> Ash.Changeset.for_create(:create, attrs, scope: scope)
    |> Ash.create!()
  end

  defp period!(scope, org, year, month) do
    FiscalPeriod
    |> Ash.Changeset.for_create(:create, %{org_id: org, year: year, month: month}, scope: scope)
    |> Ash.create!()
  end

  defp account!(scope, org, code, kind, side) do
    Account
    |> Ash.Changeset.for_create(
      :create,
      %{org_id: org, code: code, name: "Account #{code}", kind: kind, normal_side: side},
      scope: scope
    )
    |> Ash.create!()
  end

  defp admin_scope(org) do
    %Samen.Scope{
      actor: %{id: "u:#{org}", org_id: org, role: :admin, kind: :tenant, plane: :tenant}
    }
  end

  defp member_scope(org) do
    %Samen.Scope{
      actor: %{id: "member:#{org}", org_id: org, role: :member, kind: :tenant, plane: :tenant}
    }
  end

  defp reviewer_scope(org) do
    %Samen.Scope{
      actor: %{
        id: "reviewer:#{org}",
        org_id: org,
        role: :admin,
        kind: :tenant,
        plane: :tenant
      }
    }
  end
end
