defmodule Samen.Scopes.Finance.LabourAllocationPosting do
  @moduledoc """
  The posting cascade for a labour allocation (WS-ACCT Unit 10.2;
  ADR-054 D17).

  Runs in `:post`'s `before_action`, inside the action's transaction. It
  re-reads the governed facts and lands **ONE** entry for the whole payroll
  split:

      for every cost object share:
        Dr target account   share cents   dimension: <axis> => cost object
        Cr source account   share cents   dimension: <axis> => cost object

  The symmetric pair is what makes the entry R6-clean: each programme's debits
  equal its credits, while the payroll expense account is cleared exactly once.

  ## The driver is re-derived, not trusted

  `:draft` froze the approved minutes into append-only shares. Between drafting
  and posting, more hours can be approved. This cascade therefore re-runs
  `Samen.Scopes.Finance.LabourDriver` over the same period and refuses
  `labour_drift` unless the minutes per cost object are IDENTICAL — not merely
  the same total, which two different splits can share — and unless the shares
  still sum to the header total. A stale draft is re-drafted; it is never
  posted against hours that moved.

  ## Date and anchor

  The entry lands on the payroll period's `period_end` (the period the cost
  belongs to), anchored `source_key: "labour_allocation"`,
  `source_id: <this header>`. The posted-born entry factory's own `PostGuard`
  restores the transaction-local marker; the header carries `PostingMarker` so
  it is armed before the factory inserts (the AP/PO approve precedent). R10
  refuses a closed period on the entry date.
  """

  use Ash.Resource.Change

  require Ash.Query

  alias Samen.Scopes.Finance.LabourDriver

  @source_key "labour_allocation"

  @impl true
  def change(changeset, opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      post(changeset, org_id(changeset), opts)
    end)
  end

  defp post(changeset, org_id, opts) do
    header = changeset.data

    with :ok <- require_draft(header),
         {:ok, shares} <- shares_of(Keyword.fetch!(opts, :share), org_id, header.id),
         :ok <- require_two(shares),
         :ok <- tie_total(header, shares),
         {:ok, driver} <-
           LabourDriver.driver(org_id, header.period_start, header.period_end, opts),
         :ok <- tie_driver(shares, driver),
         {:ok, source} <-
           load_account(Keyword.fetch!(opts, :account), org_id, header.source_account_id),
         {:ok, target} <-
           load_account(Keyword.fetch!(opts, :account), org_id, header.target_account_id),
         :ok <- require_different(source, target) do
      land(changeset, org_id, header, shares, source, target, Keyword.fetch!(opts, :entry))
    else
      {:error, reason} -> error(changeset, format(reason))
    end
  end

  # ── re-checked facts ───────────────────────────────────────────────────────

  defp require_draft(%{status: :draft}), do: :ok
  defp require_draft(%{status: other}), do: {:error, {:not_draft, other}}

  defp shares_of(share_mod, org_id, allocation_id) do
    # authz-scope: system posting cascade — the shares of THIS org's allocation,
    # read inside the approved action's transaction to rebuild the entry.
    rows =
      share_mod
      |> Ash.Query.filter(org_id == ^org_id and labour_allocation_id == ^allocation_id)
      |> Ash.Query.sort(cost_object_id: :asc)
      |> Ash.read!(authorize?: false)

    case rows do
      [] -> {:error, :no_shares}
      rows -> {:ok, rows}
    end
  end

  defp require_two(shares) when length(shares) >= 2, do: :ok
  defp require_two(_shares), do: {:error, :too_few_shares}

  defp tie_total(header, shares) do
    total = Enum.reduce(shares, 0, &(&1.allocated_cents + &2))

    cond do
      total <= 0 -> {:error, :zero_total}
      header.total_cents != total -> {:error, {:total_mismatch, header.total_cents, total}}
      true -> :ok
    end
  end

  defp tie_driver(shares, driver) do
    persisted = minutes_by_cost_object(shares)
    derived = minutes_by_cost_object(driver.shares)

    if persisted == derived do
      :ok
    else
      {:error, {:labour_drift, persisted, derived}}
    end
  end

  defp minutes_by_cost_object(rows) do
    Map.new(rows, fn row ->
      {row.cost_object_id, Map.get(row, :minutes) || Map.get(row, :driver)}
    end)
  end

  defp load_account(account_mod, org_id, account_id) do
    case Ash.get(account_mod, account_id, authorize?: false) do
      {:ok, account} ->
        account = Ash.load!(account, [:org_id], authorize?: false)

        if account.org_id == org_id do
          {:ok, account}
        else
          {:error, :foreign_account}
        end

      {:error, _reason} ->
        {:error, :missing_account}
    end
  end

  defp require_different(%{id: id}, %{id: id}), do: {:error, :same_account}
  defp require_different(_source, _target), do: :ok

  # ── the one entry ──────────────────────────────────────────────────────────

  defp land(changeset, org_id, header, shares, source, target, entry_mod) do
    axis = Atom.to_string(header.axis)
    minutes = Enum.reduce(shares, 0, &(&1.minutes + &2))

    entry_lines =
      Enum.flat_map(shares, fn share ->
        refs = %{axis => share.cost_object_id}

        [
          %{
            account_id: target.id,
            debit_cents: share.allocated_cents,
            credit_cents: 0,
            dimension_refs: refs
          },
          %{
            account_id: source.id,
            debit_cents: 0,
            credit_cents: share.allocated_cents,
            dimension_refs: refs
          }
        ]
      end)

    entry_attrs = %{
      org_id: org_id,
      entry_date: header.period_end,
      memo:
        "Payroll allocation — #{header.period_start}..#{header.period_end} (#{minutes} min)",
      source_key: @source_key,
      source_id: header.id,
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
        error(changeset, "the payroll allocation's posting entry failed to land: #{inspect(reason)}")
    end
  end

  # ── errors / plumbing ──────────────────────────────────────────────────────

  defp format({:not_draft, status}) do
    "this payroll allocation is #{inspect(status)} — a posted allocation is final; " <>
      "a correction is a reversing entry, never a re-post"
  end

  defp format(:no_shares), do: "the labour allocation carries no shares"
  defp format(:too_few_shares), do: "a labour allocation needs at least two cost objects"
  defp format(:zero_total), do: "the labour allocation total is zero — that is not a fact"

  defp format({:total_mismatch, header, shares}) do
    "the allocation header says #{header} cents but its shares sum to #{shares} — a " <>
      "post must tie to the split it was drafted from"
  end

  defp format({:labour_drift, persisted, derived}) do
    "the approved timesheets for this period now attribute " <>
      "#{sum(derived)} minutes across #{map_size(derived)} cost object(s), not the " <>
      "#{sum(persisted)} minutes across #{map_size(persisted)} this draft froze " <>
      "(labour drift) — re-draft instead of posting a split the hours no longer support"
  end

  defp format(:foreign_account), do: "a labour allocation account does not belong to this org"
  defp format(:missing_account), do: "a labour allocation account no longer exists"
  defp format(:same_account), do: "the source and target accounts are the same — nothing would move"
  defp format(reason), do: inspect(reason)

  defp sum(map), do: map |> Map.values() |> Enum.sum()

  defp error(changeset, message) do
    Ash.Changeset.add_error(changeset, field: :base, message: message)
  end

  defp org_id(changeset) do
    case Ash.Changeset.get_attribute(changeset, :org_id) do
      %Ash.NotLoaded{} -> persisted_org_id(changeset.data)
      nil -> persisted_org_id(changeset.data)
      value -> value
    end
  end

  defp persisted_org_id(record) do
    case record.org_id do
      %Ash.NotLoaded{} -> Ash.load!(record, [:org_id], authorize?: false).org_id
      value -> value
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
