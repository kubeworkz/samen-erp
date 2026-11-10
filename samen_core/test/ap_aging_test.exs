defmodule Samen.ApAgingTest do
  @moduledoc """
  Pure AP aging/statement math. The host proof exercises the Ash-backed load;
  this suite pins the buckets, the approved-only basis, and the effective
  payment-run history (including reversed and legacy snapshots).
  """

  use ExUnit.Case, async: true

  alias Samen.Scopes.Finance.ApAging

  @as_of ~D[2026-03-31]

  defp bill(id, attrs) do
    Map.merge(
      %{
        id: id,
        vendor_id: "vendor-1",
        number: "BILL-#{id}",
        bill_date: ~D[2026-03-01],
        due_date: @as_of,
        amount_cents: 10_000,
        status: :approved
      },
      Map.new(attrs)
    )
  end

  defp run(id, attrs) do
    Map.merge(
      %{
        id: id,
        status: :paid,
        vendor_id: "vendor-1",
        vendor_name: "Vendor One",
        reference: "RUN-#{id}",
        payment_date: ~D[2026-03-15],
        payments: []
      },
      Map.new(attrs)
    )
  end

  defp payment(bill_id, amount, attrs \\ %{}) do
    Map.merge(
      %{
        "bill_id" => bill_id,
        "vendor_id" => "vendor-1",
        "number" => "BILL-#{bill_id}",
        "amount_cents" => amount
      },
      Map.new(attrs)
    )
  end

  test "ages only approved bills and places every bucket correctly" do
    bills = [
      bill("current", due_date: ~D[2026-04-10], amount_cents: 10_000),
      bill("1-30", due_date: ~D[2026-03-15], amount_cents: 20_000),
      bill("31-60", due_date: ~D[2026-02-15], amount_cents: 30_000),
      bill("61-90", due_date: ~D[2026-01-15], amount_cents: 40_000),
      bill("90+", due_date: ~D[2025-12-01], amount_cents: 50_000),
      bill("undated", due_date: nil, amount_cents: 5_000),
      bill("paid", status: :paid, amount_cents: 99_000),
      bill("draft", status: :draft, amount_cents: 98_000),
      bill("void", status: :void, amount_cents: 97_000)
    ]

    result = ApAging.aging(bills, as_of: @as_of)

    assert result.total_cents == 155_000

    assert result.buckets == %{
             current: 10_000,
             days_1_30: 20_000,
             days_31_60: 30_000,
             days_61_90: 40_000,
             days_90_plus: 50_000,
             undated: 5_000
           }

    by_id = Map.new(result.bills, &{&1.bill_id, &1})
    assert by_id["current"].days_overdue == 0
    assert by_id["31-60"].days_overdue == 44
    assert by_id["undated"].days_overdue == nil
    refute Map.has_key?(by_id, "paid")
    refute Map.has_key?(by_id, "draft")
    refute Map.has_key?(by_id, "void")
  end

  test "pins the day-boundary edges" do
    cases = [
      {~D[2026-03-31], :current},
      {~D[2026-03-30], :days_1_30},
      {~D[2026-03-01], :days_1_30},
      {~D[2026-02-28], :days_31_60},
      {~D[2026-01-30], :days_31_60},
      {~D[2026-01-29], :days_61_90},
      {~D[2025-12-31], :days_61_90},
      {~D[2025-12-30], :days_90_plus}
    ]

    for {due_date, expected} <- cases do
      result =
        ApAging.aging([bill("edge", due_date: due_date, amount_cents: 1_000)], as_of: @as_of)

      assert [row] = result.bills
      assert row.bucket == expected
    end
  end

  test "a bill's line total is used when no amount is supplied" do
    result =
      ApAging.aging(
        [
          bill("lines",
            amount_cents: nil,
            lines: [
              %{amount_cents: 1_250},
              %{"amount_cents" => 2_500}
            ]
          )
        ],
        as_of: @as_of
      )

    assert [row] = result.bills
    assert row.outstanding_cents == 3_750
  end

  test "a vendor statement includes paid history and only effective payments" do
    bills = [
      bill("open", amount_cents: 10_000, bill_date: ~D[2026-03-01], due_date: ~D[2026-03-01]),
      bill("paid",
        amount_cents: 7_500,
        bill_date: ~D[2026-02-01],
        due_date: ~D[2026-02-01],
        status: :paid
      ),
      bill("reopened",
        amount_cents: 4_000,
        bill_date: ~D[2026-02-15],
        due_date: ~D[2026-02-15]
      ),
      bill("other-vendor",
        vendor_id: "vendor-2",
        amount_cents: 99_000,
        due_date: ~D[2026-03-01]
      )
    ]

    runs = [
      run("effective",
        payments: [
          payment("paid", 7_500, %{"vendor_id" => nil}),
          payment("other-vendor", 99_000, %{"vendor_id" => "vendor-2"})
        ]
      ),
      run("reversed",
        vendor_name: "Stale Vendor Name",
        payments: [payment("reopened", 4_000)]
      ),
      run("other",
        vendor_id: "vendor-2",
        payments: [payment("other-vendor", 99_000, %{"vendor_id" => "vendor-2"})]
      )
    ]

    statement =
      ApAging.statement(bills, runs, "vendor-1",
        as_of: @as_of,
        reversed_run_ids: MapSet.new(["reversed"])
      )

    assert statement.vendor_id == "vendor-1"
    assert statement.vendor_name == "Vendor One"
    assert Enum.map(statement.bills, & &1.bill_id) == ["paid", "reopened", "open"]

    assert statement.totals == %{
             billed_cents: 21_500,
             paid_cents: 7_500,
             outstanding_cents: 14_000
           }

    assert [payment] = statement.payments
    assert payment.run_id == "effective"
    assert payment.bill_id == "paid"
    assert payment.amount_cents == 7_500
    assert payment.reference == "RUN-effective"

    assert statement.aging.total_cents == 14_000
    assert statement.aging.buckets.days_1_30 == 10_000
    assert statement.aging.buckets.days_31_60 == 4_000

    assert statement.aging.vendor_ids == ["vendor-1"]
  end

  test "a legacy run snapshot without per-payment vendors falls back to its header" do
    bills = [bill("legacy", amount_cents: 6_000, status: :paid)]
    runs = [run("legacy", payments: [payment("legacy", 6_000, %{"vendor_id" => nil})])]

    statement = ApAging.statement(bills, runs, "vendor-1", as_of: @as_of)

    assert [row] = statement.bills
    assert row.paid_cents == 6_000
    assert [payment] = statement.payments
    assert payment.amount_cents == 6_000
  end
end
