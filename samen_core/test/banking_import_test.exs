defmodule Samen.BankingImportTest do
  use ExUnit.Case, async: true

  alias Samen.Scopes.Banking.Import

  test "parses CSV aliases, quoted descriptions, and signed amounts" do
    csv = """
    Date,Amount,Description,Counterparty,Reference
    2026-10-01,-50.25,"Coffee, Inc.",Coffee Shop,TX-1
    2026-10-02,"$1,200.00",Customer payment,Acme,INV-9
    """

    assert {:ok, %{format: :csv, transactions: [coffee, payment]}} =
             Import.parse(csv, filename: "statement.csv")

    assert coffee.amount_cents == -5_025
    assert coffee.description == "Coffee, Inc."
    assert coffee.counterparty == "Coffee Shop"
    assert coffee.reference == "TX-1"
    assert DateTime.to_date(coffee.posted_at) == ~D[2026-10-01]

    assert payment.amount_cents == 120_000
    assert payment.description == "Customer payment"
    assert payment.reference == "INV-9"
  end

  test "parses amount_cents and slash dates from bank CSV exports" do
    csv = """
    Posted At,Amount Cents,Memo
    10/03/2026,-1999,Interest charge
    """

    assert {:ok, %{transactions: [line]}} = Import.parse(csv, filename: "export.csv")
    assert line.amount_cents == -1_999
    assert line.description == "Interest charge"
    assert DateTime.to_date(line.posted_at) == ~D[2026-10-03]
  end

  test "parses separate Debit and Credit money columns" do
    csv = """
    Date,Description,Debit,Credit
    2026-10-05,Coffee,50.25,
    2026-10-06,Refund,,"$1,200.00"
    """

    assert {:ok, %{transactions: [coffee, refund]}} =
             Import.parse(csv, filename: "split.csv")

    assert coffee.amount_cents == -5_025
    assert coffee.description == "Coffee"
    assert refund.amount_cents == 120_000
    assert refund.description == "Refund"
  end

  test "accepts withdrawal/deposit aliases and split cents columns" do
    aliases = """
    Date,Description,Withdrawal,Deposit
    2026-10-07,ATM,20.00,
    2026-10-08,Interest,,5.00
    """

    assert {:ok, %{transactions: [atm, interest]}} =
             Import.parse(aliases, filename: "aliases.csv")

    assert atm.amount_cents == -2_000
    assert interest.amount_cents == 500

    cents = """
    Date,Description,Debit Cents,Credit Cents
    2026-10-09,Fee,125,
    2026-10-10,Interest,,250
    """

    assert {:ok, %{transactions: [fee, cents_interest]}} =
             Import.parse(cents, filename: "split-cents.csv")

    assert fee.amount_cents == -125
    assert cents_interest.amount_cents == 250
  end

  test "refuses an ambiguous row with both Debit and Credit populated" do
    csv = """
    Date,Description,Debit,Credit
    2026-10-09,Ambiguous,10.00,5.00
    """

    assert {:error, {:invalid_row, 2, {:ambiguous_amount, "10.00", "5.00"}}} =
             Import.parse(csv, filename: "ambiguous.csv")
  end

  test "refuses a split row with neither Debit nor Credit populated" do
    csv = """
    Date,Description,Debit,Credit
    2026-10-09,Empty,,
    """

    assert {:error, {:invalid_row, 2, {:missing_value, :amount}}} =
             Import.parse(csv, filename: "empty-split.csv")
  end

  test "parses OFX 1.x SGML (including QFX) without closing STMTTRN tags" do
    ofx = """
    OFXHEADER:100
    DATA:OFXSGML
    VERSION:102

    <BANKMSGSRSV1>
    <STMTTRNRS>
    <STMTRS>
    <BANKTRANLIST>
    <STMTTRN>
    <TRNTYPE>DEBIT
    <DTPOSTED>20261001120000.000[-5:EST]
    <TRNAMT>50.00
    <FITID>coffee-1
    <NAME>COFFEE SHOP
    <MEMO>Card purchase
    <STMTTRN>
    <TRNTYPE>CREDIT
    <DTPOSTED>20261002
    <TRNAMT>1200.00
    <FITID>payment-1
    <NAME>ACME CUSTOMER
    </BANKTRANLIST>
    </STMTRS>
    </STMTTRNRS>
    </BANKMSGSRSV1>
    """

    assert {:ok, %{format: :ofx, transactions: [coffee, payment]}} =
             Import.parse(ofx, filename: "statement.qfx")

    assert coffee.amount_cents == -5_000
    assert coffee.description == "COFFEE SHOP — Card purchase"
    assert coffee.counterparty == "COFFEE SHOP"
    assert coffee.reference == "coffee-1"
    assert DateTime.to_date(coffee.posted_at) == ~D[2026-10-01]

    assert payment.amount_cents == 120_000
    assert payment.description == "ACME CUSTOMER"
    assert payment.reference == "payment-1"
  end

  test "parses OFX 2.x XML with closing STMTTRN tags" do
    ofx = """
    <?xml version="1.0" encoding="UTF-8"?>
    <OFX>
      <BANKMSGSRSV1>
        <STMTTRNRS>
          <STMTRS>
            <BANKTRANLIST>
              <STMTTRN>
                <TRNTYPE>CREDIT</TRNTYPE>
                <DTPOSTED>20261004120000</DTPOSTED>
                <TRNAMT>99.95</TRNAMT>
                <FITID>xml-1</FITID>
                <NAME>REFUND</NAME>
                <MEMO>Returned item</MEMO>
              </STMTTRN>
            </BANKTRANLIST>
          </STMTRS>
        </STMTTRNRS>
      </BANKMSGSRSV1>
    </OFX>
    """

    assert {:ok, %{format: :ofx, transactions: [line]}} =
             Import.parse(ofx, filename: "statement.ofx")

    assert line.amount_cents == 9_995
    assert line.description == "REFUND — Returned item"
    assert line.reference == "xml-1"
  end

  test "refuses a CSV row with an invalid amount" do
    csv = """
    Date,Amount,Description
    2026-10-01,not-money,Broken row
    """

    assert {:error, {:invalid_row, 2, {:invalid_amount, "not-money"}}} =
             Import.parse(csv, filename: "bad.csv")
  end

  test "refuses malformed OFX with no transaction blocks" do
    ofx = """
    OFXHEADER:100
    DATA:OFXSGML
    <OFX></OFX>
    """

    assert {:error, :no_transactions} = Import.parse(ofx, filename: "bad.ofx")
  end

  test "reports malformed OFX transaction fields" do
    missing_amount = """
    OFXHEADER:100
    <STMTTRN>
    <DTPOSTED>20261001
    <NAME>Missing amount
    </STMTTRN>
    """

    assert {:error, {:invalid_transaction, 1, {:missing_value, :amount}}} =
             Import.parse(missing_amount, filename: "bad.ofx")

    bad_date = """
    OFXHEADER:100
    <STMTTRN>
    <DTPOSTED>not-a-date
    <TRNAMT>10.00
    <NAME>Bad date
    </STMTTRN>
    """

    assert {:error, {:invalid_transaction, 1, {:invalid_date, "not-a-date"}}} =
             Import.parse(bad_date, filename: "bad.ofx")

    bad_amount = """
    OFXHEADER:100
    <STMTTRN>
    <DTPOSTED>20261001
    <TRNAMT>not-money
    <NAME>Bad amount
    </STMTTRN>
    """

    assert {:error, {:invalid_transaction, 1, {:invalid_amount, "not-money"}}} =
             Import.parse(bad_amount, filename: "bad.ofx")
  end

  test "requires the date, amount/debit-credit, and description columns" do
    assert {:error, {:missing_column, :amount_or_debit_credit}} =
             Import.parse("Date,Description\n2026-10-01,No amount\n", filename: "bad.csv")
  end
end
