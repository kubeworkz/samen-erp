defmodule Samenerp.Kubeworkz.ArDemo do
  @moduledoc """
  Seeds the demo org's AR collections context.

  One Kubeworkz customer, one overdue open CAD invoice, and one OPEN collection
  case give the AR aging page a real ledger row and the collections panel a case
  to act on. The case is opened through `Samen.Scopes.Finance.ArCollections`,
  then advanced through the org's scheduled dunning cadence by the real
  `Samen.Scopes.Finance.CollectionDunning` sweep, so its timeline shows the full
  reminder → notice → final notice → collections ladder. The recorded events
  are dated at the cadence's historical intervals, not all at seed time.

  This is demo data, not a deploy side effect. It is opt-in from the
  `mix kubeworkz.books` task (`--ar-demo`) and is idempotent: a re-run reuses
  the customer, invoice, and active case it finds and advances only a case that
  is still short of the final collections stage.
  """

  require Ash.Query

  alias Samen.Scopes.Finance.{ArCollections, CollectionDunning}
  alias Samenerp.Billing.{Customer, Invoice}
  alias Samenerp.Erp

  @customer_ref "kubeworkz-ar-demo"
  @invoice_ref "kubeworkz-ar-demo-001"
  @currency "CAD"
  @amount_cents 1_875_000
  @due_days_ago 45
  @case_opened_days_ago 28
  @initial_next_action_days_ago 21
  @event_time ~T[09:00:00]

  @doc """
  Seed the demo AR context for `org_id`. Idempotent; creates only what is
  missing and advances a still-open case to the collections stage.

  Returns the customer, invoice, collection case, and per-record `created`
  flags so the task can report what happened.
  """
  @spec seed!(String.t()) :: map()
  def seed!(org_id) do
    org_id = to_string(org_id)
    scope = admin_scope(org_id)
    today = Date.utc_today()

    {customer, customer_created?} = find_or_create_customer(org_id, scope)
    {invoice, invoice_created?} = find_or_create_invoice(org_id, customer, scope, today)

    {collection_case, collection_case_created?} =
      find_or_open_case(org_id, customer, scope, today)

    collection_case = advance_collection_case!(org_id, collection_case)

    %{
      org_id: org_id,
      customer: customer,
      customer_created: customer_created?,
      invoice: invoice,
      invoice_created: invoice_created?,
      collection_case: collection_case,
      collection_case_created: collection_case_created?,
      collection_case_stage: collection_case.stage,
      collection_case_events: length(timeline_events(collection_case))
    }
  end

  defp find_or_create_customer(org_id, scope) do
    query =
      Customer
      |> Ash.Query.filter(org_id == ^org_id and provider_customer_ref == ^@customer_ref)

    case Ash.read_one!(query, scope: scope) do
      nil ->
        customer =
          Customer
          |> Ash.Changeset.for_create(
            :create,
            %{
              org_id: org_id,
              provider_customer_ref: @customer_ref,
              currency: @currency
            },
            scope: scope
          )
          |> Ash.create!(scope: scope)

        {customer, true}

      customer ->
        {customer, false}
    end
  end

  defp find_or_create_invoice(org_id, customer, scope, today) do
    query =
      Invoice
      |> Ash.Query.filter(org_id == ^org_id and provider_invoice_ref == ^@invoice_ref)

    case Ash.read_one!(query, scope: scope) do
      nil ->
        due_date =
          DateTime.new!(Date.add(today, -@due_days_ago), ~T[00:00:00], "Etc/UTC")

        invoice =
          Invoice
          |> Ash.Changeset.for_create(
            :create,
            %{
              org_id: org_id,
              customer_id: customer.id,
              provider_invoice_ref: @invoice_ref,
              status: :open,
              amount_due_cents: @amount_cents,
              amount_paid_cents: 0,
              currency: @currency,
              period_start: DateTime.add(due_date, -30, :day),
              period_end: due_date,
              due_date: due_date,
              line_items: []
            },
            scope: scope
          )
          |> Ash.create!(scope: scope)

        {invoice, true}

      invoice ->
        {invoice, false}
    end
  end

  defp find_or_open_case(org_id, customer, scope, today) do
    query =
      Erp.CollectionCase
      |> Ash.Query.filter(
        org_id == ^org_id and customer_id == ^customer.id and currency == @currency and
          status != :resolved
      )

    case Ash.read_one!(query, scope: scope) do
      nil ->
        opened_on = Date.add(today, -@case_opened_days_ago)
        next_action_on = Date.add(today, -@initial_next_action_days_ago)

        case ArCollections.open_case(
               collection_case: Erp.CollectionCase,
               invoice: Invoice,
               receipt: Erp.PaymentReceipt,
               receipt_allocation: Erp.ReceiptAllocation,
               credit_note: Erp.CreditNote,
               org_id: org_id,
               scope: scope,
               customer_id: customer.id,
               currency: @currency,
               as_of: today,
               opened_on: opened_on,
               opened_at: event_time(opened_on),
               next_action_on: next_action_on,
               notes: "Demo case: follow up on the overdue Kubeworkz AR invoice."
             ) do
          {:ok, collection_case} ->
            {collection_case, true}

          {:error, reason} ->
            raise "could not open the demo collection case for #{org_id}: #{inspect(reason)}"
        end

      collection_case ->
        {collection_case, false}
    end
  end

  defp advance_collection_case!(_org_id, %{stage: :collections} = collection_case) do
    collection_case
  end

  defp advance_collection_case!(org_id, collection_case) do
    due_on = collection_case.next_action_on || Date.utc_today()

    case CollectionDunning.run(
           collection_case: Erp.CollectionCase,
           collection_cadence: Erp.CollectionCadence,
           case_id: collection_case.id,
           today: due_on,
           at: event_time(due_on)
         ) do
      {:ok, %{recorded: [%{stage: stage}]}} ->
        updated = collection_case!(org_id, collection_case.id)

        if updated.stage == stage do
          advance_collection_case!(org_id, updated)
        else
          raise "the demo collection case did not advance from #{collection_case.stage}"
        end

      {:ok, %{recorded: [], skipped: [%{reason: :no_enabled_stage}]}} ->
        collection_case

      {:ok, summary} ->
        raise "the demo collection case was not due for dunning: #{inspect(summary)}"

      {:error, reason} ->
        raise "could not advance the demo collection case for #{org_id}: #{inspect(reason)}"
    end
  end

  defp collection_case!(org_id, case_id) do
    Erp.CollectionCase
    |> Ash.Query.filter(org_id == ^org_id and id == ^case_id)
    |> Ash.read_one!(scope: admin_scope(org_id))
  end

  defp timeline_events(%{actions: %{"events" => events}}) when is_list(events), do: events
  defp timeline_events(_collection_case), do: []

  defp event_time(%Date{} = date), do: DateTime.new!(date, @event_time, "Etc/UTC")

  defp admin_scope(org_id) do
    %Samen.Scope{
      actor: %{
        id: "seed:ar-demo:#{org_id}",
        org_id: org_id,
        role: :admin,
        kind: :tenant,
        plane: :tenant
      }
    }
  end
end
