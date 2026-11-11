defmodule Samen.Web.ErpDetailTest do
  @moduledoc """
  WS-ERP E8 detail + write-affordance proof over the REAL `Samen.WebTest.Erp`
  action shapes (the Finance + Inventory scope blueprints, not a stand-in):

    * the record page renders inside the app shell with the surface's nav item
      active and the bounded `Erp.detail_fields/1` facts (a seeded CoA account);
    * an id that resolves nothing renders the honest not-found card, an unknown
      surface the not-found state — neither names a module;
    * Edit rides `AshPhoenix.Form.for_update` — blank required fields render
      inline errors and persist nothing, a valid save lands;
    * the governed `accept([])` transitions: a balanced draft entry Posts
      (status flips, the offered buttons follow the registry's `from_statuses`)
      and an out-of-pre-state transition is refused server-side;
    * the whole expense-report chain on its record page: submit, a Gate-opened
      approval decided by a DISTINCT member (the requester is refused), and the
      admin settlement — with the posted and settlement entries proven in the GL;
    * rejecting an expense approval leaves the report submitted and unposted,
      and the approval can be reopened; the requester's own reject is refused
      by the distinct-party rule and no decision button is offered; a decided
      approval refuses any second decision as `:not_pending` (exactly-once);
    * a submitted expense report can be withdrawn; a cancelled report offers no
      status actions and its stale approve is refused by the state machine; the
      cancellation also withdraws its pending approval through the requester's
      own path (an admin's cancellation withdraws a member's approval too) — a
      late decision is `:not_pending`;
    * on an ARMED page a `:member` is refused settlement by the kernel's
      `RoleAtLeast :admin` gate, while a real admin control settles;
    * the journal-entry CREATE with the bounded line repeater lands BOTH the
      entry and its two balanced lines (the line-argument path);
    * the operator plane carries no write affordance.
  """
  use Samen.WebTest.DataCase, async: false

  require Ash.Query

  alias Samen.Web.Erp.DetailLive
  alias Samen.Web.Erp.SurfaceLive

  alias Samen.WebTest.Erp.{
    ApprovalPolicy,
    CorporateCard,
    ExpenseCategory,
    ExpenseReport,
    JournalEntry,
    JournalLine,
    PostingAccount
  }

  alias Samen.WebTest.Operator.{Membership, User}

  @org "33333333-4444-5555-6666-777777777777"
  @policy_kind "ap_invoice:approve"

  # -- harness ----------------------------------------------------------------

  defp open(module, params) do
    mount = build_mount(:erp)
    session = mount_session(mount)
    {:ok, socket} = module.mount(params, session, %Phoenix.LiveView.Socket{})
    {:noreply, socket} = module.handle_params(params, "http://localhost/erp/detail", socket)
    socket
  end

  defp event(module, socket, name, params) do
    {:noreply, socket} = module.handle_event(name, params, socket)
    socket
  end

  # -- seeds ------------------------------------------------------------------

  defp seed_account(code \\ "1000") do
    Samen.WebTest.Erp.Account
    |> Ash.Changeset.for_create(
      :create,
      %{
        org_id: @org,
        code: code,
        name: "Cash",
        kind: :asset,
        normal_side: :debit,
        currency: "USD"
      },
      authorize?: false
    )
    |> Ash.create!()
  end

  defp seed_entry(account_id) do
    Samen.WebTest.Erp.JournalEntry
    |> Ash.Changeset.for_create(
      :create,
      %{
        org_id: @org,
        entry_date: ~D[2026-10-01],
        memo: "Opening balance",
        lines: [
          %{account_id: account_id, debit_cents: 50_000, credit_cents: 0},
          %{account_id: account_id, debit_cents: 0, credit_cents: 50_000}
        ]
      },
      authorize?: false
    )
    |> Ash.create!()
  end

  defp seed_ap_bill(account_id, attrs \\ %{}) do
    Samen.WebTest.Erp.ApInvoice
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(
        %{
          org_id: @org,
          vendor_id: Ash.UUID.generate(),
          number: "BILL-" <> binary_part(Ash.UUID.generate(), 0, 8),
          bill_date: ~D[2026-10-14],
          match_tolerance_cents: 100,
          lines: [%{account_id: account_id, amount_cents: 25_000, memo: "Widgets"}]
        },
        attrs
      ),
      authorize?: false
    )
    |> Ash.create!()
  end

  defp seed_goods_receipt,
    do: Samen.WebTest.ErpFixtures.seed_goods_receipt(@org)

  defp reload_entry(id) do
    Samen.WebTest.Erp.JournalEntry
    |> Ash.read!(authorize?: false)
    |> Enum.find(&(&1.id == id))
  end

  defp count(mod), do: mod |> Ash.read!(authorize?: false) |> length()

  defp seed_member(handle, role) do
    credential_id = Ash.UUID.generate()

    user =
      User
      |> Ash.Changeset.for_create(:create, %{org_id: @org, handle: handle})
      |> Ash.Changeset.force_change_attribute(:credential_id, credential_id)
      |> Ash.create!(authorize?: false)

    Membership
    |> Ash.Changeset.for_create(:create, %{
      org_id: @org,
      user_id: user.id,
      role: role,
      status: "active"
    })
    |> Ash.create!(authorize?: false)

    {user, credential_id}
  end

  defp seed_ap_policy(steps) do
    ApprovalPolicy
    |> Ash.Changeset.for_create(
      :create,
      %{
        org_id: @org,
        kind: @policy_kind,
        threshold_cents: 0,
        auto_approve_below: false,
        steps: steps
      },
      authorize?: false
    )
    |> Ash.create!()
  end

  defp open_as(module, params, credential_id, mount \\ build_mount(:erp)) do
    session = mount_session(mount)

    socket =
      %Phoenix.LiveView.Socket{}
      |> Phoenix.Component.assign(:samen_tenant_principal, credential_id)

    {:ok, socket} = module.mount(params, session, socket)

    # An ARMED mount fail-closes `CurrentOrg.resolve/3` without a session
    # principal; seed the org its authenticated gate would have resolved, then
    # let `handle_params/3` (which never trusts the param when armed) load.
    socket = Phoenix.Component.assign(socket, :org_id, params["org"])

    {:noreply, socket} = module.handle_params(params, "http://localhost/erp/detail", socket)
    socket
  end

  defp armed_mount do
    mount = build_mount(:erp)
    %{mount | labels: Map.put(mount.labels || %{}, :authn, :required)}
  end

  defp open_approval!(bill) do
    scope = %Samen.Scope{
      actor: %{
        id: "requester:#{@org}",
        org_id: @org,
        role: :member,
        kind: :tenant,
        plane: :tenant
      }
    }

    assert {:error, %Ash.Error.Forbidden{errors: errors}} =
             bill
             |> Ash.Changeset.for_update(:approve, %{}, scope: scope)
             |> Ash.update()

    approval_id =
      Enum.find_value(errors, fn
        %Samen.Approvals.ApprovalRequired{approval_id: id} -> id
        _ -> nil
      end) || flunk("expected an ApprovalRequired error, got: #{inspect(errors)}")

    assert {:ok, approval} = Samen.Approvals.get(approval_id)
    approval
  end

  defp clear_approvals do
    Samen.WebTest.Approvals.Approval
    |> Ash.read!(authorize?: false)
    |> Enum.each(&Ash.destroy!(&1, authorize?: false))
  end

  defp with_approvals_wiring(fun) do
    previous = Application.get_env(:samen_core, Samen.Approvals)
    previous_registry = Application.get_env(:samen_core, Samen.Approvals.Registry)

    Application.put_env(
      :samen_core,
      Samen.Approvals,
      approval_resource: Samen.WebTest.Approvals.Approval,
      repo: Samen.WebTest.Repo
    )

    Application.put_env(:samen_core, Samen.Approvals.Registry,
      kinds: %{
        (Atom.to_string(Samen.WebTest.Erp.ApInvoice) <> ":approve") =>
          {:tenant, Samen.Approvals.Gate},
        (Atom.to_string(Samen.WebTest.Erp.ExpenseReport) <> ":approve") =>
          {:tenant, Samen.Approvals.Gate}
      }
    )

    clear_approvals()

    try do
      fun.()
    after
      restore_env(:samen_core, Samen.Approvals, previous)
      restore_env(:samen_core, Samen.Approvals.Registry, previous_registry)
    end
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)

  # -- the record page ----------------------------------------------------------

  test "a seeded record renders its bounded facts in the shell with the surface active" do
    account = seed_account("1000")
    socket = open(DetailLive, %{"org" => @org, "surface" => "coa", "id" => account.id})
    html = render_html(DetailLive, socket.assigns)

    assert html =~ ~s(id="erp-detail")
    assert html =~ ~s(class="app")
    # The surface's nav item is active from the record page too.
    assert html =~ ~s(href="/erp/coa?org=#{@org}" class="on")
    # Bounded facts (humanized registry field labels) + the values.
    assert html =~ "Normal side"
    assert html =~ "1000"
    assert html =~ "Cash"
    assert html =~ "debit"
    # Back link to the list, the edit affordance, the coa has no transitions.
    assert html =~ ~s(href="/erp/coa?org=#{@org}")
    assert html =~ ~s(id="edit-record")
    refute html =~ ~s(id="erp-transitions")
  end

  test "a draft credit note offers its governed Open/Void transitions, not Apply" do
    credit =
      Samen.WebTest.Erp.CreditNote
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: @org,
          customer_id: Ash.UUID.generate(),
          invoice_id: Ash.UUID.generate(),
          number: "CN-UI-1",
          date: ~D[2026-10-01],
          amount_cents: 1_000,
          kind: :credit
        },
        authorize?: false
      )
      |> Ash.create!()

    socket =
      open(DetailLive, %{"org" => @org, "surface" => "credit_notes", "id" => credit.id})

    html = render_html(DetailLive, socket.assigns)

    assert html =~ "Credit note"
    assert html =~ "Open credit note"
    assert html =~ "Void credit note"
    refute html =~ "Apply credit note"
  end

  test "the AP detail page renders the three-way match panel honestly when there are no references" do
    account = seed_account("6100")
    bill = seed_ap_bill(account.id)

    socket =
      open(DetailLive, %{"org" => @org, "surface" => "ap_invoices", "id" => bill.id})

    html = render_html(DetailLive, socket.assigns)

    assert html =~ ~s(id="erp-ap-match")
    assert html =~ "No match references"
    assert html =~ "No PO/receipt references on this bill"
    assert html =~ "Bill tolerance"
  end

  test "the AP match panel renders billed, received, variance, tolerance and status" do
    account = seed_account("6100")
    bill = seed_ap_bill(account.id)
    socket = open(DetailLive, %{"org" => @org, "surface" => "ap_invoices", "id" => bill.id})

    match = %{
      state: :variance,
      result: %{tolerance_cents: 100, tolerance_pct: 0, flagged?: true},
      lines: [
        %{
          line: 1,
          po_line_id: "po-line-1",
          purchase_order_id: "po-1",
          receipt_line_id: "receipt-line-1",
          goods_receipt_id: "gr-1",
          billed_cents: 25_000,
          received_cents: 0,
          variance_cents: 25_000,
          tolerance_cents: 100,
          status: :variance
        }
      ]
    }

    html =
      render_html(DetailLive, Map.put(socket.assigns, :ap_match, match))

    assert html =~ ~s(id="ap-match-line-1")
    assert html =~ "$250.00"
    assert html =~ "$0.00"
    assert html =~ "$1.00"
    assert html =~ "Over tolerance"
    assert html =~ "Approval will be refused"
    assert html =~ "/erp/purchase_orders/po-1?org=#{@org}#po-line-po-line-1"
    assert html =~ "/erp/goods_receipts/gr-1?org=#{@org}#receipt-line-receipt-line-1"
  end

  test "the AP detail page decides a role-filtered step as the signed-in admin" do
    with_approvals_wiring(fn ->
      account = seed_account("6100")
      {admin, admin_credential} = seed_member("ap-admin", :admin)
      {_member, member_credential} = seed_member("ap-member", :member)

      seed_ap_policy([
        %{"approver_type" => "user", "approver" => admin.id, "role" => "admin"},
        %{"approver_type" => "role", "approver" => "member"}
      ])

      bill = seed_ap_bill(account.id)
      approval = open_approval!(bill)
      params = %{"org" => @org, "surface" => "ap_invoices", "id" => bill.id}

      member_socket = open_as(DetailLive, params, member_credential)
      member_html = render_html(DetailLive, member_socket.assigns)

      assert member_socket.assigns.decider_role == :member
      assert member_socket.assigns.pending_approval.id == approval.id
      assert member_html =~ "Pending AP approval"
      assert member_html =~ "Step 1 of 2"
      assert member_html =~ "admin only"
      refute member_html =~ ~s(id="approve-ap-approval")

      member_socket =
        event(DetailLive, member_socket, "decide_approval", %{"decision" => "approve"})

      assert member_socket.assigns.approval_error =~ "different member or role"
      assert member_socket.assigns.pending_approval.state == :pending

      admin_socket = open_as(DetailLive, params, admin_credential)
      admin_html = render_html(DetailLive, admin_socket.assigns)

      assert admin_socket.assigns.decider_role == :admin
      assert admin_socket.assigns.pending_approval.id == approval.id
      assert admin_html =~ ~s(id="approve-ap-approval")
      assert admin_html =~ "Approve step"

      admin_socket =
        event(DetailLive, admin_socket, "decide_approval", %{"decision" => "approve"})

      assert admin_socket.assigns.approval_error == nil
      assert admin_socket.assigns.approval_notice =~ "Step approved"

      assert [%{"state" => "approved"}, %{"state" => "pending"}] =
               admin_socket.assigns.pending_approval.steps

      assert admin_socket.assigns.pending_approval.state == :pending
      assert Ash.get!(Samen.WebTest.Erp.ApInvoice, bill.id, authorize?: false).status == :draft
    end)
  end

  test "opening an AP approval from the bill page reloads the chain and blocks the requester" do
    with_approvals_wiring(fn ->
      account = seed_account("6100")
      {requester, requester_credential} = seed_member("ap-requester", :admin)
      {approver, approver_credential} = seed_member("ap-approver", :admin)

      seed_ap_policy([
        %{"approver_type" => "user", "approver" => approver.id, "role" => "admin"},
        %{"approver_type" => "role", "approver" => "member"}
      ])

      bill = seed_ap_bill(account.id)
      params = %{"org" => @org, "surface" => "ap_invoices", "id" => bill.id}

      requester_socket = open_as(DetailLive, params, requester_credential)

      requester_socket =
        event(DetailLive, requester_socket, "transition", %{"action" => "approve"})

      assert requester_socket.assigns.action_error != nil
      assert requester_socket.assigns.pending_approval.requested_by == requester.id

      html = render_html(DetailLive, requester_socket.assigns)
      assert html =~ "Pending AP approval"
      assert html =~ "requester cannot decide"
      refute html =~ ~s(id="approve-ap-approval")

      approver_socket = open_as(DetailLive, params, approver_credential)

      assert approver_socket.assigns.pending_approval.id ==
               requester_socket.assigns.pending_approval.id

      approver_socket =
        event(DetailLive, approver_socket, "decide_approval", %{"decision" => "approve"})

      assert approver_socket.assigns.approval_error == nil
      assert approver_socket.assigns.approval_notice =~ "Step approved"
      assert Ash.get!(Samen.WebTest.Erp.ApInvoice, bill.id, authorize?: false).status == :draft
    end)
  end

  # -- the expense-report chain ----------------------------------------------------

  test "an expense report submits, is approved by a distinct member and settles, from its page" do
    with_approvals_wiring(fn ->
      books = seed_expense_books()
      category = seed_expense_category(books.expense)
      card = seed_expense_card(books.card_liability)
      report = seed_expense_report(category, card)

      {requester, requester_credential} = seed_member("expense-requester", :member)
      {_approver, approver_credential} = seed_member("expense-approver", :admin)

      params = %{"org" => @org, "surface" => "expense_reports", "id" => report.id}

      requester_socket = open_as(DetailLive, params, requester_credential)

      assert requester_socket.assigns.record.status == :draft
      assert render_html(DetailLive, requester_socket.assigns) =~ ~s(id="transition-submit")

      # Submit through the record page's governed transition.
      requester_socket =
        event(DetailLive, requester_socket, "transition", %{"action" => "submit"})

      submitted = expense_report(report.id)
      assert submitted.status == :submitted
      assert submitted.submitted_at

      html = render_html(DetailLive, requester_socket.assigns)
      assert html =~ ~s(id="transition-approve")
      assert html =~ ~s(id="transition-cancel")
      refute html =~ ~s(id="transition-submit")

      # Approving OPENS an approval; it never approves the report by itself.
      requester_socket =
        event(DetailLive, requester_socket, "transition", %{"action" => "approve"})

      approval = requester_socket.assigns.pending_approval

      assert approval
      assert approval.state == :pending
      assert approval.requested_by == requester.id
      assert requester_socket.assigns.action_error =~ "approval_required"

      still_submitted = expense_report(report.id)
      assert still_submitted.status == :submitted
      assert still_submitted.posted_entry_id == nil

      # The requester's own page says who may decide and offers no button.
      html = render_html(DetailLive, requester_socket.assigns)
      assert html =~ "Pending expense approval"
      assert html =~ "requester cannot decide"
      refute html =~ ~s(id="approve-expense-approval")

      # A crafted decision as the requester is refused by the engine itself.
      requester_socket =
        event(DetailLive, requester_socket, "decide_approval", %{"decision" => "approve"})

      assert requester_socket.assigns.approval_error =~ "different party than the requester"
      assert requester_socket.assigns.pending_approval.state == :pending
      assert expense_report(report.id).status == :submitted

      # A DISTINCT member opens the same page and decides the pending approval.
      approver_socket = open_as(DetailLive, params, approver_credential)

      assert approver_socket.assigns.pending_approval.id == approval.id
      html = render_html(DetailLive, approver_socket.assigns)
      assert html =~ ~s(id="approve-expense-approval")
      assert html =~ "Approve step"

      approver_socket =
        event(DetailLive, approver_socket, "decide_approval", %{"decision" => "approve"})

      assert approver_socket.assigns.approval_error == nil
      assert approver_socket.assigns.approval_notice == "Report approved and posted."
      assert approver_socket.assigns.pending_approval == nil

      approved = expense_report(report.id)
      assert approved.status == :approved
      assert approved.approved_at
      assert approved.posted_entry_id

      # The approval posted ONE balanced entry: expense debits; card and
      # employee liabilities credited.
      posting = expense_entry!("expense_report", report.id)
      posting_lines = entry_lines(posting.id)

      assert sum(posting_lines, :debit_cents) == 200_000
      assert sum(posting_lines, :credit_cents) == 200_000
      assert line_amount(posting_lines, books.expense.id, :debit_cents) == 200_000
      assert line_amount(posting_lines, books.card_liability.id, :credit_cents) == 80_000
      assert line_amount(posting_lines, books.employee_payable.id, :credit_cents) == 120_000

      # The admin settles the approved report from the same page.
      admin_socket = open_as(DetailLive, params, approver_credential)
      assert render_html(DetailLive, admin_socket.assigns) =~ ~s(id="transition-reimburse")

      admin_socket = event(DetailLive, admin_socket, "transition", %{"action" => "reimburse"})

      assert admin_socket.assigns.action_error == nil

      reimbursed = expense_report(report.id)
      assert reimbursed.status == :reimbursed
      assert reimbursed.reimbursed_at
      assert reimbursed.settlement_entry_id

      settlement = expense_entry!("expense_settlement", report.id)
      settlement_lines = entry_lines(settlement.id)

      assert sum(settlement_lines, :debit_cents) == 200_000
      assert sum(settlement_lines, :credit_cents) == 200_000
      assert line_amount(settlement_lines, books.card_liability.id, :debit_cents) == 80_000
      assert line_amount(settlement_lines, books.employee_payable.id, :debit_cents) == 120_000
      assert line_amount(settlement_lines, books.cash.id, :credit_cents) == 200_000

      assert render_html(DetailLive, admin_socket.assigns) =~ "reimbursed"
    end)
  end

  test "rejecting an expense approval leaves the report submitted and unposted" do
    with_approvals_wiring(fn ->
      books = seed_expense_books()
      category = seed_expense_category(books.expense)
      card = seed_expense_card(books.card_liability)
      report = seed_expense_report(category, card)

      {_requester, requester_credential} = seed_member("expense-requester", :member)
      {_approver, approver_credential} = seed_member("expense-approver", :admin)

      params = %{"org" => @org, "surface" => "expense_reports", "id" => report.id}

      requester_socket = open_as(DetailLive, params, requester_credential)

      requester_socket =
        event(DetailLive, requester_socket, "transition", %{"action" => "submit"})

      requester_socket =
        event(DetailLive, requester_socket, "transition", %{"action" => "approve"})

      approval = requester_socket.assigns.pending_approval
      assert approval.state == :pending
      assert expense_report(report.id).status == :submitted

      # The distinct approver rejects the pending decision from the page.
      approver_socket = open_as(DetailLive, params, approver_credential)
      assert approver_socket.assigns.pending_approval.id == approval.id
      assert render_html(DetailLive, approver_socket.assigns) =~ ~s(id="reject-expense-approval")

      approver_socket =
        event(DetailLive, approver_socket, "decide_approval", %{"decision" => "reject"})

      assert approver_socket.assigns.approval_error == nil

      assert approver_socket.assigns.approval_notice ==
               "Approval rejected. The report remains submitted."

      assert approver_socket.assigns.pending_approval == nil

      rejected = expense_report(report.id)
      assert rejected.status == :submitted
      assert rejected.approved_at == nil
      assert rejected.posted_entry_id == nil

      assert {:ok, nil} = expense_entry("expense_report", report.id)
      assert {:ok, nil} = expense_entry("expense_settlement", report.id)
      assert {:ok, %{state: :rejected}} = Samen.Approvals.get(approval.id)

      # A rejection never strands the report: the Gate can be reopened.
      requester_socket = open_as(DetailLive, params, requester_credential)

      requester_socket =
        event(DetailLive, requester_socket, "transition", %{"action" => "approve"})

      reopened = requester_socket.assigns.pending_approval
      assert reopened.id != approval.id
      assert reopened.state == :pending
      assert expense_report(report.id).status == :submitted
    end)
  end

  test "the requester cannot reject their own pending expense approval" do
    with_approvals_wiring(fn ->
      books = seed_expense_books()
      category = seed_expense_category(books.expense)
      card = seed_expense_card(books.card_liability)
      report = seed_expense_report(category, card)

      {_requester, requester_credential} = seed_member("expense-requester", :member)
      {_approver, approver_credential} = seed_member("expense-approver", :admin)

      params = %{"org" => @org, "surface" => "expense_reports", "id" => report.id}

      requester_socket = open_as(DetailLive, params, requester_credential)

      requester_socket =
        event(DetailLive, requester_socket, "transition", %{"action" => "submit"})

      requester_socket =
        event(DetailLive, requester_socket, "transition", %{"action" => "approve"})

      approval = requester_socket.assigns.pending_approval
      assert approval.state == :pending

      # The panel is honest: it says the requester cannot decide and offers
      # neither the approve nor the reject button.
      html = render_html(DetailLive, requester_socket.assigns)
      assert html =~ "requester cannot decide"
      refute html =~ ~s(id="approve-expense-approval")
      refute html =~ ~s(id="reject-expense-approval")

      # A crafted reject as the requester is refused by the engine itself.
      requester_socket =
        event(DetailLive, requester_socket, "decide_approval", %{"decision" => "reject"})

      assert requester_socket.assigns.approval_error =~ "different party than the requester"
      assert requester_socket.assigns.approval_notice == nil

      still_pending = requester_socket.assigns.pending_approval
      assert still_pending.id == approval.id
      assert still_pending.state == :pending

      untouched = expense_report(report.id)
      assert untouched.status == :submitted
      assert untouched.posted_entry_id == nil
      assert {:ok, %{state: :pending}} = Samen.Approvals.get(approval.id)
      assert {:ok, nil} = expense_entry("expense_report", report.id)

      # Positive control: the distinct approver can still reject it.
      approver_socket = open_as(DetailLive, params, approver_credential)
      assert approver_socket.assigns.pending_approval.id == approval.id

      approver_socket =
        event(DetailLive, approver_socket, "decide_approval", %{"decision" => "reject"})

      assert approver_socket.assigns.approval_error == nil
      assert {:ok, %{state: :rejected}} = Samen.Approvals.get(approval.id)
      assert expense_report(report.id).status == :submitted
    end)
  end

  test "a second decision on a rejected expense approval is refused as not pending" do
    with_approvals_wiring(fn ->
      books = seed_expense_books()
      category = seed_expense_category(books.expense)
      card = seed_expense_card(books.card_liability)
      report = seed_expense_report(category, card)

      {_requester, requester_credential} = seed_member("expense-requester", :member)
      {approver, approver_credential} = seed_member("expense-approver", :admin)

      params = %{"org" => @org, "surface" => "expense_reports", "id" => report.id}

      requester_socket = open_as(DetailLive, params, requester_credential)

      requester_socket =
        event(DetailLive, requester_socket, "transition", %{"action" => "submit"})

      requester_socket =
        event(DetailLive, requester_socket, "transition", %{"action" => "approve"})

      approval = requester_socket.assigns.pending_approval

      approver_socket = open_as(DetailLive, params, approver_credential)

      approver_socket =
        event(DetailLive, approver_socket, "decide_approval", %{"decision" => "reject"})

      assert approver_socket.assigns.pending_approval == nil
      assert {:ok, %{state: :rejected}} = Samen.Approvals.get(approval.id)

      # The page's decision affordance is gone; a crafted repeat says so.
      approver_socket =
        event(DetailLive, approver_socket, "decide_approval", %{"decision" => "reject"})

      assert approver_socket.assigns.approval_error == "That approval is no longer pending."

      # The engine refuses both decision directions on the decided approval.
      assert {:error, :not_pending} =
               Samen.Approvals.reject(approval.id, approver.id, role: :admin)

      assert {:error, :not_pending} =
               Samen.Approvals.approve(approval.id, approver.id, role: :admin)

      unchanged = expense_report(report.id)
      assert unchanged.status == :submitted
      assert unchanged.posted_entry_id == nil
      assert {:ok, nil} = expense_entry("expense_report", report.id)
      assert {:ok, nil} = expense_entry("expense_settlement", report.id)
    end)
  end

  test "a submitted expense report can be cancelled and cannot then be approved" do
    books = seed_expense_books()
    category = seed_expense_category(books.expense)
    card = seed_expense_card(books.card_liability)
    report = seed_expense_report(category, card)

    {_requester, requester_credential} = seed_member("expense-requester", :member)

    params = %{"org" => @org, "surface" => "expense_reports", "id" => report.id}

    socket = open_as(DetailLive, params, requester_credential)
    socket = event(DetailLive, socket, "transition", %{"action" => "submit"})

    assert expense_report(report.id).status == :submitted
    assert render_html(DetailLive, socket.assigns) =~ ~s(id="transition-cancel")

    # A submitted report can still be withdrawn from its own page.
    socket = event(DetailLive, socket, "transition", %{"action" => "cancel"})

    assert socket.assigns.action_error == nil

    cancelled = expense_report(report.id)
    assert cancelled.status == :cancelled
    assert cancelled.approved_at == nil
    assert cancelled.posted_entry_id == nil

    # Nothing is actionable or pending after the withdrawal.
    html = render_html(DetailLive, socket.assigns)
    refute html =~ ~s(id="transition-approve")
    refute html =~ ~s(id="transition-submit")
    refute html =~ ~s(id="transition-cancel")
    refute html =~ ~s(id="erp-transitions")
    refute html =~ ~s(id="erp-transitions-readonly")
    assert socket.assigns.pending_approval == nil

    # A crafted approve from the stale page never reaches the engine.
    socket = event(DetailLive, socket, "transition", %{"action" => "approve"})

    assert socket.assigns.pending_approval == nil
    assert expense_report(report.id).status == :cancelled
    assert {:ok, nil} = expense_entry("expense_report", report.id)

    # And the state machine itself refuses the approval on the cancelled record.
    scope = Samen.Web.Mount.scope(build_mount(:erp), @org)

    assert {:error, error} =
             cancelled
             |> Ash.Changeset.for_update(:approve, %{}, scope: scope)
             |> Ash.update()

    assert Exception.message(error) =~ "cannot transition"

    still_cancelled = expense_report(report.id)
    assert still_cancelled.status == :cancelled
    assert still_cancelled.approved_at == nil
    assert still_cancelled.posted_entry_id == nil
    assert {:ok, nil} = expense_entry("expense_report", report.id)
    assert {:ok, nil} = expense_entry("expense_settlement", report.id)
  end

  test "cancelling a submitted report withdraws its pending approval" do
    with_approvals_wiring(fn ->
      books = seed_expense_books()
      category = seed_expense_category(books.expense)
      card = seed_expense_card(books.card_liability)
      report = seed_expense_report(category, card)

      {requester, requester_credential} = seed_member("expense-requester", :member)
      {approver, _approver_credential} = seed_member("expense-approver", :admin)

      params = %{"org" => @org, "surface" => "expense_reports", "id" => report.id}

      requester_socket = open_as(DetailLive, params, requester_credential)

      requester_socket =
        event(DetailLive, requester_socket, "transition", %{"action" => "submit"})

      requester_socket =
        event(DetailLive, requester_socket, "transition", %{"action" => "approve"})

      approval = requester_socket.assigns.pending_approval
      assert approval.state == :pending
      assert approval.requested_by == requester.id

      # The report is withdrawn while the approval is still pending; the same
      # cancellation withdraws the approval through the requester's own path.
      requester_socket =
        event(DetailLive, requester_socket, "transition", %{"action" => "cancel"})

      assert requester_socket.assigns.action_error == nil
      assert expense_report(report.id).status == :cancelled

      assert {:ok, %{state: :cancelled, decided_by: nil}} =
               Samen.Approvals.get(approval.id)

      assert requester_socket.assigns.pending_approval == nil

      kind = Samen.Approvals.Gate.kind_for(ExpenseReport, :approve)
      assert {:ok, pending} = Samen.Approvals.list_pending(@org, kind)
      refute Enum.any?(pending, &(&1.id == approval.id))

      # A late decision on the withdrawn approval is refused as not pending.
      assert {:error, :not_pending} =
               Samen.Approvals.approve(approval.id, approver.id, role: :admin)

      # A cancelled report still cannot be approved, and nothing was posted.
      scope = Samen.Web.Mount.scope(build_mount(:erp), @org)

      assert {:error, error} =
               expense_report(report.id)
               |> Ash.Changeset.for_update(:approve, %{}, scope: scope)
               |> Ash.update()

      assert Exception.message(error) =~ "cannot transition"

      cancelled = expense_report(report.id)
      assert cancelled.status == :cancelled
      assert cancelled.approved_at == nil
      assert cancelled.posted_entry_id == nil
      assert {:ok, nil} = expense_entry("expense_report", report.id)
      assert {:ok, nil} = expense_entry("expense_settlement", report.id)
    end)
  end

  test "an admin's cancellation withdraws a member's pending approval" do
    with_approvals_wiring(fn ->
      books = seed_expense_books()
      category = seed_expense_category(books.expense)
      card = seed_expense_card(books.card_liability)
      report = seed_expense_report(category, card)

      {member, member_credential} = seed_member("expense-requester", :member)
      {_admin, admin_credential} = seed_member("expense-admin", :admin)

      params = %{"org" => @org, "surface" => "expense_reports", "id" => report.id}

      member_socket = open_as(DetailLive, params, member_credential)
      member_socket = event(DetailLive, member_socket, "transition", %{"action" => "submit"})
      member_socket = event(DetailLive, member_socket, "transition", %{"action" => "approve"})

      approval = member_socket.assigns.pending_approval
      assert approval.requested_by == member.id

      # The admin withdraws the member's report; the pending approval still
      # belongs to the member, so it is withdrawn on that recorded requester's path.
      admin_socket = open_as(DetailLive, params, admin_credential)
      assert render_html(DetailLive, admin_socket.assigns) =~ ~s(id="transition-cancel")

      admin_socket = event(DetailLive, admin_socket, "transition", %{"action" => "cancel"})

      assert admin_socket.assigns.action_error == nil
      assert expense_report(report.id).status == :cancelled

      assert {:ok, %{state: :cancelled, decided_by: nil}} =
               Samen.Approvals.get(approval.id)

      assert admin_socket.assigns.pending_approval == nil

      kind = Samen.Approvals.Gate.kind_for(ExpenseReport, :approve)
      assert {:ok, pending} = Samen.Approvals.list_pending(@org, kind)
      refute Enum.any?(pending, &(&1.id == approval.id))

      assert {:ok, nil} = expense_entry("expense_report", report.id)
      assert {:ok, nil} = expense_entry("expense_settlement", report.id)
    end)
  end

  test "an armed member cannot settle an approved report; the admin control can" do
    with_approvals_wiring(fn ->
      books = seed_expense_books()
      category = seed_expense_category(books.expense)
      card = seed_expense_card(books.card_liability)
      report = seed_expense_report(category, card)

      {_member, member_credential} = seed_member("expense-member", :member)
      {_admin, admin_credential} = seed_member("expense-admin", :admin)

      assert approve_report!(report).status == :approved

      params = %{"org" => @org, "surface" => "expense_reports", "id" => report.id}

      # The armed page derives the REAL Membership role (`:member`) and does
      # NOT offer the admin-only settlement — while a crafted event is still
      # refused by the kernel's `RoleAtLeast :admin` policy.
      member_socket = open_as(DetailLive, params, member_credential, armed_mount())

      assert member_socket.assigns.record.status == :approved
      member_html = render_html(DetailLive, member_socket.assigns)
      assert member_html =~ "approved"
      refute member_html =~ ~s(id="transition-reimburse")
      refute member_html =~ ~s(id="erp-transitions")
      assert member_html =~ ~s(id="erp-transitions-readonly")
      assert member_html =~ "Settle report requires an organization admin."

      member_socket = event(DetailLive, member_socket, "transition", %{"action" => "reimburse"})

      assert member_socket.assigns.action_error =~ "forbidden"

      refused = expense_report(report.id)
      assert refused.status == :approved
      assert refused.settlement_entry_id == nil
      assert {:ok, nil} = expense_entry("expense_settlement", report.id)

      # Positive control: the SAME armed page offers settlement to a real
      # admin and settles.
      admin_socket = open_as(DetailLive, params, admin_credential, armed_mount())
      admin_html = render_html(DetailLive, admin_socket.assigns)
      assert admin_html =~ ~s(id="transition-reimburse")
      refute admin_html =~ ~s(id="erp-transitions-readonly")

      admin_socket = event(DetailLive, admin_socket, "transition", %{"action" => "reimburse"})

      assert admin_socket.assigns.action_error == nil
      assert expense_report(report.id).status == :reimbursed
      assert expense_report(report.id).settlement_entry_id
    end)
  end

  # Reaches an approved report (and its posted GL entry) through the real
  # transitions + Gate, with a distinct approver deciding the approval.
  defp approve_report!(report) do
    scope = Samen.Web.Mount.scope(build_mount(:erp), @org)

    submitted =
      report
      |> Ash.Changeset.for_update(:submit, %{}, scope: scope)
      |> Ash.update!()

    {:error, %Ash.Error.Forbidden{errors: errors}} =
      submitted
      |> Ash.Changeset.for_update(:approve, %{}, scope: scope)
      |> Ash.update()

    approval_id =
      Enum.find_value(errors, fn
        %Samen.Approvals.ApprovalRequired{approval_id: id} -> id
        _ -> nil
      end) || flunk("expected an ApprovalRequired error, got: #{inspect(errors)}")

    assert {:ok, _decided, _meta} =
             Samen.Approvals.approve(approval_id, "expense-approver", role: :admin)

    expense_report(report.id)
  end

  defp seed_expense_books do
    expense = seed_expense_account("6000", "Travel expense", :expense, :debit)
    cash = seed_expense_account("1000", "Operating cash", :asset, :debit)
    card_liability = seed_expense_account("2100", "Card liability", :liability, :credit)
    employee_payable = seed_expense_account("2200", "Employee payable", :liability, :credit)

    for {key, account} <- [
          {:cash, cash},
          {:employee_reimbursement_payable, employee_payable}
        ] do
      PostingAccount
      |> Ash.Changeset.for_create(
        :create,
        %{org_id: @org, key: key, account_id: account.id},
        authorize?: false
      )
      |> Ash.create!()
    end

    %{
      expense: expense,
      cash: cash,
      card_liability: card_liability,
      employee_payable: employee_payable
    }
  end

  defp seed_expense_account(code, name, kind, side) do
    Samen.WebTest.Erp.Account
    |> Ash.Changeset.for_create(
      :create,
      %{
        org_id: @org,
        code: code,
        name: name,
        kind: kind,
        normal_side: side,
        currency: "USD"
      },
      authorize?: false
    )
    |> Ash.create!()
  end

  defp seed_expense_category(account) do
    ExpenseCategory
    |> Ash.Changeset.for_create(
      :create,
      %{
        org_id: @org,
        name: "Travel",
        account_id: account.id,
        requires_receipt: false,
        is_active: true
      },
      authorize?: false
    )
    |> Ash.create!()
  end

  defp seed_expense_card(account) do
    CorporateCard
    |> Ash.Changeset.for_create(
      :create,
      %{
        org_id: @org,
        name: "Travel card",
        last4: "4242",
        cardholder_id: Ash.UUID.generate(),
        account_id: account.id,
        currency: "USD",
        is_active: true
      },
      authorize?: false
    )
    |> Ash.create!()
  end

  defp seed_expense_report(category, card) do
    ExpenseReport
    |> Ash.Changeset.for_create(
      :create,
      %{
        org_id: @org,
        employee_id: Ash.UUID.generate(),
        title: "Q4 travel",
        currency: "USD",
        lines: [
          expense_line(category, 120_000, "personal_card", nil, "receipt-1"),
          expense_line(category, 80_000, "corporate_card", card, "receipt-2")
        ]
      },
      authorize?: false
    )
    |> Ash.create!()
  end

  defp expense_line(category, amount, method, card, receipt) do
    %{
      "category_id" => category.id,
      "corporate_card_id" => card && card.id,
      "description" => "Expense line",
      "amount_cents" => amount,
      "spent_on" => "2026-11-10",
      "payment_method" => method,
      "receipt_ref" => receipt
    }
  end

  defp expense_report(id), do: Ash.get!(ExpenseReport, id, authorize?: false)

  defp expense_entry(source_key, report_id) do
    JournalEntry
    |> Ash.Query.filter(source_key == ^source_key and source_id == ^report_id)
    |> Ash.read_one(authorize?: false)
  end

  defp expense_entry!(source_key, report_id) do
    case expense_entry(source_key, report_id) do
      {:ok, %JournalEntry{} = entry} -> entry
      other -> flunk("expected a #{source_key} entry, got: #{inspect(other)}")
    end
  end

  defp entry_lines(entry_id) do
    JournalLine
    |> Ash.Query.filter(entry_id == ^entry_id)
    |> Ash.read!(authorize?: false)
  end

  defp sum(lines, field), do: Enum.reduce(lines, 0, &(Map.fetch!(&1, field) + &2))

  defp line_amount(lines, account_id, field) do
    lines
    |> Enum.filter(&(&1.account_id == account_id))
    |> sum(field)
  end

  test "the goods-receipt detail page loads its receipt lines at stable anchors" do
    {receipt, receipt_line, po_line} = seed_goods_receipt()

    socket =
      open(DetailLive, %{"org" => @org, "surface" => "goods_receipts", "id" => receipt.id})

    html = render_html(DetailLive, socket.assigns)

    assert html =~ receipt.number
    assert html =~ "Receipt detail seed"
    assert html =~ receipt.purchase_order_id
    assert html =~ ~s(id="receipt-line-#{receipt_line.id}")
    assert html =~ po_line.id
    assert html =~ ~s(href="/erp/goods_receipts?org=#{@org}" class="on")
    refute html =~ ~s(id="edit-record")
  end

  test "an id that resolves nothing renders the honest not-found card" do
    socket =
      open(DetailLive, %{
        "org" => @org,
        "surface" => "coa",
        "id" => "99999999-9999-9999-9999-999999999999"
      })

    html = render_html(DetailLive, socket.assigns)

    assert html =~ "Account not found."
  end

  test "an unknown surface renders the not-found state and names no module" do
    socket =
      open(DetailLive, %{
        "org" => @org,
        "surface" => "bogus",
        "id" => "99999999-9999-9999-9999-999999999999"
      })

    html = render_html(DetailLive, socket.assigns)

    assert html =~ "not available on this workspace's mounted modules"
    assert html =~ "Not found"
  end

  # -- edit --------------------------------------------------------------------

  test "edit: blank required fields render inline errors; a valid save lands" do
    account = seed_account("1000")
    params = %{"org" => @org, "surface" => "coa", "id" => account.id}
    socket = open(DetailLive, params)

    socket = event(DetailLive, socket, "edit_record", %{})
    assert render_html(DetailLive, socket.assigns) =~ ~s(id="erp-edit-modal")

    socket =
      event(DetailLive, socket, "validate_edit", %{
        "form" => %{
          "name" => "",
          "kind" => "asset",
          "normal_side" => "debit",
          "currency" => "USD"
        }
      })

    assert render_html(DetailLive, socket.assigns) =~ "field-invalid"

    # Invalid submit: still on the form, nothing persisted.
    socket =
      event(DetailLive, socket, "save_edit", %{
        "form" => %{
          "name" => "",
          "kind" => "asset",
          "normal_side" => "debit",
          "currency" => "USD"
        }
      })

    assert render_html(DetailLive, socket.assigns) =~ "field-invalid"
    assert reload(account.id).name == "Cash"

    # Valid submit: persisted, modal closed, facts refreshed.
    socket =
      event(DetailLive, socket, "save_edit", %{
        "form" => %{
          "name" => "Operating Cash",
          "kind" => "asset",
          "normal_side" => "debit",
          "currency" => "USD"
        }
      })

    html = render_html(DetailLive, socket.assigns)
    refute html =~ ~s(id="erp-edit-modal")
    assert reload(account.id).name == "Operating Cash"
    assert html =~ "Operating Cash"
  end

  defp reload(id) do
    Samen.WebTest.Erp.Account
    |> Ash.read!(authorize?: false)
    |> Enum.find(&(&1.id == id))
  end

  # -- governed transitions ------------------------------------------------------

  test "Post flips a balanced draft entry and the offered buttons follow the registry" do
    account = seed_account()
    entry = seed_entry(account.id)
    params = %{"org" => @org, "surface" => "entries", "id" => entry.id}

    socket = open(DetailLive, params)
    html = render_html(DetailLive, socket.assigns)

    assert html =~ ~s(id="transition-post")
    refute html =~ ~s(id="transition-void")
    assert reload_entry(entry.id).status == :draft

    socket = event(DetailLive, socket, "transition", %{"action" => "post"})
    html = render_html(DetailLive, socket.assigns)

    posted = reload_entry(entry.id)
    assert posted.status == :posted
    assert posted.posted_at
    # Void becomes offerable from :posted; post does not.
    assert html =~ ~s(id="transition-void")
    refute html =~ ~s(id="transition-post")
    refute html =~ ~s(id="action-error")
  end

  test "an out-of-pre-state transition is refused server-side (never trusts the click)" do
    account = seed_account()
    entry = seed_entry(account.id)
    params = %{"org" => @org, "surface" => "entries", "id" => entry.id}

    socket = open(DetailLive, params)
    # `void` is only offered FROM :posted — a draft click is silently refused.
    socket = event(DetailLive, socket, "transition", %{"action" => "void"})

    assert reload_entry(entry.id).status == :draft
    _ = render_html(DetailLive, socket.assigns)
  end

  # -- the create line-repeater path ---------------------------------------------

  test "journal-entry create lands the entry AND its balanced lines through the repeater" do
    account = seed_account()
    params = %{"org" => @org, "surface" => "entries"}
    socket = open(SurfaceLive, params)

    socket = event(SurfaceLive, socket, "new_record", %{})
    assert render_html(SurfaceLive, socket.assigns) =~ ~s(id="line-rows")

    form = %{
      "entry_date" => "2026-10-02",
      "memo" => "Opening entry",
      "lines" => [
        %{"account_id" => account.id, "debit_cents" => "50000", "credit_cents" => "0"},
        %{"account_id" => account.id, "debit_cents" => "0", "credit_cents" => "50000"}
      ]
    }

    socket = event(SurfaceLive, socket, "validate_new", %{"form" => form})
    socket = event(SurfaceLive, socket, "save_new", %{"form" => form})

    assert count(Samen.WebTest.Erp.JournalEntry) == 1
    assert count(Samen.WebTest.Erp.JournalLine) == 2

    [entry] =
      Samen.WebTest.Erp.JournalEntry
      |> Ash.Query.ensure_selected([:org_id])
      |> Ash.read!(authorize?: false)

    assert entry.status == :draft
    assert entry.org_id == @org

    # The fresh row links onward to its own detail page.
    html = render_html(SurfaceLive, socket.assigns)
    assert html =~ ~s(href="/erp/entries/#{entry.id}?org=#{@org}")
  end

  # The browser roundtrip differs from what a direct handler call hands us:
  # LiveView serializes `lines[0][field]` through `Plug.Conn.Query.decode/1`,
  # which delivers lines as a MAP keyed by row index (with `_unused_*`
  # sibling markers), not as a list. This exact shape crashed the repeater
  # on prod with `BadMapError expected a map, got: {"0", %{...}}`.
  test "journal-entry create survives the browser's index-keyed lines map" do
    account = seed_account()
    params = %{"org" => @org, "surface" => "entries"}
    socket = open(SurfaceLive, params)
    socket = event(SurfaceLive, socket, "new_record", %{})

    form = %{
      "entry_date" => "2026-10-02",
      "memo" => "Opening entry",
      "_unused_id" => "ignored",
      "lines" => %{
        "0" => %{
          "account_id" => account.id,
          "debit_cents" => "50000",
          "credit_cents" => "0",
          "_unused_memo" => ""
        },
        "1" => %{
          "account_id" => account.id,
          "debit_cents" => "0",
          "credit_cents" => "50000",
          "_unused_memo" => ""
        }
      }
    }

    socket = event(SurfaceLive, socket, "validate_new", %{"form" => form})
    # The re-render reads `line_values` back through the repeater — the exact
    # code path that raised BadMapError.
    _ = render_html(SurfaceLive, socket.assigns)

    socket = event(SurfaceLive, socket, "save_new", %{"form" => form})

    assert count(Samen.WebTest.Erp.JournalEntry) == 1
    assert count(Samen.WebTest.Erp.JournalLine) == 2

    [entry] =
      Samen.WebTest.Erp.JournalEntry
      |> Ash.Query.ensure_selected([:org_id])
      |> Ash.read!(authorize?: false)

    assert entry.status == :draft

    # The modal closed and the fresh row links onward to its detail page.
    html = render_html(SurfaceLive, socket.assigns)
    refute html =~ ~s(id="new-record-modal")
    assert html =~ ~s(href="/erp/entries/#{entry.id}?org=#{@org}")
  end

  test "an unbalanced entry create is refused honestly by the balance guard" do
    account = seed_account()
    params = %{"org" => @org, "surface" => "entries"}
    socket = open(SurfaceLive, params)
    socket = event(SurfaceLive, socket, "new_record", %{})

    form = %{
      "entry_date" => "2026-10-02",
      "lines" => [
        %{"account_id" => account.id, "debit_cents" => "50000", "credit_cents" => "0"}
      ]
    }

    socket = event(SurfaceLive, socket, "save_new", %{"form" => form})

    assert count(Samen.WebTest.Erp.JournalEntry) == 0
    assert count(Samen.WebTest.Erp.JournalLine) == 0
    assert render_html(SurfaceLive, socket.assigns) =~ ~s(id="new-record-modal")
  end

  # -- operator posture ------------------------------------------------------------

  test "the operator plane carries no detail write affordance" do
    account = seed_account()

    mount = build_mount(:erp, plane: :operator, target_org_id: @org)
    session = mount_session(mount)
    params = %{"org" => @org, "surface" => "coa", "id" => account.id}

    {:ok, socket} = DetailLive.mount(params, session, %Phoenix.LiveView.Socket{})
    {:noreply, socket} = DetailLive.handle_params(params, "http://localhost/erp/detail", socket)
    html = render_html(DetailLive, socket.assigns)

    refute html =~ ~s(id="edit-record")
    refute html =~ ~s(id="erp-transitions")
  end
end
