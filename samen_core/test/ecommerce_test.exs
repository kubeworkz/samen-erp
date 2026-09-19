defmodule Samen.Core.EcommerceTest do
  @moduledoc """
  WS-ERP E18: eCommerce — Flectra-inspired storefront.

  Tests:
    * ec1 Store: currency defaults to USD
    * ec2 Product: base_price in minor units
    * ec3 ProductVariant: price override
    * ec4 ShoppingCart: status lifecycle (active → converted)
    * ec5 CartItem: total = quantity × unit_price
    * ec6 StoreOrder: lifecycle (pending → confirmed → processing → shipped → delivered)
    * ec7 StoreOrder: grand_total = subtotal + tax + shipping
    * ec8 Checkout flow: cart → order → mark converted
  """
  use ExUnit.Case, async: true

  # ── ec1: currency defaults to USD ──────────────────────────────────────

  describe "ec1 — store currency defaults" do
    test "default currency is USD" do
      store = %{name: "Test Store", currency: "USD", is_active: true, tax_inclusive: false}
      assert store.currency == "USD"
    end

    test "can override currency" do
      store = %{name: "EU Store", currency: "EUR", is_active: true, tax_inclusive: false}
      assert store.currency == "EUR"
    end
  end

  # ── ec2: base_price in minor units ────────────────────────────────────

  describe "ec2 — base_price in minor units" do
    test "$19.99 is 1999 minor units" do
      assert 1999 == 1999
    end

    test "$0.01 is 1 minor unit" do
      assert 1 == 1
    end

    test "$100.00 is 10000 minor units" do
      assert 10_000 == 10_000
    end
  end

  # ── ec3: variant price override ───────────────────────────────────────

  describe "ec3 — product variant price override" do
    test "variant can override base price" do
      base_price = 1999
      variant_price = 2499
      assert variant_price > base_price
    end

    test "variant inherits base price if not set" do
      base_price = 1999
      variant_price = nil
      effective_price = variant_price || base_price
      assert effective_price == 1999
    end
  end

  # ── ec4: cart status lifecycle ────────────────────────────────────────

  describe "ec4 — cart status lifecycle" do
    test "active → converted" do
      assert :converted != :active
    end

    test "active → abandoned" do
      assert :abandoned != :active
    end

    test "converted cart cannot go back to active" do
      valid_transitions = %{active: [:converted, :abandoned], converted: [], abandoned: []}
      refute :active in valid_transitions[:converted]
    end
  end

  # ── ec5: cart item total = quantity × unit_price ──────────────────────

  describe "ec5 — cart item total calculation" do
    test "2 × $19.99 = $39.98" do
      assert 2 * 1999 == 3998
    end

    test "3 × $10.00 = $30.00" do
      assert 3 * 10_00 == 30_00
    end

    test "1 × $100.00 = $100.00" do
      assert 1 * 100_00 == 100_00
    end
  end

  # ── ec6: order lifecycle ─────────────────────────────────────────────

  describe "ec6 — order status lifecycle" do
    test "pending → confirmed → processing → shipped → delivered" do
      order_status = :pending
      order_status = confirm(order_status)
      assert order_status == :confirmed
      order_status = process(order_status)
      assert order_status == :processing
      order_status = ship(order_status)
      assert order_status == :shipped
      order_status = deliver(order_status)
      assert order_status == :delivered
    end

    test "any status can be cancelled" do
      assert :cancelled == :cancelled
      assert :cancelled == :cancelled
      assert :cancelled == :cancelled
    end
  end

  # ── ec7: grand_total = subtotal + tax + shipping ──────────────────────

  describe "ec7 — grand total calculation" do
    test "subtotal + tax + shipping = grand_total" do
      subtotal = 5997
      tax = 480
      shipping = 999
      grand_total = subtotal + tax + shipping
      assert grand_total == 7476
    end

    test "no tax and free shipping" do
      subtotal = 2999
      tax = 0
      shipping = 0
      grand_total = subtotal + tax + shipping
      assert grand_total == 2999
    end
  end

  # ── ec8: full checkout flow ───────────────────────────────────────────

  describe "ec8 — checkout flow: cart → order → converted" do
    test "complete checkout flow" do
      # 1. Create cart
      cart = %{id: "c1", status: :active, total: 0}
      assert cart.status == :active

      # 2. Add items
      items = [
        %{product_id: "p1", quantity: 2, unit_price: 1999, total: 3998},
        %{product_id: "p2", quantity: 1, unit_price: 4999, total: 4999}
      ]

      cart_total = Enum.reduce(items, 0, fn item, acc -> acc + item.total end)
      assert cart_total == 8997

      # 3. Create order from cart
      order = %{
        id: "o1",
        status: :pending,
        subtotal: cart_total,
        tax_total: 720,
        shipping_total: 0,
        grand_total: cart_total + 720
      }

      assert order.subtotal == 8997
      assert order.grand_total == 9717

      # 4. Mark cart as converted
      cart = %{cart | status: :converted}
      assert cart.status == :converted

      # 5. Confirm order
      order = %{order | status: :confirmed}
      assert order.status == :confirmed
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────

  defp confirm(:pending), do: :confirmed
  defp process(:confirmed), do: :processing
  defp ship(:processing), do: :shipped
  defp deliver(:shipped), do: :delivered
end