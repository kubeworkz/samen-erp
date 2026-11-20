defmodule SamenCore.ApEftFileTest do
  use ExUnit.Case, async: true

  alias Samen.Scopes.Finance.ApEftFile

  @run %{
    reference: "RUN-001",
    payment_date: ~D[2026-11-08],
    vendor_id: "vendor-1",
    currency: "CAD",
    total_cents: 10_500,
    payments: [
      %{bill_id: "b1", number: "INV-1", due_date: ~D[2026-10-01], amount_cents: 4_000},
      %{bill_id: "b2", number: "INV-2", due_date: ~D[2026-11-01], amount_cents: 6_500}
    ]
  }

  @opts [
    originator_name: "Sample Co",
    originator_id: "1123456789",
    destination_data_centre: "00420",
    originator_return_institution: "000410202",
    originator_return_account: "12345678901",
    file_creation_number: "0042",
    encoding: :ascii,
    record_separator: "\r\n",
    receiver_name: "Vendor One",
    receiver_account: "123456789",
    receiver_institution: "004",
    receiver_transit: "10202",
    account_type: :checking,
    effective_date: ~D[2026-11-10],
    created_at: ~U[2026-11-08 15:04:05Z]
  ]

  defp render(run, opts) do
    {:ok, file} = ApEftFile.render(run, opts)
    file
  end

  defp records(run \\ @run, opts \\ @opts) do
    run |> render(opts) |> String.split("\r\n", trim: true)
  end

  # 1-based field slice, matching the CPA-005 position table.
  defp at(record, position, length), do: String.slice(record, position - 1, length)

  test "every A/C/Z record is 1464 bytes and the golden CPA-005 file matches" do
    file = render(@run, @opts)
    file_records = String.split(file, "\r\n", trim: true)

    assert length(file_records) == 3
    assert Enum.map(file_records, &byte_size/1) == [1464, 1464, 1464]
    assert Enum.map(file_records, &String.first/1) == ["A", "C", "Z"]
    assert file == File.read!("test/fixtures/ap_cpa005_golden.cpa005")
  end

  test "the TD profile uses ASCII + CRLF, and a CR-only separator contains no LF" do
    crlf = render(@run, @opts)
    assert String.contains?(crlf, "\r\n")

    cr = render(@run, Keyword.put(@opts, :record_separator, "\r"))
    assert String.contains?(cr, "\r")
    refute String.contains?(cr, "\n")
    # The record width is measured before the separator, so the bytes are the
    # same records with a different frame.
    assert String.split(cr, "\r", trim: true) == String.split(crlf, "\r\n", trim: true)
  end

  test "a missing encoding or separator refuses instead of defaulting" do
    assert {:error, :encoding_required} =
             ApEftFile.render(@run, Keyword.delete(@opts, :encoding))

    assert {:error, :record_separator_required} =
             ApEftFile.render(@run, Keyword.delete(@opts, :record_separator))

    assert {:error, :not_implemented} =
             ApEftFile.render(@run, Keyword.put(@opts, :encoding, :ebcdic))

    assert {:error, {:unsupported_record_separator, "\n"}} =
             ApEftFile.render(@run, Keyword.put(@opts, :record_separator, "\n"))
  end

  test "six 240-character segments pack into each C record and unused segments are blank" do
    [_, c, _] = records()

    assert byte_size(c) == 1464
    assert at(c, 25, 3) == "300"
    assert at(c, 265, 240) != String.duplicate(" ", 240)
    assert at(c, 505, 240) == String.duplicate(" ", 240)
    assert at(c, 745, 240) == String.duplicate(" ", 240)
    assert at(c, 985, 240) == String.duplicate(" ", 240)
    assert at(c, 1225, 240) == String.duplicate(" ", 240)
  end

  test "A/C/Z counts, Julian dates and trailer cents/count are exact" do
    [a, c, z] = records()

    assert at(a, 1, 1) == "A"
    assert at(a, 2, 9) == "000000001"
    assert at(a, 11, 10) == "1123456789"
    assert at(a, 21, 4) == "0042"
    assert at(a, 25, 6) == "026312"
    assert at(a, 31, 5) == "00420"
    assert at(a, 36, 20) == String.duplicate(" ", 20)
    assert at(a, 56, 3) == "CAD"

    assert at(c, 1, 1) == "C"
    assert at(c, 2, 9) == "000000002"
    assert at(c, 11, 10) == "1123456789"
    assert at(c, 21, 4) == "0042"

    assert at(c, 28, 10) == "0000004000"
    assert at(c, 38, 6) == "026314"

    assert at(z, 1, 1) == "Z"
    assert at(z, 2, 9) == "000000003"
    assert at(z, 11, 10) == "1123456789"
    assert at(z, 21, 4) == "0042"
    assert at(z, 25, 14) == "00000000000000"
    assert at(z, 39, 8) == "00000000"
    assert at(z, 47, 14) == "00000000010500"
    assert at(z, 61, 8) == "00000002"
    assert at(z, 69, 1396) == String.duplicate("0", 1396)
  end

  test "seven payments produce two C records and a Z at the next logical count" do
    payments =
      for index <- 1..7 do
        %{number: "INV-#{index}", amount_cents: index * 100}
      end

    [a, first_c, second_c, z] = records(%{@run | payments: payments})

    assert at(a, 2, 9) == "000000001"
    assert at(first_c, 2, 9) == "000000002"
    assert at(second_c, 2, 9) == "000000003"
    assert at(z, 2, 9) == "000000004"
    assert at(z, 47, 14) == "00000000002800"
    assert at(z, 61, 8) == "00000007"

    # The seventh payment occupies segment one of the second C record; the
    # remaining five slots are still 240 blank characters.
    assert at(second_c, 25, 3) == "300"
    assert at(second_c, 265, 240) == String.duplicate(" ", 240)
    assert at(second_c, 1225, 240) == String.duplicate(" ", 240)
  end

  test "TD fields put 00420 in A 31-35, 0004+transit in 194-202, the 11-digit return account in 203-214, and zeros in 254-264" do
    [a, c, _z] = records()

    assert at(a, 31, 5) == "00420"
    assert at(c, 194, 9) == "000410202"
    assert at(c, 203, 12) == "12345678901 "
    assert at(c, 254, 11) == "00000000000"
    assert at(c, 165, 10) == "1123456789"
    assert at(c, 175, 19) == String.pad_trailing("INV-1", 19)
  end

  test "preserves leading zeros in the client number, institution, transit and account" do
    [a, c, _z] =
      records(
        @run,
        Keyword.merge(@opts,
          originator_id: "0012345678",
          receiver_account: "000123456789",
          receiver_institution: "004",
          receiver_transit: "00202"
        )
      )

    assert at(a, 11, 10) == "0012345678"
    assert at(c, 44, 9) == "000400202"
    assert at(c, 53, 12) == "000123456789"
    assert at(c, 165, 10) == "0012345678"
  end

  test "checking uses transaction code 300 and savings uses 400" do
    [_a, checking, _z] = records()
    assert at(checking, 25, 3) == "300"

    [_a, savings, _z] = records(@run, Keyword.put(@opts, :account_type, :savings))
    assert at(savings, 25, 3) == "400"
  end

  test "refuses a non-CAD run" do
    assert {:error, {:unsupported_currency, "USD"}} =
             ApEftFile.render(%{@run | currency: "USD"}, @opts)
  end

  test "refuses a 13-character account instead of truncating it" do
    assert {:error, :receiver_account_too_long} =
             ApEftFile.render(
               @run,
               Keyword.put(@opts, :receiver_account, "1234567890123")
             )

    # The boundary itself is accepted and padded to 12.
    file = render(@run, Keyword.put(@opts, :receiver_account, "123456789012"))
    [_a, c, _z] = String.split(file, "\r\n", trim: true)
    assert at(c, 53, 12) == "123456789012"
  end

  test "refuses a bad client number, data centre, return institution/account, FCN, institution or transit" do
    assert {:error, :originator_id_invalid} =
             ApEftFile.render(@run, Keyword.put(@opts, :originator_id, "12345678901"))

    assert {:error, :destination_data_centre_invalid} =
             ApEftFile.render(@run, Keyword.put(@opts, :destination_data_centre, "00220"))

    assert {:error, :originator_return_institution_invalid} =
             ApEftFile.render(
               @run,
               Keyword.put(@opts, :originator_return_institution, "123456789")
             )

    assert {:error, :originator_return_account_invalid} =
             ApEftFile.render(@run, Keyword.put(@opts, :originator_return_account, "1234567890"))

    assert {:error, :receiver_institution_invalid} =
             ApEftFile.render(@run, Keyword.put(@opts, :receiver_institution, "04"))

    assert {:error, :receiver_transit_invalid} =
             ApEftFile.render(@run, Keyword.put(@opts, :receiver_transit, "1020"))

    assert {:error, {:invalid_account_type, :credit}} =
             ApEftFile.render(@run, Keyword.put(@opts, :account_type, :credit))
  end

  test "refuses FCN 0000 and 10000" do
    assert {:error, :file_creation_number_invalid} =
             ApEftFile.render(@run, Keyword.put(@opts, :file_creation_number, "0000"))

    assert {:error, :file_creation_number_invalid} =
             ApEftFile.render(@run, Keyword.put(@opts, :file_creation_number, "10000"))

    assert {:ok, file} = ApEftFile.render(@run, Keyword.put(@opts, :file_creation_number, 42))
    assert at(hd(String.split(file, "\r\n", trim: true)), 21, 4) == "0042"
  end

  test "empty payments and non-positive amounts refuse" do
    assert {:error, :no_payments} = ApEftFile.render(%{@run | payments: []}, @opts)

    assert {:error, {:invalid_amount, 1}} =
             ApEftFile.render(
               %{@run | payments: [%{number: "ZERO", amount_cents: 0}]},
               @opts
             )

    assert {:error, {:invalid_amount, 1}} =
             ApEftFile.render(
               %{@run | payments: [%{number: "NEG", amount_cents: -100}]},
               @opts
             )
  end
end
