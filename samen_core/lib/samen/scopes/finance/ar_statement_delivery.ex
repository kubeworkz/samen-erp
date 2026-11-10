defmodule Samen.Scopes.Finance.ArStatementDelivery do
  @moduledoc """
  Deliver a customer's AR statement through the single delivery chokepoint.

  The statement itself stays the kernel read (`Samen.Scopes.Finance.ArAging`);
  this service only freezes that read into a `StatementDelivery` audit row and
  hands a token-only `%Samen.Delivery.Message{}` to
  `Samen.Delivery.Chokepoint.send/2`. The recipient email is never read or
  stored here — the chokepoint resolves the customer at delivery time.

  The send attempt is recorded even when delivery is blocked, suppressed or
  fails, so the audit trail cannot claim a statement was sent when the provider
  refused it. A `LocalSink` receipt is `:captured`, never `:sent`.
  """

  alias Samen.Delivery.Chokepoint
  alias Samen.Delivery.Lifecycle.EmailWorker
  alias Samen.Delivery.Message
  alias Samen.Scopes.Finance.ArAging

  @template_id "ar_statement"

  @doc """
  Deliver one currency group of `customer_id`'s statement.

  Required options: `:statement_delivery` (the mounted resource), `:invoice`,
  `:receipt`, `:org_id`, `:scope`, `:customer_id` and `:as_of`. Optional:
  `:receipt_allocation`, `:credit_note`, `:currency` (required when the
  statement has more than one currency), `:template_id`, and `:delivery_opts`
  (threaded to `Chokepoint.send/2`).

  Returns `{:ok, delivery}` after a captured/sent attempt, or `{:error,
  reason}`. A failed attempt still leaves an audit row with its honest status.
  """
  @spec deliver(keyword()) :: {:ok, struct()} | {:error, term()}
  def deliver(opts) do
    delivery_resource = Keyword.fetch!(opts, :statement_delivery)

    with {:ok, statement} <- load_statement(opts),
         {:ok, currency, totals} <- pick_currency(statement, Keyword.get(opts, :currency)),
         send_id = Ecto.UUID.generate(),
         message = message(opts, send_id),
         send_opts = send_opts(opts, statement, currency, totals),
         result = Chokepoint.send(message, send_opts) do
      case result do
        {:ok, receipt} ->
          attrs = delivery_attrs(opts, statement, currency, totals, send_id, receipt, nil)

          case record(delivery_resource, attrs, opts[:scope]) do
            {:ok, delivery} -> {:ok, delivery}
            {:error, reason} -> {:error, {:audit_failed, reason}}
          end

        {:error, reason} ->
          attrs = delivery_attrs(opts, statement, currency, totals, send_id, nil, reason)
          _ = record(delivery_resource, attrs, opts[:scope])
          {:error, reason}
      end
    end
  end

  defp load_statement(opts) do
    ArAging.statement_for_customer(
      invoice: Keyword.fetch!(opts, :invoice),
      receipt: Keyword.fetch!(opts, :receipt),
      receipt_allocation: Keyword.get(opts, :receipt_allocation),
      credit_note: Keyword.get(opts, :credit_note),
      org_id: Keyword.fetch!(opts, :org_id),
      scope: Keyword.fetch!(opts, :scope),
      customer_id: Keyword.fetch!(opts, :customer_id),
      as_of: Keyword.fetch!(opts, :as_of)
    )
  end

  defp pick_currency(%{currencies: []}, _requested), do: {:error, :nothing_to_deliver}

  defp pick_currency(%{currencies: [currency], by_currency: by_currency}, nil) do
    {:ok, currency, by_currency[currency]}
  end

  defp pick_currency(%{currencies: [_ | _]}, nil), do: {:error, :currency_required}

  defp pick_currency(%{currencies: currencies} = statement, requested) do
    currency = requested |> to_string() |> String.trim() |> String.upcase()

    if currency in currencies do
      {:ok, currency, statement.by_currency[currency]}
    else
      {:error, :unknown_currency}
    end
  end

  defp message(opts, send_id) do
    %Message{
      send_id: send_id,
      org_id: Keyword.fetch!(opts, :org_id),
      to_subscriber_id: Keyword.fetch!(opts, :customer_id),
      template_id: Keyword.get(opts, :template_id, @template_id)
    }
  end

  defp send_opts(opts, statement, currency, totals) do
    delivery_opts = Keyword.get(opts, :delivery_opts, [])

    delivery_opts
    |> Keyword.put_new(:fallback_adapter, EmailWorker.resolve_adapter())
    |> Keyword.put_new(:fallback_config, EmailWorker.adapter_config() || %{})
    |> Keyword.put_new(:env, EmailWorker.env())
    |> Keyword.put(
      :fallback_config,
      base_config(delivery_opts)
      |> Map.merge(rendered_content(statement, currency, totals))
    )
  end

  defp base_config(delivery_opts) do
    delivery_opts
    |> Keyword.get(:fallback_config, %{})
    |> case do
      config when is_map(config) -> config
      _other -> %{}
    end
  end

  defp rendered_content(statement, currency, totals) do
    subject = "Statement of account #{currency} as of #{Date.to_iso8601(statement.as_of)}"

    text_body = """
    Statement of account — #{currency}
    As of #{Date.to_iso8601(statement.as_of)}

    Invoiced: #{money(totals.invoiced_cents)}
    Paid: #{money(totals.paid_cents)}
    Credited: #{money(totals.credited_cents)}
    Outstanding: #{money(totals.outstanding_cents)}
    Unapplied cash: #{money(totals.unapplied_cents)}
    """

    html_body =
      "<p><strong>Statement of account — #{currency}</strong><br/>" <>
        "As of #{Date.to_iso8601(statement.as_of)}</p>" <>
        "<p>Invoiced: #{money(totals.invoiced_cents)}<br/>" <>
        "Paid: #{money(totals.paid_cents)}<br/>" <>
        "Credited: #{money(totals.credited_cents)}<br/>" <>
        "Outstanding: #{money(totals.outstanding_cents)}<br/>" <>
        "Unapplied cash: #{money(totals.unapplied_cents)}</p>"

    %{subject: subject, text_body: text_body, html_body: html_body}
  end

  defp delivery_attrs(opts, statement, currency, totals, send_id, receipt, error) do
    invoices =
      Enum.filter(statement.invoices, fn invoice -> invoice.currency == currency end)

    status =
      case {receipt, error} do
        {%{} = receipt, _} -> if Map.get(receipt, :sink, false), do: :captured, else: :sent
        {_, :adapter_unconfigured} -> :blocked
        {_, :suppressed} -> :suppressed
        {_, _} -> :failed
      end

    %{
      org_id: Keyword.fetch!(opts, :org_id),
      customer_id: Keyword.fetch!(opts, :customer_id),
      send_id: send_id,
      template_id: Keyword.get(opts, :template_id, @template_id),
      as_of: statement.as_of,
      currency: currency,
      status: status,
      invoiced_cents: totals.invoiced_cents,
      paid_cents: totals.paid_cents,
      credited_cents: totals.credited_cents,
      outstanding_cents: totals.outstanding_cents,
      unapplied_cents: totals.unapplied_cents,
      invoice_count: length(invoices),
      invoice_ids: Enum.map(invoices, & &1.invoice_id),
      provider_message_id: receipt && provider_message_id(receipt),
      delivered_at: receipt && DateTime.utc_now(),
      error: error_text(error)
    }
  end

  defp record(resource, attrs, scope) do
    resource
    |> Ash.Changeset.for_create(:record, attrs, scope: scope)
    |> Ash.create()
  end

  defp provider_message_id(receipt) do
    Map.get(receipt, :provider_message_id) || Map.get(receipt, "provider_message_id")
  end

  defp error_text(nil), do: nil
  defp error_text(reason), do: reason |> inspect() |> String.slice(0, 500)

  defp money(cents) when is_integer(cents) do
    sign = if cents < 0, do: "-", else: ""
    cents = abs(cents)

    "#{sign}$#{div(cents, 100)}.#{cents |> rem(100) |> Integer.to_string() |> String.pad_leading(2, "0")}"
  end

  defp money(_cents), do: "$0.00"
end
