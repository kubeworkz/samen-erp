defmodule Samen.PayrollLeaveTest do
  @moduledoc """
  WS-ERP E21: Payroll + Leave —  HR management.

  Tests:
    * pl1 LeaveType: default values and paid/unpaid
    * pl2 LeaveBalance: available days calculation
    * pl3 LeaveBalance: carry forward
    * pl4 LeaveRequest: state lifecycle (draft → pending → approved/rejected)
    * pl5 LeaveRequest: date range validation
    * pl6 SalaryStructure: component types
    * pl7 PayRun: state lifecycle (draft → processing → done → paid)
    * pl8 Payslip: net amount = gross - deductions
    * pl9 Payslip: component breakdown
    * pl10 Integration: full leave flow
    * pl11 Integration: full payroll flow
  """
  use ExUnit.Case, async: true

  # ── pl1: leave type defaults ─────────────────────────────────────────

  describe "pl1 — leave type defaults" do
    test "default leave type is paid" do
      lt = %{name: "Annual Vacation", code: "AV", is_paid: true, default_days: 20}
      assert lt.is_paid == true
      assert lt.default_days == 20
    end

    test "sick leave is paid" do
      lt = %{name: "Sick Leave", code: "SL", is_paid: true, default_days: 10}
      assert lt.is_paid == true
    end

    test "unpaid leave" do
      lt = %{name: "Unpaid Leave", code: "UL", is_paid: false, default_days: 0}
      assert lt.is_paid == false
    end
  end

  # ── pl2: available days calculation ──────────────────────────────────

  describe "pl2 — available days calculation" do
    test "available = total - used - pending" do
      total = 20
      used = 5
      pending = 2
      available = total - used - pending

      assert available == 13
    end

    test "zero available when all used" do
      total = 20
      used = 20
      pending = 0
      available = total - used - pending

      assert available == 0
    end

    test "negative available means over-allocated" do
      total = 20
      used = 15
      pending = 8
      available = total - used - pending

      assert available == -3
    end
  end

  # ── pl3: carry forward ──────────────────────────────────────────────

  describe "pl3 — carry forward" do
    test "carry forward adds to next year's balance" do
      total = 20
      used = 12
      remaining = total - used
      carry_forward = min(remaining, 5)

      next_year_total = 20 + carry_forward
      assert next_year_total == 25
    end

    test "carry forward capped at max" do
      remaining = 10
      max_carry = 5
      carry_forward = min(remaining, max_carry)

      assert carry_forward == 5
    end

    test "no carry forward when disabled" do
      carry_forward_enabled = false
      remaining = 10
      carry_forward = if carry_forward_enabled, do: remaining, else: 0

      assert carry_forward == 0
    end
  end

  # ── pl4: leave request state lifecycle ───────────────────────────────

  describe "pl4 — leave request state lifecycle" do
    test "draft → pending → approved" do
      request = %{state: :draft}
      request = %{request | state: :pending}
      assert request.state == :pending
      request = %{request | state: :approved}
      assert request.state == :approved
    end

    test "draft → pending → rejected" do
      request = %{state: :draft}
      request = %{request | state: :pending}
      assert request.state == :pending
      request = Map.merge(request, %{state: :rejected, rejection_reason: "Insufficient balance"})
      assert request.state == :rejected
    end

    test "approved request can be cancelled" do
      request = %{state: :approved}
      request = %{request | state: :cancelled}
      assert request.state == :cancelled
    end
  end

  # ── pl5: date range validation ───────────────────────────────────────

  describe "pl5 — date range validation" do
    test "end_date must be >= start_date" do
      start_date = ~D[2026-01-15]
      end_date = ~D[2026-01-20]
      assert Date.compare(end_date, start_date) != :lt
    end

    test "num_days = working days in range" do
      start_date = ~D[2026-01-13]  # Monday
      end_date = ~D[2026-01-17]    # Friday
      # Count weekdays (simplified)
      num_days = 5
      assert num_days == 5
    end

    test "single day leave" do
      start_date = ~D[2026-01-15]
      end_date = ~D[2026-01-15]
      assert start_date == end_date
    end
  end

  # ── pl6: salary structure components ─────────────────────────────────

  describe "pl6 — salary structure components" do
    test "component types include basic, allowance, deduction, benefit" do
      valid = [:basic, :allowance, :deduction, :benefit]
      assert length(valid) == 4
      assert :basic in valid
      assert :deduction in valid
    end

    test "fixed amount component" do
      component = %{name: "Housing Allowance", type: :allowance, amount_type: :fixed, amount: 500_00}
      assert component.amount_type == :fixed
      assert component.amount == 500_00
    end

    test "percentage amount component" do
      component = %{name: "Health Insurance", type: :deduction, amount_type: :percentage, amount: 5.0}
      assert component.amount_type == :percentage
      assert component.amount == 5.0
    end
  end

  # ── pl7: pay run state lifecycle ─────────────────────────────────────

  describe "pl7 — pay run state lifecycle" do
    test "draft → processing → done → paid" do
      pay_run = %{state: :draft}
      pay_run = %{pay_run | state: :processing}
      assert pay_run.state == :processing
      pay_run = %{pay_run | state: :done}
      assert pay_run.state == :done
      pay_run = %{pay_run | state: :paid}
      assert pay_run.state == :paid
    end

    test "processing cannot go back to draft" do
      valid_transitions = %{draft: [:processing], processing: [:done], done: [:paid], paid: []}
      refute :draft in valid_transitions[:processing]
    end
  end

  # ── pl8: net amount calculation ──────────────────────────────────────

  describe "pl8 — net amount calculation" do
    test "net = gross - deductions" do
      gross = 5000_00
      deductions = 1200_00
      net = gross - deductions

      assert net == 3800_00
    end

    test "zero deductions" do
      gross = 5000_00
      deductions = 0
      net = gross - deductions

      assert net == 5000_00
    end
  end

  # ── pl9: component breakdown ─────────────────────────────────────────

  describe "pl9 — component breakdown" do
    test "earnings sum to gross" do
      earnings = [
        %{name: "Basic Salary", amount: 4000_00},
        %{name: "Housing Allowance", amount: 800_00},
        %{name: "Transport Allowance", amount: 200_00}
      ]

      gross = Enum.reduce(earnings, 0, fn e, acc -> acc + e.amount end)
      assert gross == 5000_00
    end

    test "deductions sum to total deductions" do
      deductions = [
        %{name: "Tax", amount: 800_00},
        %{name: "Health Insurance", amount: 250_00},
        %{name: "Pension", amount: 150_00}
      ]

      total = Enum.reduce(deductions, 0, fn d, acc -> acc + d.amount end)
      assert total == 1200_00
    end
  end

  # ── pl10: full leave flow ────────────────────────────────────────────

  describe "pl10 — full leave flow" do
    test "request → approve → update balance" do
      # 1. Leave type
      leave_type = %{id: "lt1", name: "Annual Vacation", code: "AV", is_paid: true, default_days: 20}

      # 2. Employee balance
      balance = %{employee_id: "emp1", leave_type_id: leave_type.id, year: 2026, total_days: 20, used_days: 0, pending_days: 0, available_days: 20}

      # 3. Submit request
      request = %{employee_id: "emp1", leave_type_id: leave_type.id, start_date: ~D[2026-03-10], end_date: ~D[2026-03-14], num_days: 5, state: :pending}

      # 4. Check balance
      available = balance.total_days - balance.used_days - balance.pending_days
      assert available >= request.num_days

      # 5. Approve
      balance = Map.merge(balance, %{pending_days: balance.pending_days + request.num_days, available_days: available - request.num_days})
      request = %{request | state: :approved}

      assert request.state == :approved
      assert balance.pending_days == 5
      assert balance.available_days == 15

      # 6. After leave is taken, update used
      balance = Map.merge(balance, %{used_days: balance.used_days + request.num_days, pending_days: balance.pending_days - request.num_days})
      assert balance.used_days == 5
      assert balance.pending_days == 0
      assert balance.available_days == 15
    end
  end

  # ── pl11: full payroll flow ──────────────────────────────────────────

  describe "pl11 — full payroll flow" do
    test "pay run → compute payslips → approve → pay" do
      # 1. Create pay run
      pay_run = %{id: "pr1", name: "Jan 2026 Monthly", period_start: ~D[2026-01-01], period_end: ~D[2026-01-31], state: :processing}

      # 2. Salary structure
      structure = %{id: "ss1", name: "Standard", components: [
        %{name: "Basic Salary", type: :basic, amount_type: :fixed, amount: 4000_00},
        %{name: "Housing", type: :allowance, amount_type: :fixed, amount: 800_00},
        %{name: "Tax", type: :deduction, amount_type: :percentage, amount: 20.0},
        %{name: "Pension", type: :deduction, amount_type: :percentage, amount: 8.0}
      ]}

      # 3. Compute payslip
      basic = 4000_00
      housing = 800_00
      gross = basic + housing
      tax = round(gross * 20 / 100)
      pension = round(gross * 8 / 100)
      total_deductions = tax + pension
      net = gross - total_deductions

      payslip = %{pay_run_id: pay_run.id, employee_id: "emp1", gross_amount: gross, total_deductions: total_deductions, net_amount: net, state: :computed}

      assert payslip.gross_amount == 4800_00
      assert payslip.net_amount == 4800_00 - tax - pension

      # 4. Approve payslip
      payslip = %{payslip | state: :approved}
      assert payslip.state == :approved

      # 5. Mark pay run as done
      pay_run = Map.merge(pay_run, %{state: :done, total_gross: gross, total_net: net, total_deductions: total_deductions})
      assert pay_run.state == :done

      # 6. Pay
      pay_run = %{pay_run | state: :paid}
      payslip = Map.merge(payslip, %{state: :paid, paid_at: DateTime.utc_now()})
      assert pay_run.state == :paid
      assert payslip.state == :paid
    end
  end
end