defmodule Samen.Scopes.Finance.GrantAwardPosting do
  @moduledoc """
  The restricted-receipt cascade (WS-ACCT Phase 11; ADR-054 D8, JE-070).

  On `Grant.:receive_award`, land ONE posted entry — debit `cash`, credit
  `grant_deferred`, both lines dimensioned to the grant's fund — anchored
  `source_key: "grant_award"`, `source_id: <the grant>`, and stamp the grant
  `:active` with `received_on`.

  The entry is created as a DRAFT and then posted through the ordinary `:post`
  action, the same shape the recognition cascade uses: the draft lets
  `EntryLines` materialize under the draft belt, and `:post` then runs R1
  (`PostBalance`), R6 (`DimensionBalance`) and R10 (`PeriodGuard`) exactly as a
  human posting would. A closed period refuses; an unmapped `cash` or
  `grant_deferred` meaning refuses fail-honest — accounts are a host decision.

  A second `:receive_award` is refused: the award is received once, and a
  correction is a reversing entry, never a re-receipt.
  """

  use Ash.Resource.Change

  require Ash.Query

  @source_key "grant_award"

  @doc "The object-ref anchor every award-receipt entry carries."
  def source_key, do: @source_key

  @impl true
  def change(changeset, opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset -> post(changeset, opts) end)
  end

  defp post(changeset, opts) do
    grant = changeset.data
    org_id = org_id(changeset)
    entry_mod = Keyword.fetch!(opts, :entry)
    pa_mod = Keyword.fetch!(opts, :posting_account)

    if grant.received_on != nil do
      add_error(changeset, "this award has already been received — a second receipt is refused")
    else
      with {:ok, cash} <- posting_account(pa_mod, org_id, :cash),
           {:ok, deferred} <- posting_account(pa_mod, org_id, :grant_deferred),
           {:ok, _entry} <-
             create_entry(entry_mod, org_id, grant, cash.account_id, deferred.account_id) do
        changeset
        |> Ash.Changeset.force_change_attribute(:status, :active)
        |> Ash.Changeset.force_change_attribute(:received_on, Date.utc_today())
      else
        {:error, reason} ->
          add_error(changeset, "the award receipt cannot be posted: #{format(reason)}")
      end
    end
  end

  defp posting_account(pa_mod, org_id, key) do
    case pa_mod
         |> Ash.Query.filter(org_id == ^org_id and key == ^key)
         |> Ash.read_one(authorize?: false) do
      {:ok, nil} -> {:error, {:unmapped_posting_account, key}}
      {:ok, row} -> {:ok, row}
      {:error, reason} -> {:error, reason}
    end
  end

  defp create_entry(entry_mod, org_id, grant, cash_account_id, deferred_account_id) do
    dims = %{"fund" => grant.fund_cost_object_id}

    attrs = %{
      org_id: org_id,
      entry_date: Date.utc_today(),
      memo: "Grant award received — #{grant.award_ref}",
      source_key: @source_key,
      source_id: grant.id,
      lines: [
        %{account_id: cash_account_id, debit_cents: grant.award_cents, dimension_refs: dims},
        %{account_id: deferred_account_id, credit_cents: grant.award_cents, dimension_refs: dims}
      ]
    }

    with {:ok, draft} <-
           entry_mod
           |> Ash.Changeset.for_create(:create, attrs, authorize?: false)
           |> Ash.create(authorize?: false),
         {:ok, posted} <-
           draft
           |> Ash.Changeset.for_update(:post, %{}, authorize?: false)
           |> Ash.update(authorize?: false) do
      {:ok, posted}
    end
  end

  defp format({:unmapped_posting_account, key}),
    do:
      "no PostingAccount row maps `#{key}` for this org (fail-honest — accounts are a " <>
        "host decision; seed the org's posting accounts first)"

  defp format(reason), do: inspect(reason)

  defp org_id(changeset) do
    case Ash.Changeset.get_attribute(changeset, :org_id) do
      %Ash.NotLoaded{} -> Ash.load!(changeset.data, [:org_id], authorize?: false).org_id
      nil -> Ash.load!(changeset.data, [:org_id], authorize?: false).org_id
      value -> value
    end
  end

  defp add_error(changeset, message) do
    Ash.Changeset.add_error(changeset, field: :base, message: message)
  end
end
