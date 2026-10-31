defmodule Samen.Scopes.Finance.AccrualGuard do
  @moduledoc """
  The automatic reversal of an accrual (WS-ACCT Phase 5; ADR-054 D6).

  The source manual's control is explicit: *"reverse all month-end accruals on
  the first day of the following month to avoid double-counting."* That is a
  habit, and a habit is what an over-worked close loses. `:post_accrual` makes
  it mechanism: ONE action lands the accrual (posted) and its **draft**
  reversal, dated the reversal date, in the same transaction. If the reversal
  cannot be created the accrual rolls back — an accrual with no scheduled
  reversal is not an accrual.

  ## How the accrual posts

  `:post_accrual` CREATES the accrual as a draft, and this guard posts it
  through the ordinary `:post` action inside the same transaction. That is not
  indirection for its own sake: a create-born-POSTED entry cannot insert its
  own lines, because `PostGuard`'s marker restore unwinds before `EntryLines`
  materializes them (the posted-born-factory quirk the Phase 3 plan records).
  Going through `:post` also means R1 (`PostBalance`), R6
  (`DimensionBalance`) and R10 (`PeriodGuard`) all evaluate the accrual exactly
  as they would a human posting — nothing about this door is privileged.

  ## Why the reversal is a DRAFT

  A void's reversal (`Samen.Scopes.Finance.VoidGuard`) is born POSTED, because
  the void IS the decision and its reversal is the same instant's fact. An
  accrual is different: the reversal is *scheduled*. Posting it now would
  double-count the expense until someone posted the flip later. So the reversal
  is a draft that
  `Samen.Scopes.Finance.AccrualReversal` posts on its date through the ordinary
  governed `:post` action — PeriodGuard, PostBalance, DimensionBalance and
  PostGuard all run, exactly as they would for a human posting it.

  ## The link

  The reversal carries `source_key: "accrual_reversal"`, `source_id: <accrual>`
  and `voided_entry_id: <accrual>` — the ADR-041 anchor plus the void
  precedent's back-link, so "what reverses this accrual?" is an indexed read,
  not a memo grep. The accrual itself is NOT stamped: `voided_entry_id` on the
  original means *"this entry was voided"*, and an accrual is not voided — it is
  reversed on schedule.

  ## Ratio/period notes

  The reversal mirrors the lines (debit ↔ credit) AND their `dimension_refs`,
  for the same reason `VoidGuard` does: a dimensioned pair whose other half
  dropped its dimensions leaves the cost object one-sided and R6 flags a ledger
  nothing was wrong with.
  """

  use Ash.Resource.Change

  @source_key "accrual_reversal"

  @doc "The object-ref anchor every scheduled reversal carries."
  def source_key, do: @source_key

  @impl true
  def change(changeset, _opts, _context) do
    if changeset.action && changeset.action.name == :post_accrual do
      # Capture the tenant NOW (attributes still pending; inside after_action the
      # created record's org_id may be a placeholder — the EntryLines posture).
      org_id =
        case Ash.Changeset.get_attribute(changeset, :org_id) do
          %Ash.NotLoaded{} -> Ash.load!(changeset.data, [:org_id], authorize?: false).org_id
          value -> value
        end

      changeset
      |> Ash.Changeset.before_action(&validate_schedule/1)
      |> Ash.Changeset.after_action(fn changeset, entry ->
        schedule_and_post(changeset, entry, org_id)
      end)
    else
      changeset
    end
  end

  # Schedule first, then post: the accrual only becomes a fact once its
  # reversal is scheduled, and both live in the action's transaction, so a
  # refusal on either side leaves neither row.
  defp schedule_and_post(changeset, entry, org_id) do
    with {:ok, _reversal} <- create_reversal(changeset, entry, org_id),
         {:ok, posted} <- post(entry) do
      {:ok, posted}
    end
  end

  defp post(entry) do
    entry
    |> Ash.Changeset.for_update(:post, %{})
    |> Ash.update(authorize?: false)
  end

  # The reversal must land AFTER the accrual it reverses. Same-day would net to
  # zero inside one period, which is the double-count the control exists to
  # prevent; an earlier date would post a reversal before its accrual.
  defp validate_schedule(changeset) do
    reversal_on = Ash.Changeset.get_argument(changeset, :reversal_on)
    entry_date = Ash.Changeset.get_attribute(changeset, :entry_date)

    if is_struct(reversal_on, Date) and is_struct(entry_date, Date) and
         Date.compare(reversal_on, entry_date) != :gt do
      Ash.Changeset.add_error(changeset,
        field: :base,
        message:
          "the reversal date (#{Date.to_iso8601(reversal_on)}) must be AFTER the accrual's " <>
            "date (#{Date.to_iso8601(entry_date)}) — an accrual reverses in a later period, " <>
            "otherwise the pair nets to zero inside the period it was meant to charge"
      )
    else
      changeset
    end
  end

  defp create_reversal(changeset, entry, org_id) do
    reversal_on = Ash.Changeset.get_argument(changeset, :reversal_on)
    lines = Ash.Changeset.get_argument(changeset, :lines) || []

    attrs = %{
      org_id: org_id,
      entry_date: reversal_on,
      memo: "Accrual reversal of entry #{entry.id}" <> memo_suffix(entry.memo),
      source_key: @source_key,
      source_id: entry.id,
      voided_entry_id: entry.id,
      lines: Enum.map(lines, &mirror_line/1)
    }

    changeset.resource
    |> Ash.Changeset.for_create(:create_accrual_reversal, attrs, authorize?: false)
    |> Ash.create(authorize?: false)
    |> case do
      {:ok, _reversal} -> {:ok, entry}
      {:error, reason} -> {:error, reason}
    end
  end

  # debit ↔ credit, dimensions copied verbatim (see the moduledoc).
  defp mirror_line(line) do
    %{
      account_id: fetch(line, :account_id),
      debit_cents: fetch(line, :credit_cents) || 0,
      credit_cents: fetch(line, :debit_cents) || 0,
      memo: fetch(line, :memo),
      dimension_refs: fetch(line, :dimension_refs) || %{}
    }
  end

  defp fetch(line, key), do: Map.get(line, key) || Map.get(line, to_string(key))

  defp memo_suffix(nil), do: ""
  defp memo_suffix(""), do: ""
  defp memo_suffix(memo), do: " — " <> memo
end
