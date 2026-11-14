defmodule Samen.Scopes.Finance.ApBillEntryVoidGuard do
  @moduledoc """
  Refuses the direct `JournalEntry.:void` door on an AP bill's own ledger
  entries.

  The approval entry (`source_key: "ap_invoice"`) is the ledger half of a bill,
  not an independent fact: voiding it directly would reverse expense/AP while
  the bill stayed `:approved` and the close's shared `fx_revaluation` entry
  stayed posted. The clearing entry (`source_key: "ap_void"`) is the mirror
  half of the bill's governed void; voiding it directly would leave the bill
  `:void` with its AP and unrealized FX restored in the ledger.

  `ApInvoice.:void` is the only bill-level door. It posts the bill-specific
  clearing entry and flips the bill to `:void` in one transaction. This guard
  runs on the generic entry `:void` action before `VoidGuard` can post a
  reversal, so neither direct path can strand the subledger.

  `ap_payment` entries are deliberately not blocked here: their sanctioned
  reversal is `ApPaymentReversal` → `ApInvoice.:reverse_payment` →
  `ReverseApPayment`, which calls the entry's `:void` as the system cascade.
  """

  use Ash.Resource.Change

  @governed_sources ["ap_invoice", "ap_void"]

  @impl true
  def change(changeset, _opts, _context) do
    if source_key(changeset) in @governed_sources do
      Ash.Changeset.add_error(changeset,
        field: :base,
        message:
          "an AP bill's ledger entry cannot be voided directly — void the bill through " <>
            "ApInvoice.:void so its AP and cumulative unrealized FX clear together"
      )
    else
      changeset
    end
  end

  defp source_key(changeset) do
    Ash.Changeset.get_attribute(changeset, :source_key) || changeset.data.source_key
  end
end
