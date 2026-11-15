defmodule Samen.Scopes.Finance.LeaseInitialPosting do
  @moduledoc """
  The lease commencement cascade: on `:create`, post
  `Dr ROU asset / Cr lease liability` at the derived present value, in the
  SAME transaction as the lease row.

  The entry is anchored `source_key: "lease_initial"`, `source_id: <lease id>`.
  The lease id is minted before the entry, so the anchor names a row that
  inserts with that same id. The entry is drafted first, then posted through
  the ordinary governed `:post` action so R1, R6 and R10 run exactly as they do
  for a human entry.

  The amount is never caller-supplied: it is re-derived from the lease
  contract by `Samen.Scopes.Finance.LeaseSchedule`.
  """

  use Ash.Resource.Change

  alias Samen.Scopes.Finance.LeaseSchedule

  @source_key "lease_initial"

  @doc "The object-ref anchor every commencement entry carries."
  def source_key, do: @source_key

  @impl true
  def change(changeset, opts, _context) do
    entry_mod = Keyword.fetch!(opts, :entry)

    org_id = Ash.Changeset.get_attribute(changeset, :org_id)

    Ash.Changeset.before_action(changeset, fn changeset ->
      post(changeset, org_id, entry_mod)
    end)
  end

  defp post(changeset, org_id, entry_mod) do
    lease = lease_attrs(changeset, org_id)
    amount = LeaseSchedule.initial_liability(lease)

    with true <- amount > 0,
         id <- Ash.UUID.generate(),
         {:ok, entry} <- create_entry(entry_mod, org_id, id, lease, amount) do
      changeset
      |> Ash.Changeset.force_change_attribute(:id, id)
      |> Ash.Changeset.force_change_attribute(:initial_entry_id, entry.id)
    else
      false ->
        Ash.Changeset.add_error(changeset,
          field: :payment_cents,
          message: "the lease present value must be positive"
        )

      {:error, reason} ->
        Ash.Changeset.add_error(changeset,
          field: :base,
          message: "the lease commencement cannot be posted: #{inspect(reason)}"
        )
    end
  end

  defp lease_attrs(changeset, org_id) do
    %{
      org_id: org_id,
      code: Ash.Changeset.get_attribute(changeset, :code),
      start_on: Ash.Changeset.get_attribute(changeset, :start_on),
      months: Ash.Changeset.get_attribute(changeset, :months),
      payment_cents: Ash.Changeset.get_attribute(changeset, :payment_cents),
      annual_rate_bps: Ash.Changeset.get_attribute(changeset, :annual_rate_bps) || 0,
      rou_asset_account_id: Ash.Changeset.get_attribute(changeset, :rou_asset_account_id),
      lease_liability_account_id:
        Ash.Changeset.get_attribute(changeset, :lease_liability_account_id),
      dimension_key: Ash.Changeset.get_attribute(changeset, :dimension_key) || :project,
      cost_object_id: Ash.Changeset.get_attribute(changeset, :cost_object_id)
    }
  end

  defp create_entry(entry_mod, org_id, id, lease, amount) do
    with {:ok, draft} <-
           entry_mod
           |> Ash.Changeset.for_create(
             :create,
             %{
               org_id: org_id,
               entry_date: lease.start_on,
               memo: "Lease commencement #{lease.code}",
               source_key: @source_key,
               source_id: id,
               lines: [
                 %{
                   account_id: lease.rou_asset_account_id,
                   debit_cents: amount,
                   dimension_refs: dimension_refs(lease)
                 },
                 %{
                   account_id: lease.lease_liability_account_id,
                   credit_cents: amount,
                   dimension_refs: dimension_refs(lease)
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
end
