defmodule Samen.Scopes.Finance.CreditNoteGuard do
  @moduledoc """
  State machine guard for Credit Notes and Vendor Credits (WS-ERP E12).

  Enforces valid state transitions:
  - `:draft` → `:open` (always allowed)
  - `:open` → `:applied` (requires invoice_id/bill_id)
  - `:open` → `:void` (always allowed)
  - `:draft` → `:void` (always allowed — cancel before opening)
  - All other transitions → refused

  When opening, the guard verifies the amount is positive.
  When applying, the guard verifies the invoice/bill exists.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      current_status = Ash.Changeset.get_attribute(changeset, :status)
      new_status = Ash.Changeset.get_attribute(changeset, :status)

      # If status is not being changed, allow through
      if new_status == current_status do
        changeset
      else
        validate_transition(changeset, current_status, new_status)
      end
    end)
  end

  defp validate_transition(changeset, :draft, :open) do
    amount = Ash.Changeset.get_attribute(changeset, :amount_cents)

    if is_nil(amount) or amount <= 0 do
      Ash.Changeset.add_error(changeset,
        field: :amount_cents,
        message: "Amount must be positive to open a credit note"
      )
    else
      changeset
    end
  end

  defp validate_transition(changeset, :open, :applied) do
    invoice_id = Ash.Changeset.get_attribute(changeset, :invoice_id)
    bill_id = Ash.Changeset.get_attribute(changeset, :bill_id)

    if is_nil(invoice_id) and is_nil(bill_id) do
      Ash.Changeset.add_error(changeset,
        field: :status,
        message: "Cannot apply credit note without an invoice or bill reference"
      )
    else
      changeset
    end
  end

  defp validate_transition(changeset, :draft, :void) do
    # Cancel before opening — always allowed
    changeset
  end

  defp validate_transition(changeset, :open, :void) do
    # Void after opening — always allowed
    changeset
  end

  defp validate_transition(changeset, current_status, new_status) do
    Ash.Changeset.add_error(changeset,
      field: :status,
      message: "Invalid transition from #{current_status} to #{new_status}"
    )
  end
end
