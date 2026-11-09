defmodule Samen.Scopes.Finance.ReverseApPayment do
  @moduledoc """
  The system side of a run reversal: void one paid bill's `ap_payment` entry and
  return the bill to `:approved`.

  Runs in `ApInvoice.:reverse_payment`, a SYSTEM-ONLY action reached by
  `Samen.Scopes.Finance.ApPaymentReversal.approve/1` after its distinct-admin
  decision. The change:

    1. locks the persisted bill row and requires `:paid`;
    2. finds the one still-POSTED journal entry anchored
       `source_key: "ap_payment"`, `source_id: <bill id>`;
    3. calls the entry's `:void` with NO actor. That is the ledger's ordinary
       reversal path: it posts a mirrored entry and links both directions. With
       no actor, `JournalApproval` treats it as a system cascade (the same
       posture as `ApPaymentPosting`'s posted-born create);
    4. forces the bill back to `:approved`.

  `PostingMarker` on the outer action arms the DB belt for the status write.
  The bill's approval entry (`posted_entry_id`) is untouched; the payment entry
  is voided, not erased, so the ledger history remains complete.
  """

  use Ash.Resource.Change

  require Ash.Query

  @impl true
  def change(changeset, opts, _context) do
    entry_resource = Keyword.fetch!(opts, :entry)

    Ash.Changeset.before_action(changeset, fn changeset ->
      do_reverse(changeset, entry_resource)
    end)
  end

  defp do_reverse(changeset, entry_resource) do
    bill = changeset.data
    repo = AshPostgres.DataLayer.Info.repo(changeset.resource, :mutate)

    with :ok <- lock_paid(changeset, repo),
         {:ok, org_id} <- org_id(bill),
         {:ok, entry} <- payment_entry(entry_resource, org_id, bill.id),
         {:ok, _voided} <- void_entry(entry) do
      Ash.Changeset.force_change_attribute(changeset, :status, :approved)
    else
      {:error, reason} ->
        Ash.Changeset.add_error(changeset, field: :base, message: format(reason))
    end
  end

  defp org_id(%{org_id: org_id}) when is_binary(org_id), do: {:ok, org_id}

  defp org_id(bill) do
    case Ash.load(bill, [:org_id], authorize?: false) do
      {:ok, loaded} -> {:ok, loaded.org_id}
      {:error, reason} -> {:error, {:org_read_failed, reason}}
    end
  end

  defp payment_entry(entry_resource, org_id, bill_id) do
    entry_resource
    |> Ash.Query.filter(
      org_id == ^org_id and source_key == "ap_payment" and source_id == ^bill_id and
        status == :posted
    )
    |> Ash.read(authorize?: false)
    |> case do
      {:ok, [entry]} -> {:ok, entry}
      {:ok, []} -> {:error, :payment_entry_missing}
      {:ok, _multiple} -> {:error, :payment_entry_ambiguous}
      {:error, reason} -> {:error, {:payment_entry_read_failed, reason}}
    end
  end

  defp void_entry(entry) do
    entry
    |> Ash.Changeset.for_update(:void, %{})
    |> Ash.update(authorize?: false)
  end

  defp lock_paid(changeset, repo) do
    resource = changeset.resource
    table = AshPostgres.DataLayer.Info.table(resource)
    id_col = attr_source(resource, :id)
    status_col = attr_source(resource, :status)

    case repo.query(
           "SELECT #{status_col} FROM #{table} WHERE #{id_col} = $1 FOR UPDATE",
           [dump_uuid(changeset.data.id)]
         ) do
      {:ok, %{rows: [[status]]}} ->
        case to_string(status) do
          "paid" -> :ok
          other -> {:error, {:not_paid, other}}
        end

      {:ok, %{rows: []}} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, {:lock_failed, reason}}
    end
  end

  defp attr_source(resource, name) do
    case Ash.Resource.Info.attribute(resource, name) do
      nil -> raise ArgumentError, "#{inspect(resource)} has no #{inspect(name)} attribute"
      attr -> to_string(attr.source || attr.name)
    end
  end

  defp dump_uuid(value) when is_binary(value) and byte_size(value) == 16, do: value

  defp dump_uuid(value) do
    case Ecto.UUID.dump(value) do
      {:ok, bin} -> bin
      :error -> value
    end
  end

  defp format({:not_paid, status}),
    do: "the bill is #{status} — only a :paid bill can have its payment reversed"

  defp format(:not_found), do: "the bill no longer exists"
  defp format(:payment_entry_missing), do: "the bill's posted AP payment entry is missing"
  defp format(:payment_entry_ambiguous), do: "the bill has more than one posted AP payment entry"

  defp format({:payment_entry_read_failed, reason}),
    do: "the payment entry could not be read: #{inspect(reason)}"

  defp format({:lock_failed, reason}), do: "the bill could not be locked: #{inspect(reason)}"

  defp format({:org_read_failed, reason}),
    do: "the bill's org could not be read: #{inspect(reason)}"

  defp format(reason), do: "the payment could not be reversed: #{inspect(reason)}"
end
