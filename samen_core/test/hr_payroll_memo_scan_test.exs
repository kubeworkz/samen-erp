defmodule Samen.Hr.Payroll.MemoScanTest do
  use ExUnit.Case, async: true

  alias Samen.Hr.Payroll.MemoScan

  describe "check/2" do
    test "refuses embedded PII shapes in memo prose" do
      cases = [
        {"Payroll for jane.doe@example.com", :email},
        {"ssn 123-45-6789", :ssn},
        {"EIN 12-3456789", :ein},
        {"employee: Jane Doe", :employee_name},
        {"employee_name: jane doe", :employee_name},
        {"Payroll for Jane Doe", :bare_name},
        {"Payroll For Jane Doe", :bare_name},
        {"Payroll for jane doe", :bare_name},
        {"Payroll for JANE DOE", :bare_name},
        {"payroll for jane doe", :bare_name},
        {"PAYROLL FOR JANE DOE", :bare_name},
        {"IBAN GB82WEST12345698765432", :iban},
        {"SWIFT BOFAUS3N", :swift},
        {"bank account 1234 5678 9012", :bank_detail},
        {"sort code: 12-34-56", :bank_detail},
        {"tax id: 123456789", :tax_id},
        {"vat: GB123456789", :tax_id},
        {"call +1-800-555-1234", :phone}
      ]

      for {memo, shape} <- cases do
        assert {:error, {:invalid_payroll_register, {:pii_memo, :line_memo, ^shape}}} =
                 MemoScan.check(memo, :line_memo)
      end
    end

    test "allows ordinary payroll prose and opaque references" do
      for memo <- [
            "September 2026 payroll",
            "Payroll Reversal",
            "Payroll clearing",
            "Payroll Clearing",
            "September Payroll",
            "Payroll for September Close",
            "Payroll for the team",
            "Payroll for all employees",
            "Payroll for PTO",
            "Payroll for audit",
            "Payroll for off-cycle",
            "Payroll for audit review",
            "Payroll for off-cycle processing",
            "employee_ref: emp_1042",
            "cost_object: project_alpha"
          ] do
        assert :ok = MemoScan.check(memo, :memo)
      end
    end

    test "does not echo the suspicious memo in the error" do
      memo = "Payroll for jane.doe@example.com"

      assert {:error, error} = MemoScan.check(memo, :memo)
      refute inspect(error) =~ "jane.doe"
    end
  end
end
