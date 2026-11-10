defmodule Samen.ArAgingTest do
  @moduledoc """
  Pure AR aging/statement math. The host proof exercises the Ash-backed load;
  this suite pins the boundaries and the posted-receipt basis.
  """

  use ExUnit.Case, async: true

  alias Samen.Scopes.Finance.ArAging

  @as_of ~D[2026-03-31]

  defp invoice(id, attrs) do
    Map.merge(
      %{
        id: id,
        customer_id: "customer-1",
        invoice_date: ~D[2026-03-01],
        due_date: @as_of,
        amount_cents: 10_000,
        status: :open
      },
      Map.new(attrs)
    )
  end

  defp receipt(invoice_id, amount, paid_at \\ ~U[2026-03-15 12:00:00Z]) do
    %{id: "receipt-#{invoice_id}", invoice_id: invoice_id, amount_cents: amount, paid_at: paid_at}
  end

  test "places every bucket correctly and subtracts posted receipts" do
    invoices = [
      invoice("current", due_date: ~D[2026-04-10], amount_cents: 10_000),
      invoice("1-30", due_date: ~D[2026-03-15], amount_cents: 20_000),
      invoice("31-60", due_date: ~D[2026-02-15], amount_cents: 30_000),
      invoice("61-90", due_date: ~D[2026-01-15], amount_cents: 40_000),
      invoice("90+", due_date: ~D[2025-12-01], amount_cents: 50_000),
      invoice("undated", due_date: nil, amount_cents: 5_000)
    ]

    receipts = [receipt("current", 5_000)]

    result = ArAging.aging(invoices, receipts, as_of: @as_of)

    assert result.total_cents == 150_000

    assert result.buckets == %{
             current: 5_000,
             days_1_30: 20_000,
             days_31_60: 30_000,
             days_61_90: 40_000,
             days_90_plus: 50_000,
             undated: 5_000
           }

    by_id = Map.new(result.invoices, &{&1.invoice_id, &1})
    assert by_id["current"].paid_cents == 5_000
    assert by_id["current"].outstanding_cents == 5_000
    assert by_id["current"].days_overdue == 0
    assert by_id["31-60"].days_overdue == 44
    assert by_id["undated"].days_overdue == nil
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
        ArAging.aging([invoice("edge", due_date: due_date, amount_cents: 1_000)], [],
          as_of: @as_of
        )

      assert [row] = result.invoices

      assert row.bucket == expected,
             "due #{due_date} landed in #{row.bucket}, expected #{expected}"
    end
  end

  test "a fully paid invoice is not aged, even when the mirror says otherwise" do
    result =
      ArAging.aging(
        [invoice("paid", amount_cents: 10_000)],
        [receipt("paid", 10_000)],
        as_of: @as_of
      )

    assert result.total_cents == 0
    assert result.invoices == []

    input = [invoice("mirror-paid", amount_cents: 10_000)]
    receipts = [receipt("mirror-paid", 4_000)]
    partial = ArAging.aging(input, receipts, as_of: @as_of)
    assert [row] = partial.invoices
    assert row.outstanding_cents == 6_000
  end

  test "a customer statement includes paid history and only that customer's receipts" do
    invoices = [
      invoice("a-open",
        customer_id: "customer-1",
        amount_cents: 10_000,
        due_date: ~D[2026-03-01]
      ),
      invoice("a-paid", customer_id: "customer-1", amount_cents: 7_500, due_date: ~D[2026-02-01]),
      invoice("b-open", customer_id: "customer-2", amount_cents: 99_000, due_date: ~D[2026-03-01])
    ]

    receipts = [
      receipt("a-paid", 7_500, ~U[2026-03-10 09:00:00Z]),
      receipt("b-open", 99_000, ~U[2026-03-11 09:00:00Z])
    ]

    statement = ArAging.statement(invoices, receipts, "customer-1", as_of: @as_of)

    assert statement.customer_id == "customer-1"
    assert Enum.map(statement.invoices, & &1.invoice_id) == ["a-open", "a-paid"]
    assert Enum.map(statement.receipts, & &1.invoice_id) == ["a-paid"]

    assert statement.totals == %{
             currency: "USD",
             invoiced_cents: 17_500,
             paid_cents: 7_500,
             credited_cents: 0,
             outstanding_cents: 10_000,
             unapplied_cents: 0
           }

    assert statement.aging.total_cents == 10_000
    assert statement.aging.buckets.days_1_30 == 10_000
  end

  test "groups aging and unapplied cash by currency instead of summing cents" do
    invoices = [
      invoice("usd", amount_cents: 1_000, currency: "USD"),
      invoice("eur", amount_cents: 2_000, currency: "EUR")
    ]

    receipts = [
      receipt("usd", 400) |> Map.put(:currency, "USD"),
      %{
        id: "on-account-usd",
        invoice_id: nil,
        customer_id: "customer-1",
        amount_cents: 300,
        currency: "USD",
        paid_at: ~U[2026-03-15 12:00:00Z]
      }
    ]

    result = ArAging.aging(invoices, receipts, as_of: @as_of)

    assert result.total_cents == nil
    assert result.buckets == nil
    assert result.by_currency["USD"].total_cents == 600
    assert result.by_currency["EUR"].total_cents == 2_000
    assert result.unapplied_by_currency == %{"USD" => 300}
    assert result.unapplied_cents == nil

    statement = ArAging.statement(invoices, receipts, "customer-1", as_of: @as_of)

    assert statement.totals == nil
    assert statement.by_currency["USD"].outstanding_cents == 600
    assert statement.by_currency["USD"].unapplied_cents == 300
    assert statement.by_currency["EUR"].outstanding_cents == 2_000
    assert [credit] = statement.unapplied_cash
    assert credit.receipt_id == "on-account-usd"
  end

  test "posted credit notes and write-offs net the invoice; voided or draft ones do not" do
    invoices = [invoice("credited", amount_cents: 10_000, due_date: ~D[2026-03-01])]

    credits = [
      %{
        id: "credit-1",
        invoice_id: "credited",
        amount_cents: 4_000,
        status: :open,
        date: ~D[2026-03-05]
      },
      %{
        id: "write-off-1",
        invoice_id: "credited",
        amount_cents: 1_000,
        status: :applied,
        date: ~D[2026-03-06]
      },
      %{
        id: "draft-1",
        invoice_id: "credited",
        amount_cents: 9_000,
        status: :draft,
        date: ~D[2026-03-07]
      },
      %{
        id: "void-1",
        invoice_id: "credited",
        amount_cents: 9_000,
        status: :void,
        date: ~D[2026-03-08]
      }
    ]

    result = ArAging.aging(invoices, [], as_of: @as_of, credit_notes: credits)
    assert [row] = result.invoices
    assert row.credited_cents == 5_000
    assert row.outstanding_cents == 5_000
    assert result.total_cents == 5_000

    statement =
      ArAging.statement(invoices, [], "customer-1", as_of: @as_of, credit_notes: credits)

    assert [row] = statement.invoices
    assert row.credited_cents == 5_000
    assert statement.totals.credited_cents == 5_000
    assert statement.totals.outstanding_cents == 5_000
    assert Enum.map(statement.credit_notes, & &1.id) == ["credit-1", "write-off-1"]
  end

  test "a fully credited invoice is not aged" do
    result =
      ArAging.aging(
        [invoice("written-off", amount_cents: 10_000)],
        [],
        as_of: @as_of,
        credit_notes: [
          %{invoice_id: "written-off", amount_cents: 10_000, status: :open}
        ]
      )

    assert result.invoices == []
    assert result.total_cents == 0
  end
end
