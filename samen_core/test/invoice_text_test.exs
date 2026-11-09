defmodule SamenCore.InvoiceTextTest do
  use ExUnit.Case, async: true

  alias Samen.Scopes.Finance.InvoiceText

  @invoice """
  ACME INDUSTRIAL SUPPLY
  Invoice No: INV-2041
  Invoice Date: 2026-10-14
  Due Date: 2026-11-13

  Description                    Amount
  Steel plate 10ga               4,250.00
  Freight                          300.00

  Total Due: $4,550.00
  """

  test "reads the header, the lines and a total that already matches" do
    assert {:ok, draft} = InvoiceText.parse(@invoice)

    assert draft.number == "INV-2041"
    assert draft.invoice_date == ~D[2026-10-14]
    assert draft.due_date == ~D[2026-11-13]
    assert draft.vendor_name == "ACME INDUSTRIAL SUPPLY"
    assert draft.currency == "USD"
    assert draft.total_cents == 455_000

    assert draft.lines == [
             %{description: "Steel plate 10ga", amount_cents: 425_000},
             %{description: "Freight", amount_cents: 30_000}
           ]

    assert draft.warnings == []
  end

  test "an unparsed difference becomes an explicit unallocated line, never a silent total" do
    text = String.replace(@invoice, "$4,550.00", "$4,650.00")
    assert {:ok, draft} = InvoiceText.parse(text)

    assert draft.total_cents == 465_000
    assert [_, _, unallocated] = draft.lines
    assert unallocated.description =~ "Unallocated"
    assert unallocated.amount_cents == 10_000
    assert Enum.any?(draft.warnings, &(&1 =~ "unallocated line"))
  end

  test "missing fields are nil with warnings, not invented defaults" do
    assert {:ok, draft} = InvoiceText.parse("ACME SUPPLY\nFreight          100.00\n")

    assert draft.number == nil
    assert draft.invoice_date == nil
    assert draft.due_date == nil
    assert draft.total_cents == 10_000
    assert Enum.any?(draft.warnings, &(&1 =~ "invoice number"))
    assert Enum.any?(draft.warnings, &(&1 =~ "invoice date"))
  end

  test "reads a euro invoice with a US-style slash date" do
    text = """
    Nordwerk GmbH
    Invoice No: NW-88
    Invoice Date: 14/10/2026
    Due Date: 13/11/2026
    Lagerregal                     1.250,00
    Total: €1.250,00
    """

    # Comma decimals are not guessed at; the line parse stays honest about it.
    assert {:ok, draft} = InvoiceText.parse(text)
    assert draft.currency == "EUR"
    assert draft.invoice_date == ~D[2026-10-14]
    assert draft.number == "NW-88"
  end

  test "reads a month-name date and a bare INV number" do
    text = """
    Contoso Ltd
    INV-9001
    Date: Oct 14, 2026
    Widgets           1,000.00
    Total             1,000.00
    """

    assert {:ok, draft} = InvoiceText.parse(text)
    assert draft.number == "INV-9001"
    assert draft.invoice_date == ~D[2026-10-14]
    assert draft.total_cents == 100_000
  end

  test "without a total line the sum of the lines is the total, with a warning" do
    assert {:ok, draft} =
             InvoiceText.parse("Vendor Co\nWidgets      250.00\nBolts         50.00\n")

    assert draft.total_cents == 30_000
    assert Enum.any?(draft.warnings, &(&1 =~ "invoice total"))
  end

  test "an OCR double-read of the same row is counted once" do
    text = """
    Vendor Co
    Invoice No: DUP-1
    Invoice Date: 2026-10-14
    Widgets      250.00
    Widgets      250.00
    Total        250.00
    """

    assert {:ok, draft} = InvoiceText.parse(text)
    assert draft.lines == [%{description: "Widgets", amount_cents: 25_000}]
    assert draft.total_cents == 25_000
  end

  test "blank text is refused" do
    assert {:error, :empty_text} = InvoiceText.parse("   \n\n ")
  end

  test "date and amount tokens parse on their own" do
    assert InvoiceText.date_in("due 2026-11-13") == ~D[2026-11-13]
    assert InvoiceText.date_in("due 11/13/2026") == ~D[2026-11-13]
    assert InvoiceText.date_in("no date here") == nil

    assert InvoiceText.amount_in("$4,550.00") == 455_000
    assert InvoiceText.amount_in("123.45") == 12_345
    assert InvoiceText.amount_in("not money") == nil
  end
end
