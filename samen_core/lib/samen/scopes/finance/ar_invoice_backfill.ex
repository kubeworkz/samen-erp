defmodule Samen.Scopes.Finance.ArInvoiceBackfill do
  @moduledoc """
  The legacy AR invoice backfill (B0): post the missing receivable/revenue
  entry for local invoices that were issued before the invoice-to-GL bridge
  existed.

  This is deliberately **opt-in and read-first**. `run/1` defaults to a dry
  run; an operator reviews `would_post` and `skipped`, then reruns with
  `dry_run: false`. It only considers local `:open` and `:paid` invoices:
  provider-mirror rows were never posted by this ledger, and draft/void rows
  are not issuance events. An invoice with an existing `billing_invoice`
  anchor is reported as `:already_posted` and left untouched.

  ## What a run writes

  Nothing in dry-run mode. In apply mode, each postable invoice gets exactly
  one `Samen.Scopes.Finance.ArInvoicePosting` entry, anchored
  `source_key: "billing_invoice"` / `source_id: <invoice id>`, inside its own
  transaction with the `PostingMarker` armed and restored. There is no invoice
  table column to stamp: the journal anchor is the exactly-once link, and the
  database's partial unique index is the belt under it.

  A posting refusal (wrong functional currency, a schedule total mismatch,
  an unmapped account, a closed period, or a racing duplicate) is reported as
  a skip with the original reason; it is never silently counted as posted.

  The run does not choose an org, a currency or an account for the host.
  `:org_id` is required, and the host must pass the same Finance modules it
  mounts on Billing.

  ## Example

      {:ok, preview} =
        Samen.Scopes.Finance.ArInvoiceBackfill.run(
          repo: MyApp.Repo,
          org_id: org_id,
          invoice: MyApp.Billing.Invoice,
          entry: MyApp.Finance.JournalEntry,
          posting_account: MyApp.Finance.PostingAccount,
          revenue_schedule: MyApp.Finance.RevenueSchedule,
          org_fx_settings: MyApp.Finance.OrgFxSettings
        )

      # review preview.would_post and preview.skipped
      {:ok, applied} = Samen.Scopes.Finance.ArInvoiceBackfill.run(..., dry_run: false)

  `:allow_paid` is passed through to `ArInvoicePosting` for this repair only:
  a historical invoice's `amount_paid_cents` records a later settlement, not
  an issue-time fact, and the B0 backfill explicitly includes legacy paid
  invoices. A normal `:issue` still refuses a paid-at-issue invoice.
  """

  require Ash.Query

  alias Samen.Scopes.Finance.{ArInvoicePosting, PostingMarker}

  @type skip_reason ::
          :provider_invoice_not_local
          | :already_posted
          | {:status, atom()}
          | {:posting_refused, term()}

  @type skip :: %{invoice_id: term(), reason: skip_reason()}

  @type summary :: %{
          org_id: String.t(),
          dry_run: boolean(),
          scanned: non_neg_integer(),
          posted: [term()],
          would_post: [term()],
          skipped: [skip()]
        }

  @doc """
  Run the backfill for one org.

  Required options: `:repo`, `:org_id`, `:invoice`, `:entry` and
  `:posting_account`. Optional: `:revenue_schedule`, `:org_fx_settings` and
  `:dry_run` (default `true`).

  Returns `{:ok, summary}` where:

    * `:scanned` is every invoice read for the org;
    * `:posted` ids are entries that landed in this apply run;
    * `:would_post` ids are the dry-run candidates that passed preflight;
    * `:skipped` names every other invoice with its reason.

  This function owns one transaction per posted invoice. Call it outside an
  enclosing database transaction so one refusal cannot abort the caller's
  transaction.
  """
  @spec run(keyword()) :: {:ok, summary()} | {:error, term()}
  def run(opts) do
    repo = Keyword.fetch!(opts, :repo)
    org_id = Keyword.fetch!(opts, :org_id)
    invoice_resource = Keyword.fetch!(opts, :invoice)
    entry_resource = Keyword.fetch!(opts, :entry)
    dry_run = Keyword.get(opts, :dry_run, true) != false

    with {:ok, invoices} <- read_invoices(invoice_resource, org_id),
         {:ok, anchored} <- anchored_ids(entry_resource, org_id) do
      plans = Enum.map(invoices, &classify(&1, anchored, opts))

      if dry_run do
        {would_post, skipped} =
          Enum.reduce(plans, {[], []}, fn
            {:post, invoice}, {post, skip} -> {[invoice.id | post], skip}
            {:skip, id, reason}, {post, skip} -> {post, [skip(id, reason) | skip]}
          end)

        {:ok,
         %{
           org_id: org_id,
           dry_run: true,
           scanned: length(plans),
           posted: [],
           would_post: Enum.reverse(would_post),
           skipped: Enum.reverse(skipped)
         }}
      else
        apply_plans(repo, org_id, plans, opts)
      end
    end
  end

  defp read_invoices(resource, org_id) do
    case resource
         |> Ash.Query.filter(org_id == ^org_id)
         |> Ash.Query.sort(id: :asc)
         |> Ash.read(authorize?: false) do
      {:ok, invoices} -> {:ok, invoices}
      {:error, reason} -> {:error, {:invoice_read_failed, reason}}
    end
  end

  defp anchored_ids(entry_resource, org_id) do
    case entry_resource
         |> Ash.Query.filter(org_id == ^org_id and source_key == ^ArInvoicePosting.source_key())
         |> Ash.Query.select([:source_id])
         |> Ash.read(authorize?: false) do
      {:ok, entries} -> {:ok, MapSet.new(entries, & &1.source_id)}
      {:error, reason} -> {:error, {:anchor_read_failed, reason}}
    end
  end

  defp classify(invoice, anchored, opts) do
    cond do
      provider_invoice?(invoice) ->
        {:skip, invoice.id, :provider_invoice_not_local}

      Map.get(invoice, :status) not in [:open, :paid] ->
        {:skip, invoice.id, {:status, Map.get(invoice, :status)}}

      MapSet.member?(anchored, invoice.id) ->
        {:skip, invoice.id, :already_posted}

      true ->
        case ArInvoicePosting.preflight(invoice, posting_opts(opts)) do
          :ok -> {:post, invoice}
          {:error, reason} -> {:skip, invoice.id, {:posting_refused, reason}}
        end
    end
  end

  defp apply_plans(repo, org_id, plans, opts) do
    {posted, skipped} =
      Enum.reduce(plans, {[], []}, fn
        {:skip, id, reason}, {posted, skipped} ->
          {posted, [skip(id, reason) | skipped]}

        {:post, invoice}, {posted, skipped} ->
          case post_invoice(repo, invoice, opts) do
            {:ok, _entry} ->
              {[invoice.id | posted], skipped}

            {:error, reason} ->
              {posted, [skip(invoice.id, {:posting_refused, reason}) | skipped]}
          end
      end)

    {:ok,
     %{
       org_id: org_id,
       dry_run: false,
       scanned: length(plans),
       posted: Enum.reverse(posted),
       would_post: [],
       skipped: Enum.reverse(skipped)
     }}
  end

  defp post_invoice(repo, invoice, opts) do
    post_opts = posting_opts(opts)

    case repo.transaction(fn ->
           prior = PostingMarker.arm_now(repo)

           try do
             case ArInvoicePosting.post(invoice, post_opts) do
               {:ok, entry} -> entry
               {:error, reason} -> repo.rollback({:posting_refused, reason})
             end
           after
             PostingMarker.restore(repo, prior)
           end
         end) do
      {:ok, entry} -> {:ok, entry}
      {:error, {:posting_refused, reason}} -> {:error, reason}
      {:error, reason} -> {:error, {:transaction_failed, reason}}
    end
  end

  defp posting_opts(opts) do
    [
      entry: Keyword.fetch!(opts, :entry),
      posting_account: Keyword.fetch!(opts, :posting_account),
      revenue_schedule: Keyword.get(opts, :revenue_schedule),
      org_fx_settings: Keyword.get(opts, :org_fx_settings),
      allow_paid: true
    ]
  end

  defp provider_invoice?(invoice) do
    case provider_ref(invoice) do
      ref when is_binary(ref) -> String.trim(ref) != ""
      _ -> false
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

  defp skip(invoice_id, reason), do: %{invoice_id: invoice_id, reason: reason}
end
