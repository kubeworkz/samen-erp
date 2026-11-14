defmodule Samen.Scopes.Finance.AssetEntry do
  @moduledoc """
  Shared ledger plumbing for asset lifecycle entries (WS-ACCT Phase 8;
  ADR-054 D9): resolve a named `PostingAccount` fail-honest, then create and
  post a journal entry through the ordinary governed `:post` door.

  Disposal and CIP-in-service both need the same shape. Keeping it here means
  neither cascade invents a second posting path: R1 (`PostBalance`), R6
  (`DimensionBalance`) and R10 (`PeriodGuard`) run exactly as they do for a
  depreciation slice or a human entry.
  """

  require Ash.Query

  @doc """
  Resolve one posting meaning for `org_id`, pinned to the org.

  Returns `{:ok, row}` or `{:error, {:unmapped_posting_account, key}}` — never a
  default account.
  """
  def posting_account(pa_mod, org_id, key) do
    case pa_mod
         |> Ash.Query.filter(org_id == ^org_id and key == ^key)
         |> Ash.read_one(authorize?: false) do
      {:ok, nil} -> {:error, {:unmapped_posting_account, key}}
      {:ok, row} -> {:ok, row}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Create a draft and post it in the same transaction.

  The draft-first shape is deliberate: `EntryLines` materializes the lines
  while the entry is a draft, then the ordinary `:post` action applies the
  posting guards.
  """
  def post(entry_mod, attrs) do
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

  @doc "The asset's dimension or an empty map when it is undimensioned."
  def dimension_refs(%{cost_object_id: nil}), do: %{}

  def dimension_refs(%{cost_object_id: cost_object_id, dimension_key: key}),
    do: %{to_string(key) => cost_object_id}
end
