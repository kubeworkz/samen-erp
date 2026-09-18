defmodule Samen.Scopes.Banking.Categorize do
  @moduledoc """
  The categorize action for Banking.StatementLine (WS-ERP E9).

  When a statement line has no matching system transaction, the user
  categorizes it into a GL expense or income account. This module creates
  the corresponding journal entry in the SAME transaction as the
  categorization — the categorization IS the posting (same pattern as
  `Samen.Scopes.Finance.ApPosting`).

  The journal entry:
  - **Debit** the expense/income account (the user's categorization)
  - **Credit** the bank account (the GL cash account linked to the BankAccount)

  For a credit statement line (money in):
  - **Debit** the bank account
  - **Credit** the income account

  The entry is created as `:posted` (not draft) because bank transactions
  are facts — the bank said this happened. The source_key/source_id anchors
  the entry to the statement line.

  After the entry is created, the statement line's status is updated to
  `:categorized`.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, context) do
    Ash.Changeset.after_action(changeset, fn changeset, line ->
      bank_account_id = Ash.Changeset.get_attribute(changeset, :bank_account_id)
      amount_cents = Ash.Changeset.get_attribute(changeset, :amount_cents)
      account_id = Ash.Changeset.get_attribute(changeset, :account_id)
      posted_at = Ash.Changeset.get_attribute(changeset, :posted_at)
      description = Ash.Changeset.get_attribute(changeset, :description)

      if account_id do
        create_categorization_entry(
          changeset,
          context,
          line,
          bank_account_id,
          amount_cents,
          account_id,
          posted_at,
          description
        )
      else
        {:ok, line}
      end
    end)
  end

  defp create_categorization_entry(
         changeset,
         context,
         line,
         bank_account_id,
         amount_cents,
         account_id,
         posted_at,
         description
       ) do
    # Resolve the entry and line resources from the domain
    entry_resource = resolve_entry_resource(changeset)
    line_resource = resolve_line_resource(entry_resource)
    bank_account_resource = resolve_bank_account_resource(changeset)

    # Get the bank account's GL account_id
    bank_account = Ash.get!(bank_account_resource, bank_account_id, authorize?: false)
    gl_account_id = bank_account.account_id

    # Determine debit/credit based on sign of amount
    # Positive amount (credit from bank) → debit bank, credit income
    # Negative amount (debit from bank) → debit expense, credit bank
    {debit_account_id, credit_account_id, abs_amount} =
      if amount_cents > 0 do
        {gl_account_id, account_id, amount_cents}
      else
        {account_id, gl_account_id, abs(amount_cents)}
      end

    # Create the journal entry in ONE transaction
    entry_attrs = %{
      entry_date: NaiveDateTime.to_date(posted_at),
      memo: "Bank: #{description}",
      status: :posted,
      posted_at: posted_at,
      source_key: "bank_statement_line",
      source_id: line.id,
      org_id: line.org_id
    }

    lines = [
      %{account_id: debit_account_id, debit_cents: abs_amount, credit_cents: 0},
      %{account_id: credit_account_id, debit_cents: 0, credit_cents: abs_amount}
    ]

    case Ash.create(entry_resource, Map.put(entry_attrs, :lines, lines),
           authorize?: false,
           context: context
         ) do
      {:ok, _entry} ->
        # Update the statement line status to :categorized
        line_resource
        |> Ash.Changeset.for_update(:update_status, %{status: :categorized},
          authorize?: false
        )
        |> Ash.update(authorize?: false)
        |> case do
          {:ok, updated_line} -> {:ok, updated_line}
          {:error, _} -> {:ok, line}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resolve_entry_resource(changeset) do
    changeset.resource
    |> Ash.Resource.Info.relationships()
    |> Enum.find(&(&1.name == :entry))
    |> Map.fetch!(:destination)
  end

  defp resolve_line_resource(entry_resource) do
    entry_resource
    |> Ash.Resource.Info.relationships()
    |> Enum.find(&(&1.name == :lines))
    |> Map.fetch!(:destination)
  end

  defp resolve_bank_account_resource(changeset) do
    changeset.resource
    |> Ash.Resource.Info.relationships()
    |> Enum.find(&(&1.name == :bank_account))
    |> Map.fetch!(:destination)
  end
end
