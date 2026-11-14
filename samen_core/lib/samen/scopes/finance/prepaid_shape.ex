defmodule Samen.Scopes.Finance.PrepaidShape do
  @moduledoc """
  The prepaid-schedule shape guard (WS-ACCT prepaid expense slice).

  A prepaid release is `Dr expense/WIP / Cr prepaid asset`. The schedule names
  both accounts directly, so this guard pins the meanings at create time:

    * the prepaid account must be a same-org **asset** account with a debit
      normal side;
    * the expense account must be a same-org **expense** or **asset** account
      with a debit normal side (WIP is an asset, but released prepaid foundry
      cost lands there rather than in an expense account);
    * the two accounts must be different.

  The account ids are host data, not invented by the engine. Cross-org ids are
  refused here as well as by `SameOrgFk`, so a crafted id cannot become a
  tenant-boundary hole.
  """

  use Ash.Resource.Change

  require Ash.Query

  @impl true
  def change(changeset, opts, _context) do
    account_mod = Keyword.fetch!(opts, :account)

    Ash.Changeset.before_action(changeset, fn changeset ->
      validate(changeset, account_mod)
    end)
  end

  defp validate(changeset, account_mod) do
    org_id = Ash.Changeset.get_attribute(changeset, :org_id)
    prepaid_id = Ash.Changeset.get_attribute(changeset, :prepaid_account_id)
    expense_id = Ash.Changeset.get_attribute(changeset, :expense_account_id)

    with {:ok, prepaid} <-
           load_account(account_mod, org_id, prepaid_id, :prepaid_account_id),
         {:ok, expense} <-
           load_account(account_mod, org_id, expense_id, :expense_account_id) do
      cond do
        prepaid.kind != :asset or prepaid.normal_side != :debit ->
          add_error(
            changeset,
            :prepaid_account_id,
            "the prepaid account must be a debit-normal asset account"
          )

        expense.kind not in [:expense, :asset] or expense.normal_side != :debit ->
          add_error(
            changeset,
            :expense_account_id,
            "the release target must be a debit-normal expense or asset (WIP) account"
          )

        prepaid.id == expense.id ->
          add_error(
            changeset,
            :expense_account_id,
            "the prepaid and release-target accounts must be different"
          )

        true ->
          changeset
      end
    else
      {:error, field, message} -> add_error(changeset, field, message)
    end
  end

  defp load_account(_account_mod, _org_id, nil, field) do
    {:error, field, "is required"}
  end

  defp load_account(account_mod, org_id, id, field) do
    case account_mod
         |> Ash.Query.filter(id == ^id and org_id == ^org_id)
         |> Ash.read_one(authorize?: false) do
      {:ok, nil} -> {:error, field, "must name an account in this org"}
      {:ok, account} -> {:ok, account}
      {:error, reason} -> {:error, field, "could not be read: #{inspect(reason)}"}
    end
  end

  defp add_error(changeset, field, message),
    do: Ash.Changeset.add_error(changeset, field: field, message: message)
end
