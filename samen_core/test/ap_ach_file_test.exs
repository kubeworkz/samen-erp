defmodule SamenCore.ApAchFileTest do
  use ExUnit.Case, async: true

  alias Samen.Scopes.Finance.ApAchFile

  @run %{
    reference: "RUN-001",
    payment_date: ~D[2026-11-08],
    vendor_id: "vendor-1",
    total_cents: 10_500,
    payments: [
      %{bill_id: "b1", number: "INV-1", due_date: ~D[2026-10-01], amount_cents: 4_000},
      %{bill_id: "b2", number: "INV-2", due_date: ~D[2026-11-01], amount_cents: 6_500}
    ]
  }

  @opts [
    originator_name: "Sample Co",
    originator_id: "1123456789",
    originator_dfi: "021000021",
    receiver_name: "Vendor One",
    receiver_account: "123456789",
    receiver_dfi: "011000015",
    account_type: :checking,
    effective_date: ~D[2026-11-10],
    created_at: ~U[2026-11-08 15:04:05Z]
  ]

  defp render(run, opts) do
    {:ok, file} = ApAchFile.render(run, opts)
    file
  end

  defp lines(run \\ @run, opts \\ @opts) do
    run |> render(opts) |> String.split("\n", trim: true)
  end

  test "every record is 94 characters and the file is a whole number of 10-record blocks" do
    file_lines = lines()

    assert length(file_lines) == 10
    assert Enum.all?(file_lines, &(String.length(&1) == 94))
    assert Enum.take(file_lines, -4) == List.duplicate(String.duplicate("9", 94), 4)
  end

  test "file and batch headers carry the originator, SEC code and dates" do
    [file_header, batch_header | _rest] = lines()

    assert String.slice(file_header, 0, 3) == "101"
    assert String.slice(file_header, 3, 10) == " 021000021"
    assert String.slice(file_header, 13, 10) == " 021000021"
    assert String.slice(file_header, 23, 6) == "261108"
    assert String.slice(file_header, 29, 4) == "1504"
    assert String.slice(file_header, 33, 7) == "A094101"

    assert String.slice(batch_header, 0, 4) == "5220"
    assert String.slice(batch_header, 4, 16) == "SAMPLE CO       "
    assert String.slice(batch_header, 20, 20) == String.pad_trailing("RUN-001", 20)
    assert String.slice(batch_header, 40, 10) == "1123456789"
    assert String.slice(batch_header, 50, 3) == "CCD"
    assert String.slice(batch_header, 53, 10) == "AP PAYMENT"
    assert String.slice(batch_header, 63, 6) == "261110"
    assert String.slice(batch_header, 69, 6) == "261110"
    assert String.slice(batch_header, 79, 8) == "02100002"
    assert String.slice(batch_header, 87, 7) == "0000001"
  end

  test "one entry per bill, with the posted cents, bill number and sequential trace" do
    entries = lines() |> Enum.filter(&String.starts_with?(&1, "6"))

    assert length(entries) == 2

    [first, second] = entries

    assert String.slice(first, 0, 3) == "622"
    assert String.slice(first, 3, 8) == "01100001"
    assert String.slice(first, 11, 1) == "5"
    assert String.slice(first, 12, 17) == String.pad_trailing("123456789", 17)
    assert String.slice(first, 29, 10) == "0000004000"
    assert String.slice(first, 39, 15) == String.pad_trailing("INV-1", 15)
    assert String.slice(first, 54, 22) == String.pad_trailing("VENDOR ONE", 22)
    assert String.slice(first, 78, 1) == "0"
    assert String.slice(first, 79, 15) == "021000020000001"

    assert String.slice(second, 29, 10) == "0000006500"
    assert String.slice(second, 79, 15) == "021000020000002"
  end

  test "batch and file controls total the run and hash the receiving routing numbers" do
    file_lines = lines()
    batch_control = Enum.find(file_lines, &String.starts_with?(&1, "8"))
    file_control = Enum.find(file_lines, &String.starts_with?(&1, "9"))

    assert String.slice(batch_control, 1, 3) == "220"
    assert String.slice(batch_control, 4, 6) == "000002"
    # two entries to 01100001 -> 2 * 11_000_001 = 22_000_002
    assert String.slice(batch_control, 10, 10) == "0002200002"
    assert String.slice(batch_control, 20, 12) == "000000000000"
    assert String.slice(batch_control, 32, 12) == "000000010500"
    assert String.slice(batch_control, 44, 10) == "1123456789"
    assert String.slice(batch_control, 79, 8) == "02100002"

    assert String.slice(file_control, 1, 6) == "000001"
    assert String.slice(file_control, 7, 6) == "000001"
    assert String.slice(file_control, 13, 8) == "00000002"
    assert String.slice(file_control, 21, 10) == "0002200002"
    assert String.slice(file_control, 43, 12) == "000000010500"
  end

  test "a savings account uses transaction code 32 and a long run pads to more blocks" do
    run = %{@run | payments: for(i <- 1..8, do: %{number: "INV-#{i}", amount_cents: 1_000})}
    file_lines = lines(run, Keyword.put(@opts, :account_type, :savings))

    savings = Enum.filter(file_lines, &String.starts_with?(&1, "6"))
    assert Enum.all?(savings, &(String.slice(&1, 0, 3) == "632"))
    assert length(file_lines) == 20
    assert Enum.take(file_lines, -3) == List.duplicate(String.duplicate("9", 94), 3)
  end

  test "invalid bank details are refused instead of written into the file" do
    assert {:error, {:invalid_routing, :receiver_dfi}} =
             ApAchFile.render(@run, Keyword.put(@opts, :receiver_dfi, "021000022"))

    assert {:error, {:invalid_routing, :originator_dfi}} =
             ApAchFile.render(@run, Keyword.put(@opts, :originator_dfi, "123456789"))

    assert {:error, :receiver_account_required} =
             ApAchFile.render(@run, Keyword.put(@opts, :receiver_account, " "))

    assert {:error, :receiver_account_too_long} =
             ApAchFile.render(
               @run,
               Keyword.put(@opts, :receiver_account, String.duplicate("9", 18))
             )

    assert {:error, :receiver_account_invalid} =
             ApAchFile.render(@run, Keyword.put(@opts, :receiver_account, "123-456"))

    assert {:error, :originator_id_invalid} =
             ApAchFile.render(@run, Keyword.put(@opts, :originator_id, "12345678901"))

    assert {:error, {:invalid_account_type, :credit}} =
             ApAchFile.render(@run, Keyword.put(@opts, :account_type, :credit))

    assert {:error, :no_payments} = ApAchFile.render(%{@run | payments: []}, @opts)
  end

  test "the ABA checksum accepts real routing numbers only" do
    assert ApAchFile.valid_routing?("021000021")
    assert ApAchFile.valid_routing?("011000015")
    refute ApAchFile.valid_routing?("021000022")
    refute ApAchFile.valid_routing?("02100002")
    refute ApAchFile.valid_routing?(nil)
  end

  test "effective date defaults to the run's payment date" do
    batch_header =
      @opts |> Keyword.delete(:effective_date) |> then(&lines(@run, &1)) |> Enum.at(1)

    assert String.slice(batch_header, 69, 6) == "261108"
  end
end
