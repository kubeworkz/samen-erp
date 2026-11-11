defmodule Samen.Scopes.Finance.ExpenseSettlement do
  @moduledoc """
  Settles an approved `ExpenseReport` in one balanced journal entry.

  The settlement debits each corporate card's liability account and the
  employee-reimbursement payable for personal/cash lines, and credits the
  org's cash account for the total. It is anchored
  `source_key: "expense_settlement"`, `source_id: <report id>`.
  """

  use Ash.Resource.Change

  alias Samen.Scopes.Finance.ExpenseLines

  @source_key "expense_settlement"

  @impl true
  def change(changeset, opts, _context) do
    entry_resource = Keyword.fetch!(opts, :entry)
    posting_account_resource = Keyword.fetch!(opts, :posting_account)
    category_resource = Keyword.fetch!(opts, :category)
    card_resource = Keyword.fetch!(opts, :card)
    org_id = loaded_org_id(changeset)

    Ash.Changeset.before_action(changeset, fn changeset ->
      settle(
        changeset,
        org_id,
        entry_resource,
        posting_account_resource,
        category_resource,
        card_resource
      )
    end)
  end

  defp settle(
         changeset,
         org_id,
         entry_resource,
         posting_account_resource,
         category_resource,
         card_resource
       ) do
    report = changeset.data

    with :ok <- require_approved(report),
         {:ok, facts} <-
           ExpenseLines.validate(
             report.lines,
             report.currency,
             org_id,
             category_resource,
             card_resource,
             require_lines: true
           ),
         {:ok, employee_account} <-
           maybe_posting_account(
             posting_account_resource,
             org_id,
             :employee_reimbursement_payable,
             facts.employee_cents
           ),
         {:ok, cash} <- posting_account(posting_account_resource, org_id, :cash) do
      entry_attrs = %{
        org_id: org_id,
        entry_date: Date.utc_today(),
        memo: "Expense settlement #{report.title}",
        source_key: @source_key,
        source_id: report.id,
        lines: entry_lines(facts, employee_account, cash)
      }

      case entry_resource
           |> Ash.Changeset.for_create(:create_reversal, entry_attrs, authorize?: false)
           |> Ash.create(authorize?: false) do
        {:ok, entry} ->
          changeset
          |> Ash.Changeset.force_change_attribute(:settlement_entry_id, entry.id)
          |> Ash.Changeset.force_change_attribute(:reimbursed_at, now())

        {:error, reason} ->
          Ash.Changeset.add_error(changeset,
            field: :base,
            message: "the expense settlement failed: #{inspect(reason)}"
          )
      end
    else
      {:error, reason} ->
        Ash.Changeset.add_error(changeset,
          field: :base,
          message: "the expense report cannot be settled: #{format(reason)}"
        )
    end
  end

  defp entry_lines(facts, employee_account, cash) do
    debits =
      Enum.map(facts.card_cents_by_account, fn {account_id, amount} ->
        %{account_id: account_id, debit_cents: amount, credit_cents: 0}
      end)

    employee_debit =
      if facts.employee_cents > 0 do
        [
          %{
            account_id: employee_account.account_id,
            debit_cents: facts.employee_cents,
            credit_cents: 0
          }
        ]
      else
        []
      end

    debits ++
      employee_debit ++
      [
        %{
          account_id: cash.account_id,
          debit_cents: 0,
          credit_cents: facts.total_cents
        }
      ]
  end

  defp require_approved(%{status: :approved}), do: :ok

  defp require_approved(%{status: status}),
    do: {:error, {:not_approved, status}}

  defp maybe_posting_account(_resource, _org_id, _key, 0), do: {:ok, nil}

  defp maybe_posting_account(resource, org_id, key, _amount) do
    posting_account(resource, org_id, key)
  end

  defp posting_account(resource, org_id, key) do
    require Ash.Query

    case resource
         |> Ash.Query.filter(org_id == ^org_id and key == ^key)
         |> Ash.read_one(authorize?: false) do
      {:ok, nil} -> {:error, {:unmapped_posting_account, key}}
      {:ok, row} -> {:ok, row}
      {:error, reason} -> {:error, reason}
    end
  end

  defp format({:not_approved, status}),
    do: "the report is #{inspect(status)} — only an approved report can be settled"

  defp format({:unmapped_posting_account, key}),
    do: "no PostingAccount row maps `#{key}` for this org"

  defp format(reason), do: inspect(reason)

  defp loaded_org_id(changeset) do
    case Ash.Changeset.get_attribute(changeset, :org_id) do
      %Ash.NotLoaded{} -> Ash.load!(changeset.data, [:org_id], authorize?: false).org_id
      nil -> Map.get(changeset.data, :org_id)
      value -> value
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
