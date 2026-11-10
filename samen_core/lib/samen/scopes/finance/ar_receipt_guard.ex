defmodule Samen.Scopes.Finance.ArReceiptGuard do
  @moduledoc """
  The AR cash-intake guard.

  A `PaymentReceipt` is either:

    * **invoice-bound** — it names a Billing invoice. The guard reads that
      invoice, requires the same org, an `:open`/`:paid` status, and derives the
      receipt's `customer_id` and `currency` from it. A caller-supplied
      customer/currency that disagrees is refused; receipts never silently
      settle a foreign-currency invoice.
    * **on-account** — it names no invoice. It must name the customer and an
      explicit ISO-4217 currency; there is no USD default to hide behind.

  `invoice_key` is normalized to `"billing_invoice"` for invoice-bound rows and
  `nil` for on-account rows. The subscription ledger's posted entry is still
  the cash fact; this guard only makes the anchor honest.
  """

  use Ash.Resource.Change

  require Ash.Query

  @invoice_key "billing_invoice"
  @currency_regex ~r/^[A-Z]{3}$/

  @impl true
  def change(changeset, opts, _context) do
    invoice_mod = Keyword.get(opts, :invoice)
    Ash.Changeset.before_action(changeset, &validate(&1, invoice_mod))
  end

  defp validate(changeset, invoice_mod) do
    org_id = org_id(changeset)
    invoice_id = Ash.Changeset.get_attribute(changeset, :invoice_id)
    invoice_key = Ash.Changeset.get_attribute(changeset, :invoice_key)
    customer_id = Ash.Changeset.get_attribute(changeset, :customer_id)
    currency = normalize_currency(Ash.Changeset.get_attribute(changeset, :currency))

    if is_nil(invoice_id) do
      validate_on_account(changeset, customer_id, invoice_key, currency)
    else
      validate_invoice(
        changeset,
        invoice_mod,
        org_id,
        invoice_id,
        invoice_key,
        customer_id,
        currency
      )
    end
  end

  defp validate_on_account(changeset, customer_id, invoice_key, currency) do
    cond do
      not is_binary(customer_id) or String.trim(customer_id) == "" ->
        error(changeset, :customer_id, "an on-account receipt requires the customer")

      is_nil(currency) ->
        error(changeset, :currency, "an on-account receipt requires its currency")

      not Regex.match?(@currency_regex, currency) ->
        error(changeset, :currency, "currency must be a three-letter ISO 4217 code")

      invoice_key not in [nil, ""] ->
        error(changeset, :invoice_key, "an on-account receipt carries no invoice key")

      true ->
        changeset
        |> Ash.Changeset.force_change_attribute(:customer_id, String.trim(customer_id))
        |> Ash.Changeset.force_change_attribute(:currency, currency)
        |> Ash.Changeset.force_change_attribute(:invoice_key, nil)
        |> Ash.Changeset.force_change_attribute(:invoice_id, nil)
    end
  end

  defp validate_invoice(
         changeset,
         nil,
         _org_id,
         _invoice_id,
         _invoice_key,
         _customer_id,
         _currency
       ) do
    error(changeset, :invoice_id, "this workspace has not mounted Billing invoices")
  end

  defp validate_invoice(
         changeset,
         invoice_mod,
         org_id,
         invoice_id,
         invoice_key,
         customer_id,
         currency
       ) do
    case invoice_mod
         |> Ash.Query.filter(id == ^invoice_id and org_id == ^org_id)
         |> Ash.read_one(authorize?: false) do
      {:ok, nil} ->
        error(changeset, :invoice_id, "the invoice could not be found in this org")

      {:ok, invoice} ->
        invoice_customer = Map.get(invoice, :customer_id)
        invoice_status = Map.get(invoice, :status)
        invoice_currency = normalize_currency(Map.get(invoice, :currency)) || "USD"

        cond do
          invoice_status not in [:open, :paid] ->
            error(
              changeset,
              :invoice_id,
              "that invoice is #{inspect(invoice_status)} — receipts settle open or paid invoices"
            )

          present?(customer_id) and String.trim(customer_id) != to_string(invoice_customer) ->
            error(changeset, :customer_id, "the customer does not match the invoice")

          not is_nil(currency) and currency != invoice_currency ->
            error(
              changeset,
              :currency,
              "receipt currency #{currency} does not match the invoice currency #{invoice_currency}"
            )

          invoice_key not in [nil, "", @invoice_key] ->
            error(changeset, :invoice_key, "invoice_key must be #{inspect(@invoice_key)}")

          true ->
            changeset
            |> Ash.Changeset.force_change_attribute(:customer_id, invoice_customer)
            |> Ash.Changeset.force_change_attribute(:currency, invoice_currency)
            |> Ash.Changeset.force_change_attribute(:invoice_key, @invoice_key)
        end

      {:error, _reason} ->
        error(changeset, :invoice_id, "the invoice could not be read in this org")
    end
  end

  defp org_id(changeset) do
    case Map.get(changeset.attributes, :org_id) do
      nil -> Ash.Changeset.get_attribute(changeset, :org_id)
      value -> value
    end
  end

  defp normalize_currency(nil), do: nil

  defp normalize_currency(value) when is_binary(value) do
    case value |> String.trim() |> String.upcase() do
      "" -> nil
      currency -> currency
    end
  end

  defp normalize_currency(value), do: value |> to_string() |> normalize_currency()

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp error(changeset, field, message) do
    Ash.Changeset.add_error(changeset, field: field, message: message)
  end
end
