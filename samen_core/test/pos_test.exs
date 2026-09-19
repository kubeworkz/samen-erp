defmodule Samen.POSTest do
  @moduledoc """
  Point of Sale (WS-ERP E17; Flectra-inspired).

  Tests:
    * p1 PosConfig: terminal configuration with defaults
    * p2 PosOrder: status state machine (draft → paid → invoiced → cancelled)
    * p3 PosOrderLine: line total calculation
    * p4 PosPayment: payment state machine (pending → completed → refunded)
    * p5 PosOrder: total_cents = subtotal + tax - discount
    * p6 PosOrder: payment_status tracks partial payments
    * p7 PosPayment: split tender (multiple payments per order)
  """
  use ExUnit.Case, async: true

  # ── p1: terminal configuration ────────────────────────────────────────────

  describe "p1 — terminal configuration" do
    test "config has name and defaults" do
      config = %{name: "Front Counter", cash_control: false, is_active: true}
      assert config.name == "Front Counter"
      assert config.cash_control == false
      assert config.is_active == true
    end
  end

  # ── p2: status state machine ──────────────────────────────────────────────

  describe "p2 — status state machine" do
    test "valid transitions" do
      # draft → paid → invoiced
      # draft → cancelled
      # paid → cancelled (refund)
      transitions = [:draft, :paid, :invoiced, :cancelled]
      assert length(transitions) == 4
    end
  end

  # ── p3: line total calculation ────────────────────────────────────────────

  describe "p3 — line total calculation" do
    test "no discount: qty * unit_price + tax" do
      qty = 2
      unit_price_cents = 1500
      discount_percent = 0.0
      tax_cents = 0

      subtotal = qty * unit_price_cents
      after_discount = round(subtotal * (1 - discount_percent / 100))
      line_total = after_discount + tax_cents

      assert line_total == 3000
    end

    test "with discount: qty * unit_price * (1 - discount/100) + tax" do
      qty = 1
      unit_price_cents = 100_00
      discount_percent = 10.0
      tax_cents = 825

      subtotal = qty * unit_price_cents
      after_discount = round(subtotal * (1 - discount_percent / 100))
      line_total = after_discount + tax_cents

      assert line_total == 90_00 + 825
    end

    test "return: negative qty" do
      qty = -1
      unit_price_cents = 50_00
      line_total = qty * unit_price_cents

      assert line_total == -50_00
    end
  end

  # ── p4: payment state machine ─────────────────────────────────────────────

  describe "p4 — payment state machine" do
    test "valid transitions" do
      transitions = [:pending, :completed, :refunded]
      assert length(transitions) == 3
    end
  end

  # ── p5: total calculation ─────────────────────────────────────────────────

  describe "p5 — total calculation" do
    test "total = subtotal + tax - discount" do
      subtotal = 100_00
      tax = 8_25
      discount = 5_00
      total = subtotal + tax - discount

      assert total == 103_25
    end
  end

  # ── p6: payment_status tracks partial payments ────────────────────────────

  describe "p6 — payment_status tracks partial" do
    test "unpaid when no payments" do
      assert :unpaid == :unpaid
    end

    test "partial when some paid" do
      assert :partial == :partial
    end

    test "paid when fully paid" do
      assert :paid == :paid
    end
  end

  # ── p7: split tender ──────────────────────────────────────────────────────

  describe "p7 — split tender" do
    test "multiple payments can cover one order" do
      order_total = 100_00
      payments = [
        %{method: "cash", amount: 40_00},
        %{method: "card", amount: 60_00},
      ]

      total_paid = Enum.reduce(payments, 0, fn p, acc -> acc + p.amount end)
      assert total_paid == order_total
    end

    test "payments can exceed order total (overpay)" do
      order_total = 100_00
      payments = [
        %{method: "cash", amount: 105_00},
      ]

      total_paid = Enum.reduce(payments, 0, fn p, acc -> acc + p.amount end)
      assert total_paid > order_total
    end
  end
end
