defmodule Samen.Scopes.Finance.RecognitionPosting do
  @moduledoc """
  The recognition cascade (WS-ACCT Phase 6; ADR-054 D5): on `:recognize`, land
  the period's journal entry — debit the schedule's deferred account by
  `amount_cents`, credit the org's `income` account — anchored
  `source_key: "revenue_recognition"`, `source_id: <recognition id>`, in the
  SAME transaction as the recognition row.

  The entry is created as a DRAFT and then posted through the ordinary `:post`
  action — the same shape `:post_accrual` uses (WS-ACCT Phase 5), and for the
  same reason: a create-born-POSTED entry cannot insert its own lines, because
  `PostGuard`'s marker restore unwinds before `EntryLines` materializes them.
  Going through `:post` also means R1 (`PostBalance`), R6 (`DimensionBalance`)
  and R10 (`PeriodGuard`) all evaluate the entry exactly as they would a human
  posting — a closed period still refuses, and the deferred/income accounts
  must be mapped for this org (fail-honest: accounts are a host decision).

  ## The id is minted BEFORE the entry

  The recognition row and its entry reference each other through the ADR-041
  anchor, so the entry's `source_id` must be the recognition's id. A
  `before_action` runs before Ash assigns the primary key, so this change mints
  the id (`Ash.UUID.generate/0`), posts the entry against it, and forces it onto
  the changeset — the row then inserts with exactly the id the entry names. The
  alternative (insert, then create the entry in an `after_action`, then update
  the row with the entry id) would need an UPDATE on an append-only fact, which
  the table's belt refuses — correctly.

  A failure anywhere in the cascade adds an error to the changeset, so the
  recognition row does not land either. There is no state in which a
  recognition exists without its entry.
  """

  use Ash.Resource.Change

  @source_key "revenue_recognition"

  @doc "The object-ref anchor every recognition entry carries."
  def source_key, do: @source_key

  @impl true
  def change(changeset, opts, _context) do
    schedule_mod = Keyword.fetch!(opts, :schedule)
    entry_mod = Keyword.fetch!(opts, :entry)
    pa_mod = Keyword.fetch!(opts, :posting_account)

    org_id = Ash.Changeset.get_attribute(changeset, :org_id)

    Ash.Changeset.before_action(changeset, fn changeset ->
      post(changeset, org_id, schedule_mod, entry_mod, pa_mod)
    end)
  end

  defp post(changeset, org_id, schedule_mod, entry_mod, pa_mod) do
    schedule_id = Ash.Changeset.get_attribute(changeset, :schedule_id)
    amount = Ash.Changeset.get_attribute(changeset, :amount_cents)
    period_key = Ash.Changeset.get_attribute(changeset, :period_key)
    recognized_on = Ash.Changeset.get_attribute(changeset, :recognized_on)

    with {:ok, schedule} <- load_schedule(schedule_mod, org_id, schedule_id),
         {:ok, deferred} <- posting_account(pa_mod, org_id, schedule.deferred_key),
         {:ok, income} <- posting_account(pa_mod, org_id, :income),
         id <- Ash.UUID.generate(),
         {:ok, _entry} <-
           create_entry(
             entry_mod,
             org_id,
             id,
             period_key,
             recognized_on,
             amount,
             deferred,
             income,
             schedule
           ) do
      Ash.Changeset.force_change_attribute(changeset, :id, id)
    else
      {:error, reason} ->
        Ash.Changeset.add_error(changeset,
          field: :base,
          message: "the recognition cannot be posted: #{format(reason)}"
        )
    end
  end

  # Read the schedule PINNED to this org (authorize?: false — this is the
  # system cascade): a schedule from another tenant is invisible, so it cannot
  # be posted against, and the refusal is a nil read rather than a comparison
  # over attributes the select does not carry.
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

  defp posting_account(pa_mod, org_id, key) do
    require Ash.Query

    case pa_mod
         |> Ash.Query.filter(org_id == ^org_id and key == ^key)
         |> Ash.read_one(authorize?: false) do
      {:ok, nil} -> {:error, {:unmapped_posting_account, key}}
      {:ok, row} -> {:ok, row}
      {:error, reason} -> {:error, reason}
    end
  end

  # Draft first (so EntryLines can materialize under the draft belt), then the
  # governed `:post` (so R1/R6/R10 run). Both steps are inside the recognition's
  # transaction: a refusal on either leaves neither row.
  defp create_entry(
         entry_mod,
         org_id,
         id,
         period_key,
         entry_date,
         amount,
         deferred,
         income,
         schedule
       ) do
    with {:ok, draft} <-
           entry_mod
           |> Ash.Changeset.for_create(
             :create,
             %{
               org_id: org_id,
               entry_date: entry_date,
               memo: "Revenue recognition #{period_key}",
               source_key: @source_key,
               source_id: id,
               lines: [
                 %{
                   account_id: deferred.account_id,
                   debit_cents: amount,
                   dimension_refs: dimension_refs(schedule)
                 },
                 %{
                   account_id: income.account_id,
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

  # A grant schedule rides the `fund` axis (Phase 11); every other schedule
  # that names a cost object rides the `project` axis. An undimensioned
  # schedule stays undimensioned — R6 passes vacuously.
  defp dimension_refs(%{cost_object_id: nil}), do: %{}

  defp dimension_refs(%{deferred_key: :grant_deferred, cost_object_id: id}) when is_binary(id),
    do: %{"fund" => id}

  defp dimension_refs(%{cost_object_id: id}) when is_binary(id), do: %{"project" => id}

  defp format({:unmapped_posting_account, key}),
    do:
      "no PostingAccount row maps `#{key}` for this org (fail-honest — accounts are a " <>
        "host decision; seed the org's posting accounts first)"

  defp format({:foreign_schedule, id}),
    do: "schedule #{id} does not belong to this org"

  defp format(reason), do: inspect(reason)
end
