defmodule Samen.Scopes.Finance.LeaseShape do
  @moduledoc """
  The lease-account shape guard.

  A lease names its six accounts directly. This guard pins the meanings at
  create time:

    * the ROU asset and cash accounts must be same-org debit-normal assets;
    * accumulated amortization must be a same-org credit-normal asset contra;
    * the lease liability must be a same-org credit-normal liability;
    * interest and amortization expense must be same-org debit-normal expense
      accounts;
    * all six accounts must be distinct.

  Cross-org ids are refused here as well as by `SameOrgFk`, so a crafted id
  cannot become a tenant-boundary hole.
  """

  use Ash.Resource.Change

  require Ash.Query

  @checks [
    {:rou_asset_account_id, :asset, :debit, "debit-normal asset account"},
    {:accumulated_amortization_account_id, :asset, :credit, "credit-normal asset contra account"},
    {:lease_liability_account_id, :liability, :credit, "credit-normal liability account"},
    {:interest_expense_account_id, :expense, :debit, "debit-normal expense account"},
    {:amortization_expense_account_id, :expense, :debit, "debit-normal expense account"},
    {:cash_account_id, :asset, :debit, "debit-normal asset account"}
  ]

  @impl true
  def change(changeset, opts, _context) do
    account_mod = Keyword.fetch!(opts, :account)

    Ash.Changeset.before_action(changeset, fn changeset ->
      validate(changeset, account_mod)
    end)
  end

  defp validate(changeset, account_mod) do
    org_id = Ash.Changeset.get_attribute(changeset, :org_id)

    accounts =
      Enum.map(@checks, fn {field, kind, side, label} ->
        id = Ash.Changeset.get_attribute(changeset, field)
        {field, kind, side, label, load_account(account_mod, org_id, id, field)}
      end)

    case Enum.find(accounts, fn {_field, _kind, _side, _label, result} ->
           match?({:error, _, _}, result)
         end) do
      {_field, _kind, _side, _label, {:error, field, message}} ->
        add_error(changeset, field, message)

      nil ->
        accounts =
          Enum.map(accounts, fn {field, kind, side, label, {:ok, account}} ->
            {field, kind, side, label, account}
          end)

        cond do
          duplicate =
              accounts
              |> Enum.map(fn {_field, _kind, _side, _label, account} -> account.id end)
              |> Enum.frequencies()
              |> Enum.find(fn {_id, count} -> count > 1 end) ->
            {_id, _count} = duplicate

            add_error(
              changeset,
              :rou_asset_account_id,
              "the ROU, accumulated, liability, interest, amortization and cash accounts must all be different"
            )

          true ->
            case Enum.find(accounts, fn {_field, kind, side, _label, account} ->
                   account.kind != kind or account.normal_side != side
                 end) do
              {field, _kind, _side, label, _account} ->
                add_error(changeset, field, "must be a same-org #{label}")

              nil ->
                changeset
            end
        end
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
