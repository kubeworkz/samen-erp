defmodule Samen.ExpensesTest do
  @moduledoc """
  WS-ERP E31 (#12): the productized expense slice over the core Finance fixture.

  Positive path: an admin configures an expense category and a corporate card,
  a member files a mixed cash/card report, the report is submitted, approved by
  a DISTINCT approver, and reimbursed. The assertions walk the GL: approval
  debits the category accounts and credits the card/employee liabilities;
  reimbursement clears those liabilities against cash.

  Red paths pair each refusal with a positive control: a receipt-required
  category refuses a missing receipt, a max-cap category refuses an over-cap
  line, a foreign-org category is invisible, and a second submit is refused.
  Cancelling a report withdraws its pending approval through the recorded
  requester — even when an admin cancels it — and a late decision is refused.
  A report with no pending approval still cancels cleanly and writes no
  cancellation audit.
  """

  use ExUnit.Case, async: false

  require Ash.Query

  import Ecto.Query, only: [from: 2]

  alias Samen.AuditEvent, as: AuditEvent

  alias SamenCore.Support.FinanceFixture.{
    Account,
    CorporateCard,
    ExpenseCategory,
    ExpenseReport,
    JournalEntry,
    JournalLine,
    PostingAccount
  }

  @repo SamenCore.TestRepo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(@repo)
    org = Ash.UUID.generate()

    %{org: org, member: member_scope(org), admin: admin_scope(org)}
  end

  test "a mixed cash/card report approves, posts and settles", %{
    org: org,
    member: member,
    admin: admin
  } do
    books = books!(admin, org)
    category = category!(admin, org, books.expense, "Travel")
    card = card!(admin, org, books.card_liability, "Travel card")

    report =
      report!(member, org, category, card, [
        line(category, 120_000, "personal_card", nil, "receipt-1"),
        line(category, 80_000, "corporate_card", card, "receipt-2")
      ])

    assert report.total_cents == 200_000
    assert report.status == :draft

    submitted = submit!(report, member)
    assert submitted.status == :submitted
    assert submitted.submitted_at

    {:gated, approval_id} = gate(submitted, member)
    assert {:ok, approved, _meta} = decide(approval_id)
    assert approved.state == :approved

    posted = Ash.get!(ExpenseReport, report.id, authorize?: false)
    assert posted.status == :approved
    assert posted.approved_at
    assert posted.posted_entry_id

    posting = entry!(org, "expense_report", report.id)
    posting_lines = entry_lines(posting.id)

    assert sum(posting_lines, :debit_cents) == 200_000
    assert sum(posting_lines, :credit_cents) == 200_000
    assert line_amount(posting_lines, books.expense.id, :debit_cents) == 200_000
    assert line_amount(posting_lines, books.card_liability.id, :credit_cents) == 80_000
    assert line_amount(posting_lines, books.employee_payable.id, :credit_cents) == 120_000

    assert {:ok, reimbursed} =
             posted
             |> Ash.Changeset.for_update(:reimburse, %{}, scope: admin)
             |> Ash.update()

    assert reimbursed.status == :reimbursed
    assert reimbursed.reimbursed_at
    assert reimbursed.settlement_entry_id

    settlement = entry!(org, "expense_settlement", report.id)
    settlement_lines = entry_lines(settlement.id)

    assert sum(settlement_lines, :debit_cents) == 200_000
    assert sum(settlement_lines, :credit_cents) == 200_000
    assert line_amount(settlement_lines, books.card_liability.id, :debit_cents) == 80_000
    assert line_amount(settlement_lines, books.employee_payable.id, :debit_cents) == 120_000
    assert line_amount(settlement_lines, books.cash.id, :credit_cents) == 200_000
  end

  test "a receipt-required category refuses a missing receipt; a receipt control passes", %{
    org: org,
    member: member,
    admin: admin
  } do
    books = books!(admin, org)

    category =
      category!(admin, org, books.expense, "Meals", %{requires_receipt: true})

    assert {:error, error} =
             ExpenseReport
             |> Ash.Changeset.for_create(
               :create,
               %{
                 org_id: org,
                 employee_id: Ash.UUID.generate(),
                 title: "Dinner",
                 currency: "USD",
                 lines: [line(category, 4_200, "cash", nil, nil)]
               },
               scope: member
             )
             |> Ash.create()

    assert Exception.message(error) =~ "receipt is required"

    assert %ExpenseReport{total_cents: 4_200} =
             report!(member, org, category, nil, [
               line(category, 4_200, "cash", nil, "receipt-dinner")
             ])
  end

  test "a category cap refuses an over-cap line; the boundary passes", %{
    org: org,
    member: member,
    admin: admin
  } do
    books = books!(admin, org)
    category = category!(admin, org, books.expense, "Taxi", %{max_amount_cents: 5_000})

    assert {:error, error} =
             ExpenseReport
             |> Ash.Changeset.for_create(
               :create,
               %{
                 org_id: org,
                 employee_id: Ash.UUID.generate(),
                 title: "Airport",
                 currency: "USD",
                 lines: [line(category, 5_001, "cash", nil, "receipt-taxi")]
               },
               scope: member
             )
             |> Ash.create()

    assert Exception.message(error) =~ "category limit"

    assert %ExpenseReport{total_cents: 5_000} =
             report!(member, org, category, nil, [
               line(category, 5_000, "cash", nil, "receipt-taxi")
             ])
  end

  test "a foreign-org category is refused; the same-org control passes", %{
    org: org,
    member: member,
    admin: admin
  } do
    books = books!(admin, org)
    category = category!(admin, org, books.expense, "Travel")
    foreign_org = Ash.UUID.generate()
    foreign_books = books!(admin_scope(foreign_org), foreign_org)

    foreign_category =
      category!(admin_scope(foreign_org), foreign_org, foreign_books.expense, "Travel")

    assert {:error, error} =
             ExpenseReport
             |> Ash.Changeset.for_create(
               :create,
               %{
                 org_id: org,
                 employee_id: Ash.UUID.generate(),
                 title: "Foreign category",
                 currency: "USD",
                 lines: [line(foreign_category, 1_000, "cash", nil, "receipt")]
               },
               scope: member
             )
             |> Ash.create()

    assert Exception.message(error) =~ "not available in this org"

    assert %ExpenseReport{} =
             report!(member, org, category, nil, [
               line(category, 1_000, "cash", nil, "receipt")
             ])
  end

  test "a non-functional-currency report is refused; the functional currency passes", %{
    org: org,
    member: member,
    admin: admin
  } do
    books = books!(admin, org)
    category = category!(admin, org, books.expense, "Travel")

    SamenCore.Support.FinanceFixture.OrgFxSettings
    |> Ash.Changeset.for_create(:create, %{org_id: org, base_currency: "CAD"}, scope: admin)
    |> Ash.create!()

    assert {:error, error} =
             ExpenseReport
             |> Ash.Changeset.for_create(
               :create,
               %{
                 org_id: org,
                 employee_id: Ash.UUID.generate(),
                 title: "USD report",
                 currency: "USD",
                 lines: [line(category, 1_000, "cash", nil, "r")]
               },
               scope: member
             )
             |> Ash.create()

    assert Exception.message(error) =~ "functional currency (CAD)"

    assert %ExpenseReport{currency: "CAD"} =
             report!(member, org, category, nil, [line(category, 1_000, "cash", nil, "r")], "CAD")
  end

  test "the state machine refuses a second submit and an unsubmitted approval", %{
    org: org,
    member: member,
    admin: admin
  } do
    books = books!(admin, org)
    category = category!(admin, org, books.expense, "Travel")
    report = report!(member, org, category, nil, [line(category, 1_000, "cash", nil, "r")])

    submitted = submit!(report, member)

    assert {:error, error} =
             submitted
             |> Ash.Changeset.for_update(:submit, %{}, scope: member)
             |> Ash.update()

    assert Exception.message(error) =~ "cannot transition"

    draft = report!(member, org, category, nil, [line(category, 1_000, "cash", nil, "r")])

    assert {:error, error} =
             draft
             |> Ash.Changeset.for_update(:approve, %{}, scope: member)
             |> Ash.update()

    assert Exception.message(error) =~ "cannot transition"
  end

  test "an admin's cancellation withdraws the member's pending approval", %{
    org: org,
    member: member,
    admin: admin
  } do
    books = books!(admin, org)
    category = category!(admin, org, books.expense, "Travel")
    card = card!(admin, org, books.card_liability, "Travel card")

    report =
      report!(member, org, category, card, [
        line(category, 120_000, "personal_card", nil, "receipt-1"),
        line(category, 80_000, "corporate_card", card, "receipt-2")
      ])

    submitted = submit!(report, member)
    assert {:gated, approval_id} = gate(submitted, member)

    kind = Samen.Approvals.Gate.kind_for(ExpenseReport, :approve)
    assert {:ok, pending} = Samen.Approvals.list_pending(org, kind)
    assert Enum.any?(pending, &(&1.id == approval_id))

    # The ADMIN withdraws the member's report; the approval belongs to the member,
    # so the domain must withdraw it via that recorded requester, not the admin.
    cancelled =
      submitted
      |> Ash.Changeset.for_update(:cancel, %{}, scope: admin)
      |> Ash.update!()

    assert cancelled.status == :cancelled

    assert {:ok, %{state: :cancelled, decided_by: nil}} =
             Samen.Approvals.get(approval_id)

    assert {:ok, []} = Samen.Approvals.list_pending(org, kind)

    # The withdrawal is audited as the REQUESTER's cancellation: exactly one
    # `approval_cancelled` event, attributed to the member — never the admin.
    assert audit_events(approval_id, "approval_cancelled") == ["approval_cancelled"]
    assert audit_actors(approval_id, "approval_cancelled") == [member.actor.id]

    assert audit_events(approval_id, "approval_approved") == []
    assert audit_events(approval_id, "approval_rejected") == []
    refute admin.actor.id in audit_actors(approval_id, "approval_cancelled")

    # A late decision is refused; the report cannot be approved and nothing posts.
    assert {:error, :not_pending} = decide(approval_id)

    assert {:error, error} =
             cancelled
             |> Ash.Changeset.for_update(:approve, %{}, scope: member)
             |> Ash.update()

    assert Exception.message(error) =~ "cannot transition"

    still_cancelled = Ash.get!(ExpenseReport, report.id, authorize?: false)
    assert still_cancelled.status == :cancelled
    assert still_cancelled.approved_at == nil
    assert still_cancelled.posted_entry_id == nil
    assert still_cancelled.settlement_entry_id == nil
    assert {:ok, nil} = entry(org, "expense_report", report.id)
    assert {:ok, nil} = entry(org, "expense_settlement", report.id)

    # Control: the same cancellation with NO pending approval succeeds and
    # fabricates no approval-cancellation audit.
    no_approval_report =
      report!(member, org, category, nil, [line(category, 1_000, "cash", nil, "r")])
      |> submit!(member)

    cancelled_without_approval =
      no_approval_report
      |> Ash.Changeset.for_update(:cancel, %{}, scope: admin)
      |> Ash.update!()

    assert cancelled_without_approval.status == :cancelled
    assert {:ok, []} = Samen.Approvals.list_pending(org, kind)

    no_approval_subject_ref =
      "samen:#{Samen.Info.abbrev(ExpenseReport)}:#{no_approval_report.id}"

    assert audit_events_for_subject(no_approval_subject_ref, "approval_cancelled") == []

    assert @repo.aggregate(
             from(a in AuditEvent, where: a.event_type == "approval_cancelled"),
             :count
           ) == 1
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp books!(admin, org) do
    expense = account!(admin, org, "6000", :expense, :debit)
    cash = account!(admin, org, "1000", :asset, :debit)
    card_liability = account!(admin, org, "2100", :liability, :credit)
    employee_payable = account!(admin, org, "2200", :liability, :credit)

    for {key, account} <- [
          {:cash, cash},
          {:employee_reimbursement_payable, employee_payable}
        ] do
      PostingAccount
      |> Ash.Changeset.for_create(:create, %{org_id: org, key: key, account_id: account.id},
        scope: admin
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

  defp account!(admin, org, code, kind, side) do
    Account
    |> Ash.Changeset.for_create(
      :create,
      %{
        org_id: org,
        code: code,
        name: "Account #{code}",
        kind: kind,
        normal_side: side
      },
      scope: admin
    )
    |> Ash.create!()
  end

  defp category!(admin, org, account, name, attrs \\ %{}) do
    ExpenseCategory
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(
        %{
          org_id: org,
          name: name,
          account_id: account.id,
          requires_receipt: false,
          max_amount_cents: nil,
          is_active: true
        },
        attrs
      ),
      scope: admin
    )
    |> Ash.create!()
  end

  defp card!(admin, org, account, name) do
    CorporateCard
    |> Ash.Changeset.for_create(
      :create,
      %{
        org_id: org,
        name: name,
        last4: "4242",
        cardholder_id: Ash.UUID.generate(),
        account_id: account.id,
        currency: "USD",
        is_active: true
      },
      scope: admin
    )
    |> Ash.create!()
  end

  defp report!(scope, org, _category, _card, lines, currency \\ "USD") do
    ExpenseReport
    |> Ash.Changeset.for_create(
      :create,
      %{
        org_id: org,
        employee_id: Ash.UUID.generate(),
        title: "Expense report",
        currency: currency,
        lines: lines
      },
      scope: scope
    )
    |> Ash.create!()
  end

  defp line(category, amount, method, card, receipt) do
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

  defp submit!(report, scope) do
    report
    |> Ash.Changeset.for_update(:submit, %{}, scope: scope)
    |> Ash.update!()
  end

  defp gate(report, scope) do
    result =
      report
      |> Ash.Changeset.for_update(:approve, %{}, scope: scope)
      |> Ash.update()

    case result do
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

  defp decide(approval_id) do
    Samen.Approvals.approve(approval_id, "a2:decider",
      approval_resource: SamenCore.Support.ApprovalsFixture.Approval,
      repo: @repo
    )
  end

  defp audit_events(approval_id, event_type) do
    @repo.all(
      from(a in AuditEvent,
        where: a.correlation_id == ^approval_id and a.event_type == ^event_type,
        select: a.event_type
      )
    )
  end

  defp audit_actors(approval_id, event_type) do
    @repo.all(
      from(a in AuditEvent,
        where: a.correlation_id == ^approval_id and a.event_type == ^event_type,
        select: a.actor_id
      )
    )
  end

  defp audit_events_for_subject(subject_ref, event_type) do
    @repo.all(
      from(a in AuditEvent,
        where: a.subject_id == ^subject_ref and a.event_type == ^event_type,
        select: a.event_type
      )
    )
  end

  defp entry(org, source_key, source_id) do
    JournalEntry
    |> Ash.Query.filter(org_id == ^org and source_key == ^source_key and source_id == ^source_id)
    |> Ash.read_one(authorize?: false)
  end

  defp entry!(org, source_key, source_id) do
    {:ok, entry} = entry(org, source_key, source_id)
    entry
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

  defp member_scope(org_id) do
    %Samen.Scope{
      actor: %{id: "u:#{org_id}", org_id: org_id, role: :member, kind: :tenant, plane: :tenant}
    }
  end

  defp admin_scope(org_id) do
    %Samen.Scope{
      actor: %{
        id: "a:#{org_id}",
        org_id: org_id,
        role: :admin,
        kind: :tenant,
        plane: :tenant
      }
    }
  end
end
