defmodule Samenerp.KubeworkzBackfillArTest do
  @moduledoc """
  Host proof for `mix samenerp.backfill_ar`: the task defaults to a dry run,
  recognizes the host's real Billing and Finance modules, and skips a
  provider-mirror invoice without writing an AR journal entry.
  """

  use Samenerp.DataCase, async: false

  require Ash.Query

  alias Samenerp.Kubeworkz.Books
  alias Samenerp.Operator, as: Op

  setup do
    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(previous_shell) end)

    org =
      Op.Org
      |> Ash.Changeset.for_create(:create, %{name: "Kubeworkz AR Backfill"}, authorize?: false)
      |> Ash.create!(authorize?: false)

    admin = admin_scope(org.id)
    customer = customer!(org.id, admin)

    invoice =
      invoice!(org.id, customer.id, admin, %{
        provider_invoice_ref: "KUBE-BACKFILL-PROVIDER-1",
        status: :open,
        amount_due_cents: 50_000,
        currency: "CAD"
      })

    {:ok, org: org, invoice: invoice}
  end

  test "the default is a dry run and a provider-mirror invoice is never posted", %{
    org: org,
    invoice: invoice
  } do
    assert :ok = Mix.Tasks.Samenerp.BackfillAr.run(["--org", org.id])
    dry_output = shell_messages()

    assert Enum.any?(dry_output, &(&1 =~ "mode: DRY RUN (no writes)"))
    assert Enum.any?(dry_output, &(&1 =~ "posted: 0"))
    assert Enum.any?(dry_output, &(&1 =~ "would post: 0"))
    assert Enum.any?(dry_output, &(&1 =~ "skipped: 1"))

    assert Enum.any?(dry_output, fn line ->
             line =~ "SKIP #{invoice.id}" and line =~ "provider-mirror invoice"
           end)

    assert entries_for(org.id, invoice.id) == []

    assert :ok = Mix.Tasks.Samenerp.BackfillAr.run(["--org", org.id, "--apply"])
    apply_output = shell_messages()

    assert Enum.any?(apply_output, &(&1 =~ "mode: APPLY"))
    assert Enum.any?(apply_output, &(&1 =~ "posted: 0"))
    assert Enum.any?(apply_output, &(&1 =~ "skipped: 1"))

    assert Enum.any?(apply_output, fn line ->
             line =~ "SKIP #{invoice.id}" and line =~ "provider-mirror invoice"
           end)

    # The provider mirror has not been touched or posted by the ledger.
    assert entries_for(org.id, invoice.id) == []

    reloaded = Ash.get!(Samenerp.Billing.Invoice, invoice.id, authorize?: false)
    assert reloaded.status == :open
    assert reloaded.provider_invoice_ref == "KUBE-BACKFILL-PROVIDER-1"
  end

  test "apply posts a local open invoice, prints POSTED, and replay is unchanged", %{
    org: org,
    invoice: provider_invoice
  } do
    Books.seed!(org.id)

    local =
      legacy_open_invoice!(
        org.id,
        provider_invoice.customer_id,
        admin_scope(org.id),
        25_000
      )

    assert :ok = Mix.Tasks.Samenerp.BackfillAr.run(["--org", org.id, "--apply"])
    output = shell_messages()

    assert Enum.any?(output, &(&1 =~ "mode: APPLY"))
    assert Enum.any?(output, &(&1 =~ "posted: 1"))
    assert Enum.any?(output, &(&1 =~ "POSTED #{local.id}"))
    assert Enum.any?(output, &(&1 =~ "skipped: 1"))
    assert Enum.any?(output, &(&1 =~ "SKIP #{provider_invoice.id}"))

    assert [entry] = entries_for(org.id, local.id)
    assert entry.status == :posted
    assert entry.source_key == "billing_invoice"
    assert entry.source_id == local.id

    lines = Ash.load!(entry, :lines, authorize?: false).lines
    ar = account!(org.id, "1100")
    income = account!(org.id, "4000")

    assert Enum.sort(Enum.map(lines, &{&1.account_id, &1.debit_cents, &1.credit_cents})) ==
             Enum.sort([{ar.id, 25_000, 0}, {income.id, 0, 25_000}])

    # Replaying the task sees the anchor and posts nothing new.
    assert :ok = Mix.Tasks.Samenerp.BackfillAr.run(["--org", org.id, "--apply"])
    replay_output = shell_messages()

    assert Enum.any?(replay_output, &(&1 =~ "posted: 0"))
    assert Enum.any?(replay_output, &(&1 =~ "skipped: 2"))
    assert Enum.any?(replay_output, &(&1 =~ "SKIP #{local.id} — already posted"))
    assert length(entries_for(org.id, local.id)) == 1

    assert Ash.get!(Samenerp.Billing.Invoice, local.id, authorize?: false).status == :open
  end

  defp shell_messages(acc \\ []) do
    receive do
      {:mix_shell, :info, [message]} -> shell_messages([message | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp admin_scope(org_id) do
    %Samen.Scope{
      actor: %{id: "admin:#{org_id}", org_id: org_id, role: :admin, kind: :tenant, plane: :tenant}
    }
  end

  defp legacy_open_invoice!(org_id, customer_id, scope, amount_cents) do
    invoice =
      invoice!(org_id, customer_id, scope, %{
        status: :draft,
        amount_due_cents: amount_cents,
        currency: "CAD"
      })

    # Legacy rows predate the B0 issue guard: an open local invoice with no
    # journal anchor. Raw SQL models that historical state; the normal :issue
    # path would post the entry and make this test vacuous.
    Samenerp.Repo.query!(
      "UPDATE eri_invoice SET eri_status = 'open' WHERE eri_id = $1",
      [Ecto.UUID.dump!(invoice.id)]
    )

    Ash.get!(Samenerp.Billing.Invoice, invoice.id, authorize?: false)
  end

  defp account!(org_id, code) do
    Samenerp.Erp.Account
    |> Ash.Query.filter(org_id == ^org_id and code == ^code)
    |> Ash.read_one!(authorize?: false)
  end

  defp customer!(org_id, scope) do
    Samenerp.Billing.Customer
    |> Ash.Changeset.for_create(:create, %{org_id: org_id, currency: "CAD"}, scope: scope)
    |> Ash.create!(scope: scope)
  end

  defp invoice!(org_id, customer_id, scope, attrs) do
    Samenerp.Billing.Invoice
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(
        %{
          org_id: org_id,
          customer_id: customer_id,
          status: :open,
          amount_due_cents: 0,
          amount_paid_cents: 0,
          currency: "CAD",
          due_date: ~U[2026-10-01 00:00:00Z],
          period_start: ~U[2026-09-01 00:00:00Z],
          period_end: ~U[2026-09-30 00:00:00Z],
          line_items: []
        },
        attrs
      ),
      scope: scope
    )
    |> Ash.create!(scope: scope)
  end

  defp entries_for(org_id, invoice_id) do
    Samenerp.Erp.JournalEntry
    |> Ash.Query.filter(
      org_id == ^org_id and source_key == "billing_invoice" and source_id == ^invoice_id
    )
    |> Ash.read!(authorize?: false)
  end
end
