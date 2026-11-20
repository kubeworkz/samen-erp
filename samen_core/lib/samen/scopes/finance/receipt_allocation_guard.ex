defmodule Samen.Scopes.Finance.ReceiptAllocationGuard do
  @moduledoc """
  The direct `ReceiptAllocation` create guard.

  An allocation is only meaningful against a local AR invoice. A direct
  allocation create could otherwise bypass `ArReceiptApplication.apply_credit/1`
  and attach on-account cash to a provider-mirror invoice that this ledger never
  posted. This change reads the invoice by `{org_id, invoice_id}` before the
  row lands and refuses:

    * an unwired invoice resource (the host did not mount Billing invoices);
    * a missing or cross-org invoice (the query is org-pinned);
    * a provider-mirror invoice (`provider_invoice_ref` non-empty).

  A resource without `provider_invoice_ref` has no provider docs and passes.
  """

  use Ash.Resource.Change

  require Ash.Query

  @impl true
  def change(changeset, opts, _context) do
    invoice_mod = Keyword.get(opts, :invoice)

    Ash.Changeset.before_action(changeset, &validate(&1, invoice_mod))
  end

  defp validate(changeset, invoice_mod) do
    org_id = org_id(changeset)
    invoice_id = Ash.Changeset.get_attribute(changeset, :invoice_id)

    cond do
      is_nil(invoice_id) ->
        error(changeset, :invoice_id, "a receipt allocation requires the invoice")

      is_nil(invoice_mod) ->
        error(changeset, :invoice_id, "this workspace has not mounted Billing invoices")

      true ->
        read_invoice(changeset, invoice_mod, org_id, invoice_id)
    end
  end

  defp read_invoice(changeset, invoice_mod, org_id, invoice_id) do
    case invoice_mod
         |> Ash.Query.filter(id == ^invoice_id and org_id == ^org_id)
         |> Ash.read_one(authorize?: false) do
      {:ok, nil} ->
        error(changeset, :invoice_id, "the invoice could not be found in this org")

      {:ok, invoice} ->
        check_provider(changeset, invoice)

      {:error, _reason} ->
        error(changeset, :invoice_id, "the invoice could not be read in this org")
    end
  end

  defp check_provider(changeset, invoice) do
    case provider_invoice_ref(invoice) do
      ref when is_binary(ref) ->
        if String.trim(ref) == "" do
          changeset
        else
          error(
            changeset,
            :invoice_id,
            "provider_invoice_not_local: this is a provider-mirror invoice and cannot " <>
              "receive a local allocation"
          )
        end

      _ ->
        changeset
    end
  end

  defp provider_invoice_ref(invoice) do
    if Ash.Resource.Info.attribute(invoice.__struct__, :provider_invoice_ref) do
      case Map.get(invoice, :provider_invoice_ref) do
        %Ash.NotLoaded{} ->
          Ash.load!(invoice, [:provider_invoice_ref], authorize?: false).provider_invoice_ref

        value ->
          value
      end
    end
  end

  defp org_id(changeset) do
    case Map.get(changeset.attributes, :org_id) do
      nil -> Ash.Changeset.get_attribute(changeset, :org_id)
      value -> value
    end
  end

  defp error(changeset, field, message) do
    Ash.Changeset.add_error(changeset, field: field, message: message)
  end
end
