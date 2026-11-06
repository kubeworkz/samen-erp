defmodule Samen.Web.CloseDashboardTest do
  @moduledoc """
  WS-ACCT Phase 12 — the monthly close dashboard.

  The page renders the CURRENT cycle's honest board: the ten phases with their
  role assignments, the anchored Work task beside each governed sign-off, and a
  discrepancy where the two disagree. Selection is proved by an in-progress
  close outranking a NEWER, empty period.

  The honesty leg signs the whole run BEFORE its Work tasks exist, then seeds
  the tasks. Every task is open, so the board must drop all ten phases back to
  open and name the disagreement — a dashboard that kept `done_at`'s 100% would
  be the certificate ADR-054 D7 refuses. (The reopen-after-sign-off path is
  covered end to end by `samenerp/test/close_walkthrough_test.exs`.)
  """

  use Samen.WebTest.DataCase, async: false

  alias Samen.Scopes.Finance.{CloseChecklist, ClosePhases}
  alias Samen.Web.Finance.CloseDashboard
  alias Samen.Web.Finance.CloseDashboard.Live
  alias Samen.Web.Mount
  alias Samen.Web.Plane

  alias Samen.WebTest.Erp.{CloseRun, FiscalPeriod}
  alias Samen.WebTest.Repo
  alias Samen.WebTest.Work.Task

  defp admin_scope(org_id) do
    %Samen.Scope{
      actor: %{id: "u:#{org_id}", org_id: org_id, role: :admin, kind: :tenant, plane: :tenant}
    }
  end

  defp mount(_org_id, opts \\ []) do
    labels =
      %{close_path: "/close", erp_path: "/erp"}
      |> then(fn labels ->
        if Keyword.get(opts, :work, true) do
          Map.put(labels, :work_namespace, Samen.WebTest.Work)
        else
          labels
        end
      end)

    Mount.new(:erp, Samen.WebTest.Erp, Repo, plane: Plane.tenant(), labels: labels)
  end

  defp seed_period!(org_id, year, month) do
    FiscalPeriod
    |> Ash.Changeset.for_create(
      :create,
      %{org_id: org_id, year: year, month: month},
      scope: admin_scope(org_id)
    )
    |> Ash.create!()
  end

  defp start_run!(org_id, period) do
    CloseRun
    |> Ash.Changeset.for_create(
      :start,
      %{org_id: org_id, period_id: period.id},
      scope: admin_scope(org_id)
    )
    |> Ash.create!()
  end

  defp sign!(run, key, org_id) do
    run
    |> Ash.Changeset.for_update(:complete_phase, %{phase: key}, scope: admin_scope(org_id))
    |> Ash.update!()
  end

  defp finish!(run, org_id) do
    run
    |> Ash.Changeset.for_update(:finish, %{}, scope: admin_scope(org_id))
    |> Ash.update!()
  end

  describe "cycle selection" do
    test "an in-progress close outranks a newer, empty period" do
      org_id = Ash.UUID.generate()
      period = seed_period!(org_id, 2026, 10)
      run = start_run!(org_id, period)
      _november = seed_period!(org_id, 2026, 11)

      assert {:ok, state} = CloseDashboard.load(mount(org_id), org_id)
      assert state.period.id == period.id
      assert state.run.id == run.id
      assert state.report.completeness.total == 10
    end

    test "with no run, the newest period is named honestly" do
      org_id = Ash.UUID.generate()
      _october = seed_period!(org_id, 2026, 10)
      november = seed_period!(org_id, 2026, 11)

      assert {:ok, state} = CloseDashboard.load(mount(org_id), org_id)
      assert state.run == nil
      assert state.report == nil
      assert state.period.id == november.id
    end
  end

  describe "the page" do
    test "names the current period and its honest no-run state" do
      org_id = Ash.UUID.generate()
      _period = seed_period!(org_id, 2026, 10)

      html = mount_smoke(Live, mount(org_id), %{"org" => org_id})

      assert html =~ ~s(id="close-dashboard")
      assert html =~ "October 2026"
      assert html =~ "No close run has been started for October 2026."
      assert html =~ ~s(href="/close?org=#{org_id}" class="on")
      refute html =~ "vt_"
    end

    test "renders each phase with its roles, sign-off, Work task, and derived status" do
      org_id = Ash.UUID.generate()
      period = seed_period!(org_id, 2026, 10)
      run = start_run!(org_id, period)
      tasks = CloseChecklist.seed!(run, task: Task)

      CloseChecklist.complete!(Map.fetch!(tasks, "pre_close"))
      run = sign!(run, "pre_close", org_id)
      assert run.status == :in_progress

      html = mount_smoke(Live, mount(org_id), %{"org" => org_id})

      assert html =~ ~s(id="close-dashboard-period")
      assert html =~ "October 2026"
      assert html =~ "close run in_progress"
      assert html =~ "10% complete"
      assert html =~ "1 of 10 phases signed"
      assert html =~ "1/10 Work tasks completed"
      assert html =~ "9 open"

      assert html =~ ~s(id="close-phase-pre_close")
      assert html =~ "Pre-Close"
      assert html =~ "Readiness confirmation"
      assert html =~ "Controller"
      assert html =~ "AP Clerk"
      assert html =~ ~s(id="close-phase-status-pre_close" data-status="done")

      for key <- ClosePhases.keys() -- ["pre_close"] do
        assert html =~ ~s(id="close-phase-status-#{key}" data-status="open")
      end

      refute html =~ "vt_"
    end

    test "without a Work namespace the page says task state is not read" do
      org_id = Ash.UUID.generate()
      period = seed_period!(org_id, 2026, 10)
      _run = start_run!(org_id, period)

      assert {:ok, state} = CloseDashboard.load(mount(org_id, work: false), org_id)
      refute state.task_wired?
      assert Enum.all?(state.report.phases, &is_nil(&1.task))

      html = mount_smoke(Live, mount(org_id, work: false), %{"org" => org_id})

      assert html =~ ~s(id="close-dashboard-work-unwired")
      assert html =~ "not read"
      refute html =~ "Work tasks completed"
    end

    test "an org without Finance mounted gets the honest unavailable card" do
      org_id = Ash.UUID.generate()
      mount = Mount.new(:crm, Samen.WebTest.Crm, Repo, plane: Plane.tenant(), labels: %{})

      assert {:error, :finance_not_mounted} = CloseDashboard.load(mount, org_id)

      html = mount_smoke(Live, mount, %{"org" => org_id})
      assert html =~ ~s(id="close-dashboard-unavailable")
      assert html =~ "no Finance mount"
    end
  end

  describe "honesty" do
    test "a phase signed before its Work task existed is not reported done" do
      org_id = Ash.UUID.generate()
      period = seed_period!(org_id, 2026, 10)
      run = start_run!(org_id, period)

      run =
        Enum.reduce(ClosePhases.keys(), run, fn key, run ->
          sign!(run, key, org_id)
        end)

      run = finish!(run, org_id)
      assert run.status == :completed

      # No anchored tasks yet: the Phase-3 view trusts the governed sign-off.
      html = mount_smoke(Live, mount(org_id), %{"org" => org_id})
      assert html =~ "100% complete"
      assert html =~ "10 of 10 phases signed"
      refute html =~ ~s(id="close-dashboard-discrepancies")

      # The operational facts arrive AFTER the sign-off (a run started before
      # Phase 12, or a host that wired Work later). Every task is open, so NO
      # phase may be reported done — the run stays completed, the board does not.
      CloseChecklist.seed!(run, task: Task)

      html = mount_smoke(Live, mount(org_id), %{"org" => org_id})

      assert html =~ ~s(id="close-dashboard-discrepancies")
      assert html =~ "financial_statements"
      assert html =~ "signed off but its Work task is still open"
      assert html =~ ~s(id="close-phase-status-financial_statements" data-status="open")
      assert html =~ "0 of 10 phases signed"
      assert html =~ "0/10 Work tasks completed"
      assert html =~ "10 open"
      refute html =~ "100% complete"
    end
  end
end
