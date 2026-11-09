defmodule SamenCore.ApPaymentDuplicatesTest do
  use ExUnit.Case, async: true

  alias Samen.Scopes.Finance.ApPaymentRun

  defp bill(attrs) do
    Map.merge(
      %{
        id: Ash.UUID.generate(),
        number: "INV-1",
        vendor_id: "vendor-a",
        bill_date: ~D[2026-09-01],
        lines: [%{amount_cents: 5_000}]
      },
      Map.new(attrs)
    )
  end

  test "the same vendor, total and bill date group even under different numbers" do
    first = bill(%{number: "INV-1"})
    second = bill(%{number: "INV-2"})

    assert [%{bills: [^first, ^second]}] = ApPaymentRun.duplicates([first, second])
  end

  test "a different amount, date or vendor is not a duplicate" do
    base = bill(%{number: "INV-1"})

    assert ApPaymentRun.duplicates([base, bill(%{lines: [%{amount_cents: 5_001}]})]) == []
    assert ApPaymentRun.duplicates([base, bill(%{bill_date: ~D[2026-09-02]})]) == []
    assert ApPaymentRun.duplicates([base, bill(%{vendor_id: "vendor-b"})]) == []
    assert ApPaymentRun.duplicates([base]) == []
  end

  test "line totals are summed, and bills without a vendor are ignored" do
    multi = bill(%{number: "INV-1", lines: [%{amount_cents: 2_500}, %{amount_cents: 2_500}]})

    assert [_group] = ApPaymentRun.duplicates([multi, bill(%{number: "INV-9"})])

    assert ApPaymentRun.duplicates([
             bill(%{number: "A", vendor_id: nil}),
             bill(%{number: "B", vendor_id: nil})
           ]) == []
  end

  test "each group lists its bills by number" do
    a = bill(%{number: "INV-3"})
    b = bill(%{number: "INV-1"})
    c = bill(%{number: "INV-2"})

    assert [%{bills: bills}] = ApPaymentRun.duplicates([a, b, c])
    assert Enum.map(bills, & &1.number) == ["INV-1", "INV-2", "INV-3"]
  end
end
