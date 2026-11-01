defmodule Samen.Scopes.Finance.ReservePosting do
  @moduledoc """
  The posting cascade for an approved obsolescence write-down (WS-ACCT Phase 9;
  ADR-054 D10).

  Runs in `:post`'s `before_action` — INSIDE the ADR-040 decision transaction,
  so a posting failure rolls back the approval transition too. It re-derives the
  assessment from governed state and compares the draft's persisted lines with
  what the stock says NOW:

    * a line whose item, quantity, write-down cents or inventory account no
      longer matches is `:assessment_drift` — an approval consents to the stock
      that is there, never to a snapshot that has moved;
    * the header total must equal Σ its lines (`:total_mismatch`);
    * `write_down_expense` must be mapped (`:unmapped_posting_account`), like
      every other posting cascade;
    * a zero total is refused.

  If all of that holds, it creates ONE posted entry — debit `write_down_expense`
  for the total, credit each line's inventory account for that account's share
  (the manual's JE-062 shape: one expense debit, one credit per finished-goods
  account) — anchored `source_key: "reserve_write_down"`, `source_id: <this
  row>`, and stamps the header `:posted`.

  The netting in `ReserveAssessment` is what makes a re-assessment after this
  posting propose only the remaining value; this module's drift check is what
  makes a stale draft refuse instead of expensing an old number twice.
  """

  use Ash.Resource.Change

  require Ash.Query

  @source_key "reserve_write_down"

  @impl true
  def change(changeset, opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      post(changeset, org_id(changeset), opts)
    end)
  end

  defp post(changeset, org_id, opts) do
    assessment_modules = Keyword.fetch!(opts, :assessment)

    if Enum.any?(assessment_modules, fn {_key, mod} -> is_nil(mod) end) do
      add_error(
        changeset,
        "this host has not wired an Inventory scope into Finance — the write-down " <>
          "cannot be re-derived against stock it cannot read (pass `inventory:` to " <>
          "`use Samen.Scopes.Finance`)"
      )
    else
      line_mod = Keyword.fetch!(opts, :line)
      policy_mod = Keyword.fetch!(opts, :policy)
      entry_mod = Keyword.fetch!(opts, :entry)
      pa_mod = Keyword.fetch!(opts, :posting_account)

      draft = changeset.data

      with :ok <- require_draft(draft),
           {:ok, policy} <- load_policy(policy_mod, org_id, draft),
           {:ok, lines} <- lines_of(line_mod, org_id, draft.id),
           :ok <- tie_total(draft, lines),
           {:ok, assessment} <- assess(org_id, policy, draft, assessment_modules, line_mod),
           :ok <- tie_assessment(lines, assessment),
           {:ok, expense} <- posting_account(pa_mod, org_id) do
        land(changeset, org_id, draft, policy, lines, expense, entry_mod)
      else
        {:error, reason} -> add_error(changeset, format(reason))
      end
    end
  end

  # The state machine re-checked over the PERSISTED row inside the decision
  # transaction (the validation ran on a possibly-stale build).
  defp require_draft(%{status: :draft}), do: :ok
  defp require_draft(%{status: other}), do: {:error, {:already_posted, other}}

  defp load_policy(policy_mod, org_id, draft) do
    with {:ok, policy} <- Ash.get(policy_mod, draft.policy_id, authorize?: false),
         %{org_id: ^org_id} <- Ash.load!(policy, [:org_id], authorize?: false) do
      {:ok, policy}
    else
      {:ok, _foreign} -> {:error, :foreign_policy}
      {:error, reason} -> {:error, {:policy_unavailable, reason}}
    end
  end

  defp lines_of(line_mod, org_id, write_down_id) do
    # authz-scope: system posting cascade — the lines of THIS org's write-down,
    # read inside the approved action's transaction to compare with the
    # re-derived assessment.
    lines =
      line_mod
      |> Ash.Query.filter(org_id == ^org_id and write_down_id == ^write_down_id)
      |> Ash.read!(authorize?: false)

    case lines do
      [] -> {:error, :no_lines}
      lines -> {:ok, Enum.sort_by(lines, & &1.item_id)}
    end
  end

  defp tie_total(draft, lines) do
    total = Enum.reduce(lines, 0, &(&1.write_down_cents + &2))

    cond do
      total <= 0 -> {:error, :zero_total}
      draft.amount_cents != total -> {:error, {:total_mismatch, draft.amount_cents, total}}
      true -> :ok
    end
  end

  defp assess(org_id, policy, draft, modules, line_mod) do
    {:ok,
     Samen.Scopes.Finance.ReserveAssessment.assess(org_id, policy,
       items: Keyword.fetch!(modules, :items),
       levels: Keyword.fetch!(modules, :levels),
       ledger: Keyword.fetch!(modules, :ledger),
       write_downs: draft.__struct__,
       lines: line_mod,
       as_of: draft.assessed_on
     )}
  end

  defp tie_assessment(lines, assessment) do
    expected = assessment.candidates |> Enum.map(&signature/1) |> Enum.sort()
    actual = lines |> Enum.map(&signature/1) |> Enum.sort()

    if expected == actual do
      :ok
    else
      {:error, {:assessment_drift, expected -- actual, actual -- expected}}
    end
  end

  defp signature(row) do
    {row.item_id, row.quantity, row.write_down_cents, row.inventory_account_id}
  end

  defp posting_account(pa_mod, org_id) do
    case pa_mod
         |> Ash.Query.filter(org_id == ^org_id and key == :write_down_expense)
         |> Ash.read_one(authorize?: false) do
      {:ok, nil} -> {:error, {:unmapped_posting_account, :write_down_expense}}
      {:ok, row} -> {:ok, row}
      {:error, reason} -> {:error, reason}
    end
  end

  defp land(changeset, org_id, draft, policy, lines, expense, entry_mod) do
    total = Enum.reduce(lines, 0, &(&1.write_down_cents + &2))

    credits =
      lines
      |> Enum.group_by(& &1.inventory_account_id, & &1.write_down_cents)
      |> Enum.map(fn {account_id, amounts} ->
        %{account_id: account_id, debit_cents: 0, credit_cents: Enum.sum(amounts)}
      end)
      |> Enum.sort_by(& &1.account_id)

    entry_lines =
      [%{account_id: expense.account_id, debit_cents: total, credit_cents: 0} | credits]
      |> Enum.reject(&(&1.debit_cents == 0 and &1.credit_cents == 0))

    entry_attrs = %{
      org_id: org_id,
      entry_date: draft.assessed_on,
      memo: "Inventory write-down — #{policy.name}",
      source_key: @source_key,
      source_id: draft.id,
      lines: entry_lines
    }

    case entry_mod
         |> Ash.Changeset.for_create(:create_reversal, entry_attrs, authorize?: false)
         |> Ash.create(authorize?: false) do
      {:ok, entry} ->
        changeset
        |> Ash.Changeset.force_change_attribute(:status, :posted)
        |> Ash.Changeset.force_change_attribute(:entry_id, entry.id)
        |> Ash.Changeset.force_change_attribute(:posted_at, now())

      {:error, reason} ->
        add_error(changeset, "the write-down's posting entry failed to land: #{inspect(reason)}")
    end
  end

  # ── errors ─────────────────────────────────────────────────────────────────

  defp format({:already_posted, _status}),
    do: "this write-down is already posted — a posted write-down is final"

  defp format(:no_lines), do: "the write-down carries no assessment lines"
  defp format(:zero_total), do: "the write-down total is zero — that is not a fact"
  defp format(:foreign_policy), do: "the reserve policy does not belong to this org"

  defp format({:total_mismatch, header, lines}),
    do:
      "the draft header says #{header} cents but its lines sum to #{lines} — " <>
        "a write-down must tie to the assessment it carries"

  defp format({:unmapped_posting_account, key}),
    do:
      "no PostingAccount row maps `#{key}` for this org (fail-honest — accounts are a " <>
        "host decision; seed the org's posting accounts first)"

  defp format({:assessment_drift, missing, extra}),
    do:
      "the stock assessment changed since this draft was made " <>
        "(no longer proposed: #{inspect(missing)}; newly proposed: #{inspect(extra)}) — " <>
        "re-assess instead of posting a stale estimate"

  defp format(reason), do: inspect(reason)

  defp add_error(changeset, message) do
    Ash.Changeset.add_error(changeset, field: :base, message: message)
  end

  defp org_id(changeset) do
    case Ash.Changeset.get_attribute(changeset, :org_id) do
      %Ash.NotLoaded{} -> persisted_org_id(changeset.data)
      nil -> persisted_org_id(changeset.data)
      value -> value
    end
  end

  # The Gate loads the record without tenant columns selected, so `org_id` can
  # be an #Ash.NotLoaded{} placeholder on the record the decision transaction
  # hands us. Load it — never compare a placeholder to a real id.
  defp persisted_org_id(record) do
    case record.org_id do
      %Ash.NotLoaded{} -> Ash.load!(record, [:org_id], authorize?: false).org_id
      value -> value
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
