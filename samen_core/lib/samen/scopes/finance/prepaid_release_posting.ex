defmodule Samen.Scopes.Finance.PrepaidReleasePosting do
  @moduledoc """
  The prepaid release cascade (WS-ACCT prepaid expense slice): on `:release`,
  post `Dr expense/WIP / Cr prepaid asset` and create the release row in the
  same transaction.

  This mirrors the asset/revenue cascades:

    * the amount is re-derived from the schedule (`PrepaidSchedule.slice/2`) and
      a crafted amount is refused;
    * the date must be the period's last day;
    * the schedule and both accounts are pinned to the releasing org;
    * the entry is drafted first, then posted through the ordinary `:post`
      action, so R1, R6 and R10 run exactly as they do for a human entry;
    * the release id is minted before the entry, so the ADR-041 anchor
      `source_key: "prepaid_release"`, `source_id: <release id>` names a row
      that inserts with that same id.

  The release row names the two accounts it paid. A later change to the
  schedule's account pair cannot rewrite the historical release: the row keeps
  the accounts actually used.
  """

  use Ash.Resource.Change

  alias Samen.Scopes.Finance.PrepaidSchedule

  @source_key "prepaid_release"

  @doc "The object-ref anchor every prepaid release entry carries."
  def source_key, do: @source_key

  @impl true
  def change(changeset, opts, _context) do
    schedule_mod = Keyword.fetch!(opts, :schedule)
    entry_mod = Keyword.fetch!(opts, :entry)
    account_mod = Keyword.fetch!(opts, :account)

    org_id = Ash.Changeset.get_attribute(changeset, :org_id)

    Ash.Changeset.before_action(changeset, fn changeset ->
      post(changeset, org_id, schedule_mod, entry_mod, account_mod)
    end)
  end

  defp post(changeset, org_id, schedule_mod, entry_mod, account_mod) do
    schedule_id = Ash.Changeset.get_attribute(changeset, :schedule_id)
    amount = Ash.Changeset.get_attribute(changeset, :amount_cents)
    period_key = Ash.Changeset.get_attribute(changeset, :period_key)
    released_on = Ash.Changeset.get_attribute(changeset, :released_on)

    with {:ok, schedule} <- load_schedule(schedule_mod, org_id, schedule_id),
         {:ok, period} <- parse_period(period_key),
         {:ok, expected} <- slice(schedule, period_key),
         :ok <- ensure_amount(expected, amount),
         :ok <- ensure_period_end(period, released_on),
         {:ok, prepaid} <-
           load_account(account_mod, org_id, schedule.prepaid_account_id, :prepaid_account_id),
         {:ok, expense} <-
           load_account(account_mod, org_id, schedule.expense_account_id, :expense_account_id),
         id <- Ash.UUID.generate(),
         {:ok, _entry} <-
           create_entry(
             entry_mod,
             org_id,
             id,
             schedule,
             period_key,
             released_on,
             amount,
             prepaid,
             expense
           ) do
      changeset
      |> Ash.Changeset.force_change_attribute(:id, id)
      |> Ash.Changeset.force_change_attribute(:prepaid_account_id, prepaid.id)
      |> Ash.Changeset.force_change_attribute(:expense_account_id, expense.id)
    else
      {:error, reason} ->
        Ash.Changeset.add_error(changeset,
          field: :base,
          message: "the prepaid release cannot be posted: #{format(reason)}"
        )
    end
  end

  defp load_schedule(schedule_mod, org_id, schedule_id) do
    require Ash.Query

    case schedule_mod
         |> Ash.Query.filter(id == ^schedule_id and org_id == ^org_id)
         |> Ash.read_one(authorize?: false) do
      {:ok, nil} -> {:error, {:foreign_schedule, schedule_id}}
      {:ok, schedule} -> {:ok, schedule}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_period(key) do
    case PrepaidSchedule.parse_period(key) do
      {:ok, period} -> {:ok, period}
      :error -> {:error, {:bad_period, key}}
    end
  end

  defp slice(schedule, period_key) do
    case PrepaidSchedule.slice(schedule, period_key) do
      {:ok, amount} -> {:ok, amount}
      :outside_term -> {:error, {:outside_term, period_key}}
      {:error, :bad_period} -> {:error, {:bad_period, period_key}}
    end
  end

  defp ensure_amount(expected, expected), do: :ok

  defp ensure_amount(expected, got),
    do: {:error, {:amount_not_the_schedule, expected, got}}

  defp ensure_period_end(_period, nil), do: {:error, :released_on_missing}

  defp ensure_period_end(period, on) do
    expected = PrepaidSchedule.period_end(period)

    if Date.compare(on, expected) == :eq,
      do: :ok,
      else: {:error, {:not_period_end, expected, on}}
  end

  defp load_account(_account_mod, _org_id, nil, field),
    do: {:error, {:account_missing, field}}

  defp load_account(account_mod, org_id, account_id, field) do
    require Ash.Query

    case account_mod
         |> Ash.Query.filter(id == ^account_id and org_id == ^org_id)
         |> Ash.read_one(authorize?: false) do
      {:ok, nil} -> {:error, {:account_not_found, field, account_id}}
      {:ok, account} -> {:ok, account}
      {:error, reason} -> {:error, {:account_unreadable, field, reason}}
    end
  end

  defp create_entry(
         entry_mod,
         org_id,
         id,
         schedule,
         period_key,
         entry_date,
         amount,
         prepaid,
         expense
       ) do
    with {:ok, draft} <-
           entry_mod
           |> Ash.Changeset.for_create(
             :create,
             %{
               org_id: org_id,
               entry_date: entry_date,
               memo: "Prepaid release #{schedule.code} #{period_key}",
               source_key: @source_key,
               source_id: id,
               lines: [
                 %{
                   account_id: expense.id,
                   debit_cents: amount,
                   dimension_refs: dimension_refs(schedule)
                 },
                 %{
                   account_id: prepaid.id,
                   credit_cents: amount,
                   dimension_refs: dimension_refs(schedule)
                 }
               ]
             },
             authorize?: false
           )
           |> Ash.create(authorize?: false),
         {:ok, posted} <-
           draft
           |> Ash.Changeset.for_update(:post, %{}, authorize?: false)
           |> Ash.update(authorize?: false) do
      {:ok, posted}
    end
  end

  defp dimension_refs(%{cost_object_id: nil}), do: %{}

  defp dimension_refs(%{cost_object_id: cost_object_id, dimension_key: key}),
    do: %{to_string(key) => cost_object_id}

  defp format({:foreign_schedule, id}), do: "schedule #{id} does not belong to this org"

  defp format({:amount_not_the_schedule, expected, got}) do
    "the schedule says #{expected} cents for this period, but the release carries " <>
      "#{got} — the contract is the only source of the amount"
  end

  defp format({:outside_term, key}),
    do: "period #{key} is outside the prepaid term — there is no slice to release"

  defp format({:not_period_end, expected, got}),
    do: "the release must be dated the period's last day (#{expected}), not #{got}"

  defp format({:bad_period, key}), do: "#{inspect(key)} is not a \"YYYY-MM\" period key"

  defp format({:account_missing, field}),
    do: "the schedule has no #{field} account"

  defp format({:account_not_found, field, id}),
    do: "the schedule's #{field} (#{id}) is not an account in this org"

  defp format({:account_unreadable, field, reason}),
    do: "the schedule's #{field} account could not be read: #{inspect(reason)}"

  defp format(reason), do: inspect(reason)
end
