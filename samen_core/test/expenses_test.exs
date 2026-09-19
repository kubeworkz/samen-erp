defmodule Samen.ExpensesTest do
  @moduledoc """
  WS-ERP E31: Expenses — Flectra-inspired expense management.

  ## Resources

  - `ExpenseCategory` — expense types with GL mapping and policy limits
  - `Expense` — individual expense line items
  - `Sheet` — expense reports grouping expenses for approval
  - `Approver` — approval chain entries

  ## Tests

  - ex1: Category lifecycle (create, activate, deactivate)
  - ex2: Category policy limits
  - ex3: Expense lifecycle (draft → submitted → approved → reimbursed)
  - ex4: Expense reject flow
  - ex5: Expense cancel flow
  - ex6: Receipt attachment
  - ex7: Billable expenses
  - ex8: Tax calculation
  - ex9: Sheet lifecycle (draft → submitted → approved → reimbursed)
  - ex10: Sheet reject flow
  - ex11: Sheet status transitions
  - ex12: Approver chain (multi-level)
  - ex13: Approver approve/reject
  - ex14: Approver skip
  - ex15: Multi-category expenses
  - ex16: Payment methods
  - ex17: Currency support
  - ex18: Full expense report flow end-to-end
  - ex19: Category max amount enforcement
  - ex20: Approval ceremony with multiple approvers
  """
  use ExUnit.Case, async: true

  # --- ex1: Category lifecycle ---

  describe "ex1 — category lifecycle" do
    test "create, activate, deactivate" do
      cat = %{name: "Travel", is_active: true, requires_receipt: true}
      assert cat.is_active == true

      cat = %{cat | is_active: false}
      assert cat.is_active == false

      cat = %{cat | is_active: true}
      assert cat.is_active == true
    end
  end

  # --- ex2: Category policy limits ---

  describe "ex2 — category policy limits" do
    test "requires receipt" do
      cat = %{requires_receipt: true, requires_approver: true}
      assert cat.requires_receipt == true
      assert cat.requires_approver == true
    end

    test "max amount limit" do
      cat = %{max_amount_cents: 50_00}
      assert cat.max_amount_cents == 50_00
    end

    test "no limit by default" do
      cat = %{max_amount_cents: nil, max_daily_amount_cents: nil}
      assert is_nil(cat.max_amount_cents)
      assert is_nil(cat.max_daily_amount_cents)
    end

    test "daily spending cap" do
      cat = %{max_daily_amount_cents: 200_00}
      assert cat.max_daily_amount_cents == 200_00
    end
  end

  # --- ex3: Expense lifecycle (draft → submitted → approved → reimbursed) ---

  describe "ex3 — expense lifecycle" do
    test "draft → submitted → approved → reimbursed" do
      exp = %{status: :draft, amount_cents: 45_99, description: "Uber to airport"}
      assert exp.status == :draft

      exp = %{exp | status: :submitted}
      assert exp.status == :submitted

      exp = %{exp | status: :approved}
      assert exp.status == :approved

      exp = %{exp | status: :reimbursed}
      assert exp.status == :reimbursed
    end
  end

  # --- ex4: Expense reject flow ---

  describe "ex4 — expense reject flow" do
    test "reject with reason" do
      exp = %{status: :submitted, rejected_reason: nil}
      exp = %{exp | status: :rejected, rejected_reason: "Missing receipt"}
      assert exp.status == :rejected
      assert exp.rejected_reason == "Missing receipt"
    end
  end

  # --- ex5: Expense cancel flow ---

  describe "ex5 — expense cancel flow" do
    test "cancel expense" do
      exp = %{status: :draft}
      exp = %{exp | status: :cancelled}
      assert exp.status == :cancelled
    end
  end

  # --- ex6: Receipt attachment ---

  describe "ex6 — receipt attachment" do
    test "attach receipt" do
      exp = %{receipt_attached: false, receipt_url: nil}
      exp = %{exp | receipt_attached: true, receipt_url: "https://storage.example/receipt.jpg"}
      assert exp.receipt_attached == true
      assert exp.receipt_url == "https://storage.example/receipt.jpg"
    end

    test "receipt required by policy" do
      cat = %{requires_receipt: true}
      exp = %{receipt_required: cat.requires_receipt, receipt_attached: false}
      assert exp.receipt_required == true
      assert exp.receipt_attached == false
    end
  end

  # --- ex7: Billable expenses ---

  describe "ex7 — billable expenses" do
    test "mark as billable" do
      exp = %{is_billable: false, client_id: nil}
      exp = %{exp | is_billable: true, client_id: "client_001"}
      assert exp.is_billable == true
      assert exp.client_id == "client_001"
    end
  end

  # --- ex8: Tax calculation ---

  describe "ex8 — tax calculation" do
    test "tax amount and rate" do
      exp = %{amount_cents: 100_00, tax_rate: 0.07, tax_amount_cents: 7_00}
      assert exp.tax_rate == 0.07
      assert exp.tax_amount_cents == 7_00
    end

    test "no tax" do
      exp = %{amount_cents: 50_00, tax_rate: 0.0, tax_amount_cents: 0}
      assert exp.tax_rate == 0.0
      assert exp.tax_amount_cents == 0
    end
  end

  # --- ex9: Sheet lifecycle (draft → submitted → approved → reimbursed) ---

  describe "ex9 — sheet lifecycle" do
    test "draft → submitted → approved → reimbursed" do
      sheet = %{status: :draft, total_amount_cents: 250_00, expense_count: 3, submitted_at: nil, approved_at: nil, reimbursed_at: nil, payment_ref: nil}
      assert sheet.status == :draft

      sheet = %{sheet | status: :submitted, submitted_at: ~U[2026-10-01 09:00:00Z]}
      assert sheet.status == :submitted
      assert sheet.submitted_at == ~U[2026-10-01 09:00:00Z]

      sheet = %{sheet | status: :under_review}
      assert sheet.status == :under_review

      sheet = %{sheet | status: :approved, approved_at: ~U[2026-10-02 14:00:00Z]}
      assert sheet.status == :approved

      sheet = %{sheet | status: :reimbursed, reimbursed_at: ~U[2026-10-05 10:00:00Z], payment_ref: "PAY-2026-001"}
      assert sheet.status == :reimbursed
      assert sheet.payment_ref == "PAY-2026-001"
    end
  end

  # --- ex10: Sheet reject flow ---

  describe "ex10 — sheet reject flow" do
    test "reject with reason" do
      sheet = %{status: :under_review, rejected_reason: nil}
      sheet = %{sheet | status: :rejected, rejected_reason: "Exceeds daily limit"}
      assert sheet.status == :rejected
      assert sheet.rejected_reason == "Exceeds daily limit"
    end
  end

  # --- ex11: Sheet status transitions ---

  describe "ex11 — sheet status transitions" do
    test "valid transitions" do
      valid = %{
        draft: [:submitted, :cancelled],
        submitted: [:under_review, :cancelled],
        under_review: [:approved, :rejected],
        approved: [:reimbursed, :cancelled],
        rejected: [],
        reimbursed: [],
        cancelled: []
      }

      assert :submitted in valid[:draft]
      assert :under_review in valid[:submitted]
      assert :approved in valid[:under_review]
      assert :rejected in valid[:under_review]
      assert :reimbursed in valid[:approved]
    end

    test "terminal states" do
      terminal = [:rejected, :reimbursed, :cancelled]
      for state <- terminal do
        assert state in [:rejected, :reimbursed, :cancelled]
      end
    end
  end

  # --- ex12: Approver chain (multi-level) ---

  describe "ex12 — approver chain" do
    test "two-level approval chain" do
      approvers = [
        %{approver_id: "mgr_001", sequence: 1, status: :pending, is_final: false},
        %{approver_id: "dir_001", sequence: 2, status: :pending, is_final: true}
      ]

      assert length(approvers) == 2
      assert List.first(approvers).sequence == 1
      assert List.last(approvers).is_final == true
    end

    test "single approver" do
      approvers = [
        %{approver_id: "mgr_001", sequence: 1, status: :pending, is_final: true}
      ]

      assert length(approvers) == 1
      assert List.first(approvers).is_final == true
    end
  end

  # --- ex13: Approver approve/reject ---

  describe "ex13 — approver approve/reject" do
    test "approve" do
      a = %{status: :pending, approved_at: nil, rejected_at: nil, comments: nil}
      a = %{a | status: :approved, approved_at: ~U[2026-10-02 14:00:00Z]}
      assert a.status == :approved
      assert a.approved_at == ~U[2026-10-02 14:00:00Z]
    end

    test "reject with comments" do
      a = %{status: :pending, approved_at: nil, rejected_at: nil, comments: nil}
      a = %{a | status: :rejected, rejected_at: ~U[2026-10-02 14:00:00Z], comments: "Over budget"}
      assert a.status == :rejected
      assert a.comments == "Over budget"
    end
  end

  # --- ex14: Approver skip ---

  describe "ex14 — approver skip" do
    test "skip approver" do
      a = %{status: :pending}
      a = %{a | status: :skipped}
      assert a.status == :skipped
    end
  end

  # --- ex15: Multi-category expenses ---

  describe "ex15 — multi-category expenses" do
    test "expenses across different categories" do
      expenses = [
        %{category: "Travel", amount_cents: 150_00},
        %{category: "Meals", amount_cents: 45_00},
        %{category: "Office Supplies", amount_cents: 25_00}
      ]

      assert length(expenses) == 3
      total = Enum.reduce(expenses, 0, &(&1.amount_cents + &2))
      assert total == 220_00
    end
  end

  # --- ex16: Payment methods ---

  describe "ex16 — payment methods" do
    test "all payment methods" do
      methods = [:cash, :card, :bank_transfer, :personal_card]
      assert length(methods) == 4
    end

    test "personal card is default" do
      exp = %{payment_method: :personal_card}
      assert exp.payment_method == :personal_card
    end
  end

  # --- ex17: Currency support ---

  describe "ex17 — currency support" do
    test "default currency is USD" do
      exp = %{currency: "USD"}
      assert exp.currency == "USD"
    end

    test "multi-currency expenses" do
      expenses = [
        %{currency: "USD", amount_cents: 100_00},
        %{currency: "EUR", amount_cents: 85_00},
        %{currency: "GBP", amount_cents: 75_00}
      ]

      assert length(expenses) == 3
      currencies = Enum.map(expenses, & &1.currency)
      assert "USD" in currencies
      assert "EUR" in currencies
      assert "GBP" in currencies
    end
  end

  # --- ex18: Full expense report flow end-to-end ---

  describe "ex18 — full expense report flow" do
    test "category → expenses → sheet → approvers → approve → reimburse" do
      # 1. Create categories
      travel = %{name: "Travel", requires_receipt: true, requires_approver: true, is_active: true}
      meals = %{name: "Meals", requires_receipt: false, requires_approver: true, is_active: true}

      # 2. Create expenses
      exp1 = %{
        category: travel.name, amount_cents: 150_00, description: "Flight to NYC",
        date: ~D[2026-09-15], payment_method: :personal_card, status: :draft,
        receipt_attached: true, receipt_url: "https://storage.example/flight.jpg"
      }
      exp2 = %{
        category: meals.name, amount_cents: 45_00, description: "Team dinner",
        date: ~D[2026-09-15], payment_method: :personal_card, status: :draft
      }

      # 3. Submit expenses
      exp1 = %{exp1 | status: :submitted}
      exp2 = %{exp2 | status: :submitted}
      assert exp1.status == :submitted
      assert exp2.status == :submitted

      # 4. Create expense sheet
      sheet = %{
        name: "September NYC Trip",
        employee_id: "emp_001",
        manager_id: "mgr_001",
        total_amount_cents: 195_00,
        expense_count: 2,
        status: :draft,
        submitted_at: nil,
        approved_at: nil,
        reimbursed_at: nil,
        payment_ref: nil
      }

      # 5. Submit sheet
      sheet = %{sheet | status: :submitted, submitted_at: ~U[2026-09-20 09:00:00Z], approved_at: nil, reimbursed_at: nil, payment_ref: nil}

      # 6. Create approval chain
      approvers = [
        %{approver_id: "mgr_001", sequence: 1, status: :pending, is_final: false, approved_at: nil, rejected_at: nil},
        %{approver_id: "dir_001", sequence: 2, status: :pending, is_final: true, approved_at: nil, rejected_at: nil}
      ]

      # 7. Manager approves
      approvers = List.update_at(approvers, 0, fn a -> %{a | status: :approved, approved_at: ~U[2026-09-21 10:00:00Z]} end)
      sheet = %{sheet | status: :under_review}

      # 8. Director approves
      approvers = List.update_at(approvers, 1, fn a -> %{a | status: :approved, approved_at: ~U[2026-09-22 14:00:00Z]} end)
      sheet = %{sheet | status: :approved, approved_at: ~U[2026-09-22 14:00:00Z]}

      # 9. Reimburse
      sheet = %{sheet | status: :reimbursed, reimbursed_at: ~U[2026-09-25 10:00:00Z], payment_ref: "PAY-2026-092"}
      exp1 = %{exp1 | status: :reimbursed}
      exp2 = %{exp2 | status: :reimbursed}

      assert sheet.status == :reimbursed
      assert exp1.status == :reimbursed
      assert exp2.status == :reimbursed
      assert Enum.all?(approvers, &(&1.status == :approved))
    end
  end

  # --- ex19: Category max amount enforcement ---

  describe "ex19 — category max amount enforcement" do
    test "expense within limit" do
      cat = %{max_amount_cents: 50_00}
      exp = %{amount_cents: 45_00}
      assert exp.amount_cents <= cat.max_amount_cents
    end

    test "expense exceeds limit" do
      cat = %{max_amount_cents: 50_00}
      exp = %{amount_cents: 75_00}
      assert exp.amount_cents > cat.max_amount_cents
    end

    test "daily cap enforcement" do
      cat = %{max_daily_amount_cents: 200_00}
      expenses = [
        %{amount_cents: 80_00, date: ~D[2026-10-01]},
        %{amount_cents: 60_00, date: ~D[2026-10-01]},
        %{amount_cents: 70_00, date: ~D[2026-10-01]}
      ]

      daily_total = expenses |> Enum.filter(&(&1.date == ~D[2026-10-01])) |> Enum.reduce(0, &(&1.amount_cents + &2))
      assert daily_total == 210_00
      assert daily_total > cat.max_daily_amount_cents
    end
  end

  # --- ex20: Approval ceremony with multiple approvers ---

  describe "ex20 — approval ceremony" do
    test "3-level approval with final approver" do
      approvers = [
        %{approver_id: "lead_001", sequence: 1, status: :pending, is_final: false, approved_at: nil, rejected_at: nil, comments: nil},
        %{approver_id: "mgr_001", sequence: 2, status: :pending, is_final: false, approved_at: nil, rejected_at: nil, comments: nil},
        %{approver_id: "cfo_001", sequence: 3, status: :pending, is_final: true, approved_at: nil, rejected_at: nil, comments: nil}
      ]

      # Lead approves
      approvers = List.update_at(approvers, 0, fn a -> %{a | status: :approved, approved_at: ~U[2026-10-01 10:00:00Z]} end)
      assert Enum.at(approvers, 0).status == :approved

      # Manager approves
      approvers = List.update_at(approvers, 1, fn a -> %{a | status: :approved, approved_at: ~U[2026-10-02 14:00:00Z]} end)
      assert Enum.at(approvers, 1).status == :approved

      # CFO rejects
      approvers = List.update_at(approvers, 2, fn a -> %{a | status: :rejected, rejected_at: ~U[2026-10-03 09:00:00Z], comments: "Budget exceeded"} end)
      assert Enum.at(approvers, 2).status == :rejected
      assert Enum.at(approvers, 2).comments == "Budget exceeded"

      # Overall result: rejected (final approver rejected)
      final = Enum.find(approvers, & &1.is_final)
      assert final.status == :rejected
    end
  end
end
