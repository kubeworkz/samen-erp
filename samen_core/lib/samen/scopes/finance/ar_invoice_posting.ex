defmodule Samen.Scopes.Finance.ArInvoicePosting do
  @moduledoc """
  The AR invoice posting cascade (B0; ADR-054 amendment): on a local
  invoice's `:issue`, land the receivable/revenue entry in the org's
  functional currency.

  The entry is anchored `source_key: "billing_invoice"` / `source_id:
  <invoice id>` and is built **inside `before_action`**, after the caller's
  `PostingMarker` has armed the posting belt. It is created through the
  JournalEntry `:create_reversal` factory, so the ordinary PeriodGuard,
  PostGuard and R1 checks apply.

  A `RevenueSchedule` anchored to the same invoice switches the credit from
  `:income` to the schedule's `deferred_key`; its total must equal the
  invoice's pre-tax amount. No schedule means the point-in-time income path.

  This service deliberately does not convert currency: an invoice whose
  currency differs from the org's functional currency refuses before any
  entry. It also refuses provider-mirror invoices, paid-at-issue invoices,
  non-positive amounts, an existing anchor, and unmapped accounts.
  """

  use Ash.Resource.Change

  require Ash.Query

  alias Samen.Scopes.Finance.ApFx

  @source_key "billing_invoice"

  @doc "The AR invoice journal-anchor source key."
  def source_key, do: @source_key

  @impl true
  def change(changeset, opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      case post(changeset.data, opts) do
        {:ok, _entry} ->
          changeset

        {:error, reason} ->
          Ash.Changeset.add_error(changeset,
            field: :base,
            message: "the invoice cannot be issued: #{format(reason)}"
          )
      end
    end)
  end

  @doc """
  Post the invoice's AR/revenue entry.

  Expected options are the host modules: `:entry`, `:posting_account`,
  `:revenue_schedule` (nil when the host has no schedule module) and
  `:org_fx_settings` (nil means the USD default). The caller must already be
  inside a transaction whose posting marker is armed — the `:issue` action
  does this with `Samen.Scopes.Finance.PostingMarker` before this change.

  `:allow_paid` defaults to `false`. The legacy backfill passes `true` because
  a historical invoice's `amount_paid_cents` is a later settlement fact, not an
  issue-time input; a normal `:issue` never bypasses the paid-at-issue guard.
  """
  def post(invoice, opts) do
    with {:ok, plan} <- plan(invoice, opts) do
      create_entry(
        plan.entry_resource,
        plan.org_id,
        invoice,
        plan.amount,
        plan.ar_account_id,
        plan.credit_account_id
      )
    end
  end

  @doc """
  Validate a posting without writing one.

  This is the same read-only preflight used by `post/2`; the backfill calls it
  during a dry run so a currency, schedule or account refusal is reported as a
  skip instead of appearing postable. `allow_paid: true` is accepted here for
  the same legacy-invoice reason as `post/2`.
  """
  def preflight(invoice, opts) do
    case plan(invoice, opts) do
      {:ok, _plan} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp plan(invoice, opts) do
    entry_resource = Keyword.fetch!(opts, :entry)
    posting_account_resource = Keyword.fetch!(opts, :posting_account)
    revenue_schedule = Keyword.get(opts, :revenue_schedule)
    org_fx_settings = Keyword.get(opts, :org_fx_settings)
    allow_paid = Keyword.get(opts, :allow_paid, false)

    with {:ok, org_id} <- invoice_org_id(invoice),
         :ok <- refuse_provider_invoice(invoice),
         :ok <- refuse_existing_anchor(entry_resource, org_id, invoice),
         :ok <- refuse_amounts(invoice, allow_paid),
         {:ok, _currency, _base_currency} <-
           functional_currency(invoice, org_id, org_fx_settings),
         {:ok, credit_key} <- credit_key(revenue_schedule, org_id, invoice),
         {:ok, ar} <- posting_account(posting_account_resource, org_id, :ar_clearing),
         {:ok, credit} <- posting_account(posting_account_resource, org_id, credit_key) do
      {:ok,
       %{
         entry_resource: entry_resource,
         org_id: org_id,
         amount: invoice.amount_due_cents,
         ar_account_id: ar.account_id,
         credit_account_id: credit.account_id
       }}
    end
  end

  defp create_entry(entry_resource, org_id, invoice, amount, ar_account_id, credit_account_id) do
    attrs = %{
      org_id: org_id,
      entry_date: Date.utc_today(),
      memo: "AR invoice #{invoice.id}",
      source_key: @source_key,
      source_id: invoice.id,
      lines: [
        %{account_id: ar_account_id, debit_cents: amount, credit_cents: 0},
        %{account_id: credit_account_id, debit_cents: 0, credit_cents: amount}
      ]
    }

    case entry_resource
         |> Ash.Changeset.for_create(:create_reversal, attrs, authorize?: false)
         |> Ash.create(authorize?: false) do
      {:ok, entry} -> {:ok, entry}
      {:error, reason} -> {:error, {:entry_create_failed, reason}}
    end
  end

  defp invoice_org_id(invoice) do
    case Map.get(invoice, :org_id) do
      value when is_binary(value) ->
        {:ok, value}

      %Ash.NotLoaded{} ->
        case Ash.load(invoice, [:org_id], authorize?: false) do
          {:ok, loaded} when is_binary(loaded.org_id) -> {:ok, loaded.org_id}
          other -> {:error, {:org_read_failed, other}}
        end

      other ->
        {:error, {:org_read_failed, other}}
    end
  end

  defp refuse_provider_invoice(invoice) do
    case provider_ref(invoice) do
      ref when is_binary(ref) ->
        if String.trim(ref) == "" do
          :ok
        else
          {:error, {:provider_invoice_not_local, ref}}
        end

      _ ->
        :ok
    end
  end

  defp refuse_existing_anchor(entry_resource, org_id, invoice) do
    case entry_resource
         |> Ash.Query.filter(
           org_id == ^org_id and source_key == @source_key and source_id == ^invoice.id
         )
         |> Ash.read_one(authorize?: false) do
      {:ok, nil} -> :ok
      {:ok, entry} -> {:error, {:already_posted, entry.id}}
      {:error, reason} -> {:error, {:anchor_read_failed, reason}}
    end
  end

  defp refuse_amounts(invoice, allow_paid) do
    amount = invoice.amount_due_cents
    paid = invoice.amount_paid_cents || 0

    cond do
      not is_integer(amount) or amount <= 0 ->
        {:error, {:non_positive_amount, amount}}

      paid != 0 and not allow_paid ->
        {:error, {:paid_at_issue, paid}}

      true ->
        :ok
    end
  end

  defp functional_currency(invoice, org_id, org_fx_settings) do
    base_currency = ApFx.base_currency(org_fx_settings, org_id)
    invoice_currency = ApFx.normalize_currency(invoice.currency)

    if is_binary(invoice_currency) and invoice_currency == base_currency do
      {:ok, invoice_currency, base_currency}
    else
      {:error, {:unsupported_invoice_currency, invoice.currency, base_currency}}
    end
  end

  defp credit_key(nil, _org_id, _invoice), do: {:ok, :income}

  defp credit_key(schedule_resource, org_id, invoice) do
    case schedule_resource
         |> Ash.Query.filter(
           org_id == ^org_id and source_key == @source_key and source_id == ^invoice.id
         )
         |> Ash.read(authorize?: false) do
      {:ok, []} ->
        {:ok, :income}

      {:ok, [schedule]} ->
        if schedule.total_cents == invoice.amount_due_cents do
          {:ok, schedule.deferred_key || :deferred_revenue}
        else
          {:error, {:schedule_total_mismatch, schedule.total_cents, invoice.amount_due_cents}}
        end

      {:ok, schedules} ->
        {:error, {:multiple_schedules, length(schedules)}}

      {:error, reason} ->
        {:error, {:schedule_read_failed, reason}}
    end
  end

  defp posting_account(pa_resource, org_id, key) do
    case pa_resource
         |> Ash.Query.filter(org_id == ^org_id and key == ^key)
         |> Ash.read_one(authorize?: false) do
      {:ok, nil} -> {:error, {:unmapped_posting_account, key}}
      {:ok, row} -> {:ok, row}
      {:error, reason} -> {:error, {:posting_account_read_failed, key, reason}}
    end
  end

  defp provider_ref(invoice) do
    resource = invoice.__struct__

    if Ash.Resource.Info.attribute(resource, :provider_invoice_ref) do
      case Map.get(invoice, :provider_invoice_ref) do
        %Ash.NotLoaded{} ->
          Ash.load!(invoice, [:provider_invoice_ref], authorize?: false).provider_invoice_ref

        value ->
          value
      end
    end
  end

  defp format({:org_read_failed, reason}),
    do: "the invoice org could not be read: #{inspect(reason)}"

  defp format({:provider_invoice_not_local, ref}),
    do:
      "provider_invoice_not_local: this is a provider-mirror invoice (#{inspect(ref)}) and " <>
        "was never posted by this ledger"

  defp format({:already_posted, entry_id}),
    do: "already_posted: an AR entry is already anchored to this invoice (#{inspect(entry_id)})"

  defp format({:anchor_read_failed, reason}),
    do: "the existing AR anchor could not be read: #{inspect(reason)}"

  defp format({:non_positive_amount, amount}),
    do: "non_positive_amount: the invoice amount is #{inspect(amount)}"

  defp format({:paid_at_issue, amount}),
    do: "paid_at_issue: amount_paid_cents is #{inspect(amount)}; an invoice is issued unpaid"

  defp format({:unsupported_invoice_currency, currency, base_currency}),
    do:
      "unsupported_invoice_currency: invoice currency #{inspect(currency)} is not the org " <>
        "functional currency #{inspect(base_currency)} (no conversion in B0)"

  defp format({:schedule_total_mismatch, schedule_total, invoice_total}),
    do:
      "schedule_total_mismatch: the revenue schedule totals #{inspect(schedule_total)} but " <>
        "the invoice's pre-tax amount is #{inspect(invoice_total)}"

  defp format({:multiple_schedules, count}),
    do: "multiple_schedules: found #{count} revenue schedules anchored to this invoice"

  defp format({:schedule_read_failed, reason}),
    do: "the revenue schedule read failed: #{inspect(reason)}"

  defp format({:unmapped_posting_account, key}),
    do:
      "unmapped_posting_account: no PostingAccount row maps #{inspect(key)} for this org " <>
        "(accounts are a host decision)"

  defp format({:posting_account_read_failed, key, reason}),
    do: "the posting account #{inspect(key)} could not be read: #{inspect(reason)}"

  defp format({:entry_create_failed, reason}),
    do: "the AR journal entry failed to land: #{inspect(reason)}"
end
