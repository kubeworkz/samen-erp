defmodule Mix.Tasks.Samenerp.BackfillAr do
  @shortdoc "Backfill missing AR issuance entries for legacy local invoices"

  @moduledoc """
  Posts the B0 receivable/revenue entry for legacy local invoices that were
  issued before the invoice-to-GL bridge existed.

      mix samenerp.backfill_ar --org kubeworkz
      mix samenerp.backfill_ar --org kubeworkz --apply

  `--org` is required and accepts a tenant slug or uuid. The default is a dry
  run; `--apply` is the only mode that writes. `--dry-run` is accepted
  explicitly for scripts and is the default when neither flag is present.

  The task uses the host's real Billing and Finance modules:

    * `Samenerp.Billing.Invoice`
    * `Samenerp.Erp.JournalEntry`
    * `Samenerp.Erp.PostingAccount`
    * `Samenerp.Erp.RevenueSchedule`
    * `Samenerp.Erp.OrgFxSettings`

  Every invoice is reported as posted, would-post (dry-run only), or skipped
  with its reason. Provider-mirror invoices are skipped and never posted;
  already-anchored invoices are left untouched.
  """

  use Mix.Task

  require Ash.Query

  alias Samen.Scopes.Finance.ArInvoiceBackfill
  alias Samenerp.Operator, as: Op

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, rest, invalid} =
      OptionParser.parse(args, strict: [org: :string, apply: :boolean, dry_run: :boolean])

    if invalid != [] do
      Mix.raise(
        "unrecognised option(s): #{inspect(invalid)} — usage: mix samenerp.backfill_ar --org <slug|uuid> [--apply]"
      )
    end

    if rest != [] do
      Mix.raise(
        "unexpected argument(s): #{inspect(rest)} — usage: mix samenerp.backfill_ar --org <slug|uuid> [--apply]"
      )
    end

    apply? = Keyword.get(opts, :apply, false)
    explicit_dry_run? = Keyword.get(opts, :dry_run, false)

    if apply? and explicit_dry_run? do
      Mix.raise("--apply and --dry-run are mutually exclusive")
    end

    org = resolve_org!(Keyword.get(opts, :org))

    case ArInvoiceBackfill.run(
           repo: Samenerp.Repo,
           org_id: org.id,
           invoice: Samenerp.Billing.Invoice,
           entry: Samenerp.Erp.JournalEntry,
           posting_account: Samenerp.Erp.PostingAccount,
           revenue_schedule: Samenerp.Erp.RevenueSchedule,
           org_fx_settings: Samenerp.Erp.OrgFxSettings,
           dry_run: not apply?
         ) do
      {:ok, summary} ->
        report(org, summary)
        :ok

      {:error, reason} ->
        Mix.raise("AR invoice backfill failed: #{inspect(reason)}")
    end
  end

  defp report(org, summary) do
    Mix.shell().info("AR invoice backfill — #{org.name} (#{org.id})")
    Mix.shell().info("mode: #{if summary.dry_run, do: "DRY RUN (no writes)", else: "APPLY"}")

    Mix.shell().info("scanned: #{summary.scanned}")
    Mix.shell().info("posted: #{length(summary.posted)}")

    Enum.each(summary.posted, fn invoice_id ->
      Mix.shell().info("  POSTED #{invoice_id}")
    end)

    if summary.dry_run do
      Mix.shell().info("would post: #{length(summary.would_post)}")

      Enum.each(summary.would_post, fn invoice_id ->
        Mix.shell().info("  WOULD POST #{invoice_id}")
      end)
    end

    Mix.shell().info("skipped: #{length(summary.skipped)}")

    Enum.each(summary.skipped, fn %{invoice_id: invoice_id, reason: reason} ->
      Mix.shell().info("  SKIP #{invoice_id} — #{format_reason(reason)}")
    end)
  end

  defp format_reason(:provider_invoice_not_local),
    do: "provider-mirror invoice (not posted by this ledger)"

  defp format_reason(:already_posted), do: "already posted"
  defp format_reason({:status, status}), do: "status #{inspect(status)}"
  defp format_reason({:posting_refused, reason}), do: "posting refused: #{inspect(reason)}"
  defp format_reason(reason), do: inspect(reason)

  # Tenant orgs only: the operator seat is not an AR workspace. This mirrors
  # the Kubeworkz books task's resolution rule.
  defp resolve_org!(nil) do
    Mix.raise(
      "--org is required (a tenant slug or uuid). This host's tenant orgs:\n" <>
        Enum.map_join(tenant_orgs(), "\n", fn org ->
          "  #{org.id}  #{org.name}  #{org.slug || "—"}"
        end)
    )
  end

  defp resolve_org!(name_or_id) do
    orgs = tenant_orgs()

    case Enum.find(orgs, fn org -> org.id == name_or_id or org.slug == name_or_id end) do
      nil ->
        Mix.raise(
          "no tenant org matches #{inspect(name_or_id)}. This host's tenant orgs:\n" <>
            Enum.map_join(orgs, "\n", fn org ->
              "  #{org.id}  #{org.name}  #{org.slug || "—"}"
            end)
        )

      org ->
        org
    end
  end

  defp tenant_orgs do
    operator = Samenerp.Seeds.operator_org_id()

    Op.Org
    |> Ash.Query.filter((is_nil(plan) or plan != "operator") and id != ^operator)
    |> Ash.Query.sort(name: :asc)
    |> Ash.read!(authorize?: false)
  end
end
