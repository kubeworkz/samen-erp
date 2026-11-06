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

  defp socket(mount, params) do
    session = mount_session(mount)
    {:ok, socket} = Live.mount(params, session, %Phoenix.LiveView.Socket{})
    {:noreply, socket} = Live.handle_params(params, "http://localhost/smoke", socket)
    socket
  end

  defp dispatch(socket, event, params \\ %{}) do
    {:noreply, socket} = Live.handle_event(event, params, socket)
    socket
  end

  defp phase_row(html, key) do
    html
    |> String.split(~s(id="close-phase-#{key}"))
    |> List.last()
    |> String.split("<tr")
    |> List.first()
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

    test "a completed close yields to the next open period so it can be started" do
      org_id = Ash.UUID.generate()
      october = seed_period!(org_id, 2026, 10)
      run = start_run!(org_id, october)
      run = Enum.reduce(ClosePhases.keys(), run, fn key, run -> sign!(run, key, org_id) end)
      finish!(run, org_id)
      november = seed_period!(org_id, 2026, 11)

      assert {:ok, state} = CloseDashboard.load(mount(org_id), org_id)
      assert state.period.id == november.id
      assert state.run == nil
      assert state.report == nil
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

  describe "governed actions" do
    test "starts the close from the page through the host action" do
      org_id = Ash.UUID.generate()
      period = seed_period!(org_id, 2026, 10)
      socket = socket(mount(org_id), %{"org" => org_id})

      assert render_html(Live, socket.assigns) =~ ~s(id="close-start-run")

      socket = dispatch(socket, "start_run")
      html = render_html(Live, socket.assigns)

      assert html =~ ~s(id="close-action-notice")
      assert html =~ "Close started for October 2026."
      assert html =~ "close run in_progress"
      assert html =~ ~s(id="close-phase-pre_close")
      refute html =~ ~s(id="close-start-run")

      assert [run] = Ash.read!(CloseRun, scope: admin_scope(org_id))
      assert run.period_id == period.id
      assert run.status == :in_progress
    end

    test "signs a phase off and the board counts it" do
      org_id = Ash.UUID.generate()
      period = seed_period!(org_id, 2026, 10)
      run = start_run!(org_id, period)
      socket = socket(mount(org_id), %{"org" => org_id})

      socket = dispatch(socket, "complete_phase", %{"phase" => "pre_close"})
      html = render_html(Live, socket.assigns)

      assert html =~ "Signed off Pre-Close."
      assert html =~ ~s(id="close-phase-status-pre_close" data-status="done")

      run = Ash.get!(CloseRun, run.id, authorize?: false)
      phase = Enum.find(run.phases, &(&1["key"] == "pre_close"))
      assert phase["done_at"] != nil
      page_actor = Samen.Web.TenantRole.attributed_admin_scope(mount(org_id), org_id).actor.id
      assert phase["done_by"] == page_actor
      assert phase_row(html, "pre_close") =~ "the workspace"
    end

    test "shows the governed refusal from a completed run" do
      org_id = Ash.UUID.generate()
      period = seed_period!(org_id, 2026, 10)
      run = start_run!(org_id, period)
      run = Enum.reduce(ClosePhases.keys(), run, fn key, run -> sign!(run, key, org_id) end)
      finish!(run, org_id)

      socket = socket(mount(org_id), %{"org" => org_id})
      socket = dispatch(socket, "complete_phase", %{"phase" => "pre_close"})
      html = render_html(Live, socket.assigns)

      assert html =~ ~s(id="close-action-error")
      assert html =~ "COMPLETED"
      refute html =~ "Signed off Pre-Close."
    end

    test "hides sign-off until the phase's Work task is complete" do
      org_id = Ash.UUID.generate()
      period = seed_period!(org_id, 2026, 10)
      run = start_run!(org_id, period)
      tasks = CloseChecklist.seed!(run, task: Task)

      socket = socket(mount(org_id), %{"org" => org_id})
      html = render_html(Live, socket.assigns)
      pre_close = phase_row(html, "pre_close")

      assert pre_close =~ "Complete the Work task first"
      refute pre_close =~ ~s(id="close-sign-pre_close")

      CloseChecklist.complete!(Map.fetch!(tasks, "pre_close"))

      socket = socket(mount(org_id), %{"org" => org_id})
      html = render_html(Live, socket.assigns)
      pre_close = phase_row(html, "pre_close")

      assert pre_close =~ ~s(id="close-sign-pre_close")
      refute pre_close =~ "Complete the Work task first"
    end
  end
end
