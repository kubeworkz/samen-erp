defmodule Samen.FinanceArInvoiceBackfillTest do
  @moduledoc """
  B0 legacy backfill: only local issued invoices are candidates, dry-run writes
  nothing and reports real preflight refusals, apply posts exactly once, and a
  replay leaves the existing anchor untouched.
  """

  use ExUnit.Case, async: false

  require Ash.Query

  alias Samen.Scopes.Finance.{ArInvoiceBackfill, PostingMarker}

  alias SamenCore.Support.FinanceFixture.{
    Account,
    FiscalPeriod,
    InvoiceMirror,
    JournalEntry,
    JournalLine,
    PostingAccount
  }

  @repo SamenCore.TestRepo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(@repo)
    org = Ash.UUID.generate()
    accounts = seed_posting_accounts(org)

    {:ok, org: org, scope: admin_scope(org), accounts: accounts}
  end

  test "backfill posts only local open/paid invoices and reports the rest", %{
    org: org,
    scope: scope
  } do
    open = new_invoice(org, %{status: :open, amount_due_cents: 10_000})
    paid = new_invoice(org, %{status: :paid, amount_due_cents: 20_000, amount_paid_cents: 20_000})
    draft = new_invoice(org, %{status: :draft})
    void = new_invoice(org, %{status: :void})

    already = issue!(new_invoice(org, %{status: :open, amount_due_cents: 5_000}), scope)

    # A foreign org's invoice is invisible to this org's sweep.
    foreign_org = Ash.UUID.generate()
    foreign = new_invoice(foreign_org, %{status: :open})

    assert {:ok, summary} = run(org, dry_run: false)

    assert summary.scanned == 5
    assert summary.dry_run == false
    assert Enum.sort(summary.posted) == Enum.sort([open.id, paid.id])
    assert summary.would_post == []

    assert reason_for(summary.skipped, draft.id) == {:status, :draft}
    assert reason_for(summary.skipped, void.id) == {:status, :void}
    assert reason_for(summary.skipped, already.id) == :already_posted
    refute Enum.any?(summary.skipped, &(&1.invoice_id == foreign.id))

    assert [open_entry] = entries_for(org, open.id)
    assert open_entry.status == :posted
    assert open_entry.source_key == "billing_invoice"
    assert open_entry.source_id == open.id
    assert entry_total(open_entry.id) == 10_000

    # A legacy paid invoice still gets its gross issue entry; amount_paid is a
    # later settlement fact, not an issue-time refusal.
    assert [paid_entry] = entries_for(org, paid.id)
    assert paid_entry.status == :posted
    assert entry_total(paid_entry.id) == 20_000

    # The already-issued invoice was not re-posted.
    assert length(entries_for(org, already.id)) == 1

    # The direct posting path did not leak its armed marker.
    assert PostingMarker.current(@repo) == "off"
  end

  test "dry-run writes nothing and previews the postable invoice", %{
    org: org
  } do
    open = new_invoice(org, %{status: :open})
    draft = new_invoice(org, %{status: :draft})

    assert {:ok, summary} = run(org)

    assert summary.dry_run == true
    assert summary.scanned == 2
    assert summary.posted == []
    assert summary.would_post == [open.id]
    assert reason_for(summary.skipped, draft.id) == {:status, :draft}
    assert entries_for(org, open.id) == []
    assert PostingMarker.current(@repo) == "off"
  end

  test "dry-run reports a real preflight refusal instead of a false candidate", %{org: org} do
    eur = new_invoice(org, %{status: :open, currency: "EUR"})

    assert {:ok, summary} = run(org)

    assert summary.would_post == []

    assert reason_for(summary.skipped, eur.id) ==
             {:posting_refused, {:unsupported_invoice_currency, "EUR", "USD"}}

    assert entries_for(org, eur.id) == []
  end

  test "a second apply is a no-op and names the invoice as already posted", %{org: org} do
    invoice = new_invoice(org, %{status: :open, amount_due_cents: 7_500})

    assert {:ok, first} = run(org, dry_run: false)
    assert first.posted == [invoice.id]
    assert length(entries_for(org, invoice.id)) == 1

    assert {:ok, second} = run(org, dry_run: false)
    assert second.posted == []
    assert reason_for(second.skipped, invoice.id) == :already_posted
    assert length(entries_for(org, invoice.id)) == 1
  end

  test "an apply refusal rolls back, reports the reason, and restores the marker", %{
    org: org,
    scope: scope
  } do
    close_current_period!(org, scope)
    invoice = new_invoice(org, %{status: :open, amount_due_cents: 6_000})

    assert {:ok, summary} = run(org, dry_run: false)

    assert summary.posted == []
    assert {:posting_refused, reason} = reason_for(summary.skipped, invoice.id)
    assert inspect(reason) =~ "CLOSED"
    assert entries_for(org, invoice.id) == []
    assert PostingMarker.current(@repo) == "off"
  end

  # ── helpers ─────────────────────────────────────────────────────────────────

  defp run(org, extra \\ []) do
    ArInvoiceBackfill.run(
      Keyword.merge(
        [
          repo: @repo,
          org_id: org,
          invoice: InvoiceMirror,
          entry: JournalEntry,
          posting_account: PostingAccount,
          revenue_schedule: nil,
          org_fx_settings: nil
        ],
        extra
      )
    )
  end

  defp tenant_scope(org_id) do
    %Samen.Scope{
      actor: %{id: "u:#{org_id}", org_id: org_id, role: :member, kind: :tenant, plane: :tenant}
    }
  end

  defp admin_scope(org_id) do
    %Samen.Scope{
      actor: %{id: "a:#{org_id}", org_id: org_id, role: :admin, kind: :tenant, plane: :tenant}
    }
  end

  defp new_account(org, code, kind, side) do
    Account
    |> Ash.Changeset.for_create(
      :create,
      %{org_id: org, code: code, name: "Account #{code}", kind: kind, normal_side: side},
      scope: tenant_scope(org)
    )
    |> Ash.create!()
  end

  defp seed_posting_accounts(org) do
    Map.new(
      [
        {:ar_clearing, "1200", :asset, :debit},
        {:income, "4000", :income, :credit}
      ],
      fn {key, code, kind, side} ->
        account = new_account(org, code, kind, side)

        PostingAccount
        |> Ash.Changeset.for_create(
          :create,
          %{org_id: org, key: key, account_id: account.id},
          scope: admin_scope(org)
        )
        |> Ash.create!()

        {key, account}
      end
    )
  end

  defp new_invoice(org, attrs) do
    attrs =
      Map.merge(
        %{
          org_id: org,
          customer_id: Ash.UUID.generate(),
          status: :draft,
          amount_due_cents: 1_000,
          amount_paid_cents: 0,
          currency: "USD",
          line_items: []
        },
        attrs
      )

    InvoiceMirror
    |> Ash.Changeset.for_create(:create, attrs, scope: admin_scope(org))
    |> Ash.create!()
  end

  defp issue!(invoice, scope) do
    invoice
    |> Ash.Changeset.for_update(:issue, %{}, scope: scope)
    |> Ash.update!()
  end

  defp close_current_period!(org, scope) do
    today = Date.utc_today()

    FiscalPeriod
    |> Ash.Changeset.for_create(
      :create,
      %{org_id: org, year: today.year, month: today.month},
      scope: scope
    )
    |> Ash.create!()
    |> Ash.Changeset.for_update(:close, %{}, scope: scope)
    |> Ash.update!()
  end

  defp entries_for(org, invoice_id) do
    JournalEntry
    |> Ash.Query.filter(
      org_id == ^org and source_key == "billing_invoice" and source_id == ^invoice_id
    )
    |> Ash.read!(authorize?: false)
  end

  defp entry_total(entry_id) do
    JournalLine
    |> Ash.Query.filter(entry_id == ^entry_id)
    |> Ash.read!(authorize?: false)
    |> Enum.reduce(0, &(&1.debit_cents + &2))
  end

  defp reason_for(skipped, invoice_id) do
    Enum.find_value(skipped, fn
      %{invoice_id: ^invoice_id, reason: reason} -> reason
      _ -> nil
    end)
  end
end
