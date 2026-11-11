defmodule Samen.Scopes.Finance.ExpensePosting do
  @moduledoc """
  Posts an approved `ExpenseReport` as one balanced journal entry.

  Each line debits its category's expense account. Corporate-card lines credit
  the card's own liability account; cash/personal lines credit the org's
  `employee_reimbursement_payable` posting account. The entry is anchored
  `source_key: "expense_report"`, `source_id: <report id>` and lands POSTED in
  the report's approval transaction — a report that cannot post is not
  approved.
  """

  use Ash.Resource.Change

  alias Samen.Scopes.Finance.ExpenseLines

  @source_key "expense_report"

  @impl true
  def change(changeset, opts, _context) do
    entry_resource = Keyword.fetch!(opts, :entry)
    posting_account_resource = Keyword.fetch!(opts, :posting_account)
    category_resource = Keyword.fetch!(opts, :category)
    card_resource = Keyword.fetch!(opts, :card)
    org_id = loaded_org_id(changeset)

    Ash.Changeset.before_action(changeset, fn changeset ->
      post(
        changeset,
        org_id,
        entry_resource,
        posting_account_resource,
        category_resource,
        card_resource
      )
    end)
  end

  defp post(
         changeset,
         org_id,
         entry_resource,
         posting_account_resource,
         category_resource,
         card_resource
       ) do
    report = changeset.data

    with :ok <- require_submitted(report),
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
           ) do
      entry_attrs = %{
        org_id: org_id,
        entry_date: Date.utc_today(),
        memo: "Expense report #{report.title}",
        source_key: @source_key,
        source_id: report.id,
        lines: entry_lines(facts, employee_account)
      }

      case entry_resource
           |> Ash.Changeset.for_create(:create_reversal, entry_attrs, authorize?: false)
           |> Ash.create(authorize?: false) do
        {:ok, entry} ->
          changeset
          |> Ash.Changeset.force_change_attribute(:posted_entry_id, entry.id)
          |> Ash.Changeset.force_change_attribute(:approved_at, now())

        {:error, reason} ->
          Ash.Changeset.add_error(changeset,
            field: :base,
            message: "the expense report posting failed: #{inspect(reason)}"
          )
      end
    else
      {:error, reason} ->
        Ash.Changeset.add_error(changeset,
          field: :base,
          message: "the expense report cannot be approved: #{format(reason)}"
        )
    end
  end

  defp entry_lines(facts, employee_account) do
    debits =
      Enum.map(facts.lines, fn line ->
        category = Map.fetch!(facts.categories, line.category_id)

        %{
          account_id: category.account_id,
          debit_cents: line.amount_cents,
          credit_cents: 0
        }
      end)

    card_credits =
      Enum.map(facts.card_cents_by_account, fn {account_id, amount} ->
        %{account_id: account_id, debit_cents: 0, credit_cents: amount}
      end)

    employee_credit =
      if facts.employee_cents > 0 do
        [
          %{
            account_id: employee_account.account_id,
            debit_cents: 0,
            credit_cents: facts.employee_cents
          }
        ]
      else
        []
      end

    debits ++ card_credits ++ employee_credit
  end

  defp require_submitted(%{status: :submitted}), do: :ok

  defp require_submitted(%{status: status}),
    do: {:error, {:not_submitted, status}}

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

  defp format({:not_submitted, status}),
    do: "the report is #{inspect(status)} — only a submitted report can be approved"

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
