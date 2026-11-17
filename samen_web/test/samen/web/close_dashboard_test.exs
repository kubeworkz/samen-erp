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

  alias Samen.WebTest.Docs.Doc

  alias Samen.WebTest.Erp.{
    Account,
    CloseRun,
    FiscalPeriod,
    JournalEntry,
    PayrollImport,
    PayrollSettlement
  }

  alias Samen.WebTest.Repo
  alias Samen.WebTest.Work.Task

  defp admin_scope(org_id) do
    %Samen.Scope{
      actor: %{id: "u:#{org_id}", org_id: org_id, role: :admin, kind: :tenant, plane: :tenant}
    }
  end

  defp mount(_org_id, opts \\ []) do
    labels =
      %{close_path: "/close", erp_path: "/erp", pages_path: "/pages"}
      |> then(fn labels ->
        if Keyword.get(opts, :work, true) do
          Map.put(labels, :work_namespace, Samen.WebTest.Work)
        else
          labels
        end
      end)
      |> then(fn labels ->
        if Keyword.get(opts, :docs, true) do
          Map.put(labels, :docs_namespace, Samen.WebTest.Docs)
        else
          labels
        end
      end)

    Mount.new(:erp, Samen.WebTest.Erp, Repo, plane: Plane.tenant(), labels: labels)
  end

  defp seed_doc!(org_id, title) do
    Doc
    |> Ash.Changeset.for_create(
      :create,
      %{org_id: org_id, title: title, body: "Close evidence"},
      scope: admin_scope(org_id)
    )
    |> Ash.create!()
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

  defp reviewer_scope(org_id) do
    %Samen.Scope{
      actor: %{
        id: "reviewer:#{org_id}",
        org_id: org_id,
        role: :admin,
        kind: :tenant,
        plane: :tenant
      }
    }
  end

  defp review!(run, key, org_id) do
    run
    |> Ash.Changeset.for_update(
      :review_phase,
      %{phase: key, evidence_files: [Ash.UUID.generate()]},
      scope: reviewer_scope(org_id)
    )
    |> Ash.update!()
  end

  defp sign!(run, key, org_id) do
    run
    |> review!(key, org_id)
    |> Ash.Changeset.for_update(:complete_phase, %{phase: key}, scope: admin_scope(org_id))
    |> Ash.update!()
  end

  defp finish!(run, org_id) do
    run
    |> Ash.Changeset.for_update(:finish, %{}, scope: admin_scope(org_id))
    |> Ash.update!()
  end

  defp sign_all!(run, org_id) do
    Enum.reduce(ClosePhases.keys(), run, fn key, run -> sign!(run, key, org_id) end)
  end

  defp payroll_entry!(org_id, status) do
    expense = account!(org_id, "6000", :expense, :debit)
    payable = account!(org_id, "2100", :liability, :credit)

    entry =
      JournalEntry
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: org_id,
          entry_date: ~D[2026-10-31],
          memo: "October payroll",
          lines: [
            %{account_id: expense.id, debit_cents: 125_000},
            %{account_id: payable.id, credit_cents: 125_000}
          ]
        },
        scope: admin_scope(org_id)
      )
      |> Ash.create!()

    case status do
      :draft ->
        entry

      :posted ->
        entry
        |> Ash.Changeset.for_update(:post, %{}, scope: admin_scope(org_id))
        |> Ash.update!()
    end
  end

  defp payroll_import!(org_id, entry) do
    PayrollImport
    |> Ash.Changeset.for_create(
      :create,
      %{
        org_id: org_id,
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
      scope: admin_scope(org_id)
    )
    |> Ash.create!()
  end

  defp hold_payroll!(import, org_id, exception) do
    import
    |> Ash.Changeset.for_update(:hold, %{exception: exception}, scope: admin_scope(org_id))
    |> Ash.update!()
  end

  defp account!(org_id, code, kind, side) do
    Account
    |> Ash.Changeset.for_create(
      :create,
      %{org_id: org_id, code: code, name: "Account #{code}", kind: kind, normal_side: side},
      scope: admin_scope(org_id)
    )
    |> Ash.create!()
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

  defp period_card(html) do
    html
    |> String.split(~s(id="close-dashboard-period"))
    |> List.last()
    |> String.split(~s(id="close-dashboard-progress"))
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

    test "shows an unposted payroll import as a close blocker" do
      org_id = Ash.UUID.generate()
      period = seed_period!(org_id, 2026, 10)
      run = start_run!(org_id, period)
      _run = sign_all!(run, org_id)
      entry = payroll_entry!(org_id, :draft)
      _import = payroll_import!(org_id, entry)

      html = mount_smoke(Live, mount(org_id), %{"org" => org_id})

      assert html =~ ~s(id="close-payroll-check" data-status="blocked")
      assert html =~ ~s(id="close-payroll-status" data-status="blocked")
      assert html =~ "acme_payroll"
      assert html =~ "unposted draft"
      assert html =~ "The close is blocked until every imported payroll entry"
      refute html =~ ~s(id="close-finish-run")

      # A crafted event still reaches the kernel's finish guard.
      socket = socket(mount(org_id), %{"org" => org_id})
      socket = dispatch(socket, "finish_run")
      html = render_html(Live, socket.assigns)

      assert html =~ ~s(id="close-action-error")
      assert html =~ "imported payroll entry is unresolved"
      refute html =~ "Close completed"
      assert Ash.get!(CloseRun, run.id, authorize?: false).status == :in_progress
    end

    test "holds an unresolved payroll row from the page with actor attribution" do
      org_id = Ash.UUID.generate()
      period = seed_period!(org_id, 2026, 10)
      run = start_run!(org_id, period)
      _run = sign_all!(run, org_id)
      entry = payroll_entry!(org_id, :draft)
      import = payroll_import!(org_id, entry)

      socket = socket(mount(org_id), %{"org" => org_id})
      html = render_html(Live, socket.assigns)

      assert html =~ ~s(id="close-payroll-hold-form-#{import.id}")
      assert html =~ ~s(id="close-payroll-hold-#{import.id}")
      assert html =~ "Named exception (required)"
      refute html =~ ~s(id="close-payroll-held")

      socket =
        dispatch(socket, "hold_payroll", %{"import_id" => import.id, "exception" => "  "})

      html = render_html(Live, socket.assigns)
      assert html =~ "exception is required"
      assert Ash.get!(PayrollImport, import.id, authorize?: false).held_at == nil

      exception = "Payment run arrives after close; controller approved"

      socket =
        dispatch(socket, "hold_payroll", %{
          "import_id" => import.id,
          "exception" => exception
        })

      html = render_html(Live, socket.assigns)
      assert html =~ "Held acme_payroll/#{import.external_id} with a named exception."
      assert html =~ ~s(id="close-payroll-check" data-status="clear")
      assert html =~ ~s(id="close-payroll-held")
      assert html =~ exception
      assert html =~ "held by the workspace"
      assert html =~ ~s(id="close-finish-run")

      held = Ash.get!(PayrollImport, import.id, authorize?: false)
      page_actor = Samen.Web.TenantRole.attributed_admin_scope(mount(org_id), org_id).actor.id

      assert held.exception == exception
      assert held.held_by == page_actor
      assert held.held_at != nil
    end

    test "offers the payroll hold only to an admin and refuses a crafted non-admin event" do
      org_id = Ash.UUID.generate()
      period = seed_period!(org_id, 2026, 10)
      run = start_run!(org_id, period)
      _run = sign_all!(run, org_id)
      entry = payroll_entry!(org_id, :draft)
      import = payroll_import!(org_id, entry)
      socket = socket(mount(org_id), %{"org" => org_id})

      html = render_html(Live, Map.put(socket.assigns, :can_admin?, false))
      refute html =~ ~s(id="close-payroll-hold-form-#{import.id}")
      refute html =~ "Named exception (required)"

      socket = %{socket | assigns: Map.put(socket.assigns, :can_admin?, false)}

      _socket =
        dispatch(socket, "hold_payroll", %{
          "import_id" => import.id,
          "exception" => "A member should not be able to hold this"
        })

      assert Ash.get!(PayrollImport, import.id, authorize?: false).held_at == nil
    end

    test "shows a named payroll hold and permits the close" do
      org_id = Ash.UUID.generate()
      period = seed_period!(org_id, 2026, 10)
      run = start_run!(org_id, period)
      _run = sign_all!(run, org_id)
      entry = payroll_entry!(org_id, :draft)
      import = payroll_import!(org_id, entry)
      exception = "Payment run arrives after close; controller approved"
      _held = hold_payroll!(import, org_id, exception)

      html = mount_smoke(Live, mount(org_id), %{"org" => org_id})

      assert html =~ ~s(id="close-payroll-check" data-status="clear")
      assert html =~ ~s(id="close-payroll-held")
      assert html =~ exception
      assert html =~ ~s(id="close-finish-run")

      socket = socket(mount(org_id), %{"org" => org_id})
      socket = dispatch(socket, "finish_run")
      html = render_html(Live, socket.assigns)

      assert html =~ "Close completed for October 2026."
      assert html =~ "close run completed"
      assert Ash.get!(CloseRun, run.id, authorize?: false).status == :completed
    end
  end

  describe "payroll settlement surface" do
    test "prepares and posts a settlement and shows its tie-out status" do
      org_id = Ash.UUID.generate()
      _period = seed_period!(org_id, 2026, 10)
      entry = payroll_entry!(org_id, :posted)
      import = payroll_import!(org_id, entry)
      cash = account!(org_id, "1010", :asset, :debit)

      socket = socket(mount(org_id), %{"org" => org_id})
      html = render_html(Live, socket.assigns)

      assert html =~ ~s(id="close-payroll-settlements")
      assert html =~ ~s(id="close-payroll-settlement-#{import.id}")
      assert html =~ ~s(id="close-payroll-settlement-status-#{import.id}" data-status="unsettled")
      assert html =~ ~s(id="close-payroll-settlement-form-#{import.id}")
      assert html =~ "1010"
      refute html =~ ~s(id="close-payroll-settlement-post-#{import.id}")

      socket =
        dispatch(socket, "prepare_payroll_settlement", %{
          "import_id" => import.id,
          "cash_account_id" => cash.id,
          "settlement_date" => "2026-10-31",
          "reference" => "October payroll clearance"
        })

      html = render_html(Live, socket.assigns)

      assert html =~ "Prepared payroll settlement."
      assert html =~ ~s(id="close-payroll-settlement-status-#{import.id}" data-status="unposted")
      assert html =~ "draft · not posted"
      assert html =~ "1 entry"
      assert html =~ ~s(id="close-payroll-settlement-post-#{import.id}")
      assert html =~ "October payroll clearance"

      [row] = socket.assigns.state.settlements.rows
      settlement = row.settlement
      assert settlement.status == :draft
      assert settlement.total_cents == 125_000
      assert settlement.payment_count == 1

      socket =
        dispatch(socket, "post_payroll_settlement", %{"settlement_id" => settlement.id})

      html = render_html(Live, socket.assigns)

      assert html =~ "Posted payroll settlement."

      assert html =~
               ~s(id="close-payroll-settlement-status-#{import.id}" data-status="unreconciled")

      assert html =~ ~s(id="close-payroll-tie-out-#{import.id}" data-status="unreconciled")
      assert html =~ "posted · bank unreconciled"
      assert html =~ "Bank matching is not wired on this host."
      assert html =~ "$1250.00"
      assert html =~ "posted by the workspace"

      posted = Ash.get!(PayrollSettlement, settlement.id, authorize?: false)
      assert posted.status == :posted
      assert posted.posted_at != nil
    end

    test "names an unreadable payroll gate instead of implying there are no registers" do
      org_id = Ash.UUID.generate()
      socket = socket(mount(org_id), %{"org" => org_id})
      html = render_html(Live, socket.assigns)

      assert socket.assigns.state.payroll.status == :unavailable
      assert socket.assigns.state.settlements.error == :payroll_unavailable
      assert html =~ ~s(id="close-payroll-settlements-payroll-unavailable")
      refute html =~ ~s(id="close-payroll-settlements-empty")
    end

    test "offers prepare and post only to an admin and refuses a crafted non-admin event" do
      org_id = Ash.UUID.generate()
      _period = seed_period!(org_id, 2026, 10)
      entry = payroll_entry!(org_id, :posted)
      import = payroll_import!(org_id, entry)
      cash = account!(org_id, "1010", :asset, :debit)

      socket = socket(mount(org_id), %{"org" => org_id})
      html = render_html(Live, Map.put(socket.assigns, :can_admin?, false))

      refute html =~ ~s(id="close-payroll-settlement-form-#{import.id}")
      refute html =~ ~s(id="close-payroll-settlement-post-#{import.id}")
      assert html =~ "Admin required."

      socket = %{socket | assigns: Map.put(socket.assigns, :can_admin?, false)}

      _socket =
        dispatch(socket, "prepare_payroll_settlement", %{
          "import_id" => import.id,
          "cash_account_id" => cash.id,
          "settlement_date" => "2026-10-31"
        })

      assert Ash.read!(PayrollSettlement, authorize?: false) == []
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
      assert run.completed_by == admin_scope(org_id).actor.id

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

      page_actor = Samen.Web.TenantRole.attributed_admin_scope(mount(org_id), org_id).actor.id
      assert run.started_by == page_actor
      assert period_card(html) =~ "Started"
      assert period_card(html) =~ "by the workspace"
    end

    test "signs a reviewed phase off and the board counts it" do
      org_id = Ash.UUID.generate()
      period = seed_period!(org_id, 2026, 10)
      run = start_run!(org_id, period)
      run = review!(run, "pre_close", org_id)
      socket = socket(mount(org_id), %{"org" => org_id})

      socket = dispatch(socket, "complete_phase", %{"phase" => "pre_close"})
      html = render_html(Live, socket.assigns)

      assert html =~ "Signed off Pre-Close."
      assert html =~ ~s(id="close-phase-status-pre_close" data-status="done")

      run = Ash.get!(CloseRun, run.id, authorize?: false)
      phase = Enum.find(run.phases, &(&1["key"] == "pre_close"))
      assert phase["done_at"] != nil
      assert length(phase["evidence_files"]) == 1
      assert phase["reviewed_by"] == "reviewer:#{org_id}"
      page_actor = Samen.Web.TenantRole.attributed_admin_scope(mount(org_id), org_id).actor.id
      assert phase["done_by"] == page_actor
      assert phase_row(html, "pre_close") =~ "the workspace"
      assert phase_row(html, "pre_close") =~ "Unavailable document"
      [unresolved_id] = phase["evidence_files"]
      assert phase_row(html, "pre_close") =~ "not accessible"
      refute phase_row(html, "pre_close") =~ ~s(href="/pages/#{unresolved_id}")
      refute phase_row(html, "pre_close") =~ "/pages/trash"
    end

    test "records evidence and an independent review from the page" do
      org_id = Ash.UUID.generate()
      period = seed_period!(org_id, 2026, 10)
      run = start_run!(org_id, period)
      socket = socket(mount(org_id), %{"org" => org_id})

      socket =
        dispatch(socket, "review_phase", %{"phase" => "pre_close", "evidence_files" => " "})

      html = render_html(Live, socket.assigns)
      assert html =~ ~s(id="close-action-error")
      assert html =~ "at least one evidence file id"

      first = Ash.UUID.generate()
      second = Ash.UUID.generate()

      socket =
        dispatch(socket, "review_phase", %{
          "phase" => "pre_close",
          "evidence_files" => "#{first}, #{second}"
        })

      html = render_html(Live, socket.assigns)
      assert html =~ "Recorded evidence and reviewer sign-off for Pre-Close."

      run = Ash.get!(CloseRun, run.id, authorize?: false)
      phase = Enum.find(run.phases, &(&1["key"] == "pre_close"))
      page_actor = Samen.Web.TenantRole.attributed_admin_scope(mount(org_id), org_id).actor.id

      assert phase["evidence_files"] == [first, second]
      assert phase["reviewed_by"] == page_actor
      assert phase["reviewed_at"] != nil

      # The reviewer cannot also sign it off; the page does not offer the button.
      pre_close = phase_row(html, "pre_close")
      assert pre_close =~ "reviewed by you — a different admin must sign"
      refute pre_close =~ ~s(id="close-sign-pre_close")

      # A different admin can sign it off.
      run = sign!(run, "pre_close", org_id)
      phase = Enum.find(run.phases, &(&1["key"] == "pre_close"))
      assert phase["done_at"] != nil
    end

    test "offers mounted Docs as evidence and resolves stored ids to titles" do
      org_id = Ash.UUID.generate()
      alpha = seed_doc!(org_id, "October bank statement")
      beta = seed_doc!(org_id, "Payroll reconciliation")
      other = seed_doc!(Ash.UUID.generate(), "Other org document")
      period = seed_period!(org_id, 2026, 10)
      run = start_run!(org_id, period)
      socket = socket(mount(org_id), %{"org" => org_id})

      html = render_html(Live, socket.assigns)
      pre_close = phase_row(html, "pre_close")

      assert pre_close =~ ~s(id="close-evidence-picker-pre_close")
      assert pre_close =~ "October bank statement"
      assert pre_close =~ "Payroll reconciliation"
      assert pre_close =~ ~s(id="close-evidence-pre_close-#{alpha.id}")
      refute pre_close =~ "Other org document"

      socket =
        dispatch(socket, "review_phase", %{
          "phase" => "pre_close",
          "evidence_files" => [alpha.id, beta.id]
        })

      html = render_html(Live, socket.assigns)
      pre_close = phase_row(html, "pre_close")

      assert pre_close =~ "October bank statement"
      assert pre_close =~ "Payroll reconciliation"
      assert pre_close =~ ~s(href="/pages/#{alpha.id}?org=#{org_id}")
      assert pre_close =~ ~s(href="/pages/#{beta.id}?org=#{org_id}")

      assert {:ok, state} = CloseDashboard.load(mount(org_id), org_id)
      assert state.docs_wired?
      assert state.evidence_titles[alpha.id] == "October bank statement"
      assert MapSet.new(Enum.map(state.docs, & &1.id)) == MapSet.new([alpha.id, beta.id])
      refute Enum.any?(state.docs, &(&1.id == other.id))

      run = Ash.get!(CloseRun, run.id, authorize?: false)
      phase = Enum.find(run.phases, &(&1["key"] == "pre_close"))
      assert phase["evidence_files"] == [alpha.id, beta.id]
    end

    test "flags archived evidence and leaves it unlinked" do
      org_id = Ash.UUID.generate()
      archived = seed_doc!(org_id, "Archived bank statement")
      assert {:ok, _archived} = Samen.Archival.archive(archived, scope: admin_scope(org_id))
      period = seed_period!(org_id, 2026, 10)
      _run = start_run!(org_id, period)
      socket = socket(mount(org_id), %{"org" => org_id})

      # The picker lists live pages only, so an archived page cannot be newly selected.
      html = render_html(Live, socket.assigns)
      refute phase_row(html, "pre_close") =~ "Archived bank statement"

      socket =
        dispatch(socket, "review_phase", %{
          "phase" => "pre_close",
          "evidence_files" => [archived.id]
        })

      html = render_html(Live, socket.assigns)
      pre_close = phase_row(html, "pre_close")

      assert pre_close =~ "Archived bank statement"
      assert pre_close =~ "archived"
      assert pre_close =~ ~s(href="/pages/trash?org=#{org_id}#note-trash-item-#{archived.id}")
      assert pre_close =~ "open trash"
      refute pre_close =~ ~s(href="/pages/#{archived.id}")

      assert {:ok, state} = CloseDashboard.load(mount(org_id), org_id)
      assert state.evidence_titles[archived.id] == "Archived bank statement"
      assert state.evidence_status[archived.id] == :archived
    end

    test "without a Docs namespace the form falls back to Doc IDs" do
      org_id = Ash.UUID.generate()
      period = seed_period!(org_id, 2026, 10)
      _run = start_run!(org_id, period)

      assert {:ok, state} = CloseDashboard.load(mount(org_id, docs: false), org_id)
      refute state.docs_wired?
      assert state.docs == []

      html = mount_smoke(Live, mount(org_id, docs: false), %{"org" => org_id})
      pre_close = phase_row(html, "pre_close")

      assert pre_close =~ ~s(name="evidence_files")
      assert pre_close =~ "Doc IDs (comma-separated)"
      refute pre_close =~ "Docs evidence"
    end

    test "names who completed the run beside its status" do
      org_id = Ash.UUID.generate()
      period = seed_period!(org_id, 2026, 10)
      run = start_run!(org_id, period)
      run = Enum.reduce(ClosePhases.keys(), run, fn key, run -> sign!(run, key, org_id) end)

      scope = Samen.Web.TenantRole.attributed_admin_scope(mount(org_id), org_id)

      run =
        run
        |> Ash.Changeset.for_update(:finish, %{}, scope: scope)
        |> Ash.update!()

      assert run.status == :completed
      assert run.completed_by == scope.actor.id
      assert run.completed_by == "broker:#{org_id}"

      html = mount_smoke(Live, mount(org_id), %{"org" => org_id})
      card = period_card(html)

      assert card =~ "close run completed"
      assert card =~ ~s(id="close-run-completed-by")
      assert card =~ "by the workspace"
    end

    test "completes the close from the page once every phase is done" do
      org_id = Ash.UUID.generate()
      period = seed_period!(org_id, 2026, 10)
      run = start_run!(org_id, period)
      socket = socket(mount(org_id), %{"org" => org_id})

      html = render_html(Live, socket.assigns)
      refute html =~ ~s(id="close-finish-run")

      # A crafted early finish still reaches the kernel and shows its refusal.
      socket = dispatch(socket, "finish_run")
      html = render_html(Live, socket.assigns)
      assert html =~ ~s(id="close-action-error")
      assert html =~ "still open"

      run = Enum.reduce(ClosePhases.keys(), run, fn key, run -> sign!(run, key, org_id) end)
      assert run.status == :in_progress

      socket = socket(mount(org_id), %{"org" => org_id})
      html = render_html(Live, socket.assigns)
      assert html =~ ~s(id="close-finish-run")

      socket = dispatch(socket, "finish_run")
      html = render_html(Live, socket.assigns)

      assert html =~ "Close completed for October 2026."
      assert html =~ "close run completed"
      refute html =~ ~s(id="close-finish-run")

      run = Ash.get!(CloseRun, run.id, authorize?: false)
      assert run.status == :completed
      page_actor = Samen.Web.TenantRole.attributed_admin_scope(mount(org_id), org_id).actor.id
      assert run.completed_by == page_actor
      assert period_card(html) =~ "by the workspace"
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

      # The task is complete, but the phase still needs evidence and a review;
      # the sign-off button is not offered until both exist.
      assert pre_close =~ ~s(id="close-review-form-pre_close")
      refute pre_close =~ ~s(id="close-sign-pre_close")
      refute pre_close =~ "Complete the Work task first"
    end
  end
end
