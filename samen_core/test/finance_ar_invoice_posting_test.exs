defmodule Samen.FinanceArInvoicePostingTest do
  @moduledoc """
  B0 step 3: the AR invoice issuance posting.

  The fixture `InvoiceMirror` carries the same marker-first `:issue` chain as
  the real Billing invoice. These tests prove the receivable/revenue entry,
  the functional-currency refusal, the paid-at-issue and duplicate refusals,
  fail-honest account resolution, the closed-period gate, and the nested
  posting marker restore.
  """

  use ExUnit.Case, async: false

  require Ash.Query

  alias Samen.Scopes.Finance.PostingMarker

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

    {:ok, org: org, scope: admin_scope(org)}
  end

  test "a local invoice posts Dr AR / Cr income exactly once", %{org: org, scope: scope} do
    accounts = seed_posting_accounts(org)
    invoice = new_invoice(org, amount_due_cents: 12_500)

    issued = issue!(invoice, scope)

    assert issued.status == :open

    assert [entry] = entries_for(org, invoice.id)
    assert entry.status == :posted
    assert entry.source_key == "billing_invoice"
    assert entry.source_id == invoice.id

    assert [debit, credit] = lines_for(entry.id)
    assert debit.account_id == accounts.ar_clearing.id
    assert debit.debit_cents == 12_500
    assert debit.credit_cents == 0
    assert credit.account_id == accounts.income.id
    assert credit.credit_cents == 12_500
    assert credit.debit_cents == 0

    # A retry is refused by the anchor pre-read; the ledger still has one entry.
    assert {:error, retry} = issue(issued, scope)
    assert inspect(retry) =~ "already_posted"
    assert length(entries_for(org, invoice.id)) == 1
  end

  test "a non-functional-currency invoice refuses before any entry", %{org: org, scope: scope} do
    _accounts = seed_posting_accounts(org)
    invoice = new_invoice(org, amount_due_cents: 9_000, currency: "EUR")

    assert {:error, error} = issue(invoice, scope)
    assert inspect(error) =~ "unsupported_invoice_currency"
    assert entries_for(org, invoice.id) == []
  end

  test "manual :issue restores the posting marker after the entry lands", %{
    org: org,
    scope: scope
  } do
    _accounts = seed_posting_accounts(org)
    invoice = new_invoice(org, amount_due_cents: 7_500)

    assert PostingMarker.current(@repo) == "off"

    _issued = issue!(invoice, scope)

    assert PostingMarker.current(@repo) == "off"
  end

  test "a paid-at-issue invoice refuses", %{org: org, scope: scope} do
    _accounts = seed_posting_accounts(org)

    invoice =
      new_invoice(org, amount_due_cents: 7_500, amount_paid_cents: 100)

    assert {:error, error} = issue(invoice, scope)
    assert inspect(error) =~ "paid_at_issue"
    assert entries_for(org, invoice.id) == []
  end

  test "an unmapped :ar_clearing refuses fail-honest", %{org: org, scope: scope} do
    invoice = new_invoice(org, amount_due_cents: 5_000)

    assert {:error, error} = issue(invoice, scope)
    assert inspect(error) =~ "unmapped_posting_account"
    assert inspect(error) =~ "ar_clearing"
    assert entries_for(org, invoice.id) == []
  end

  test "an unmapped credit account refuses fail-honest", %{org: org, scope: scope} do
    PostingAccount
    |> Ash.Changeset.for_create(
      :create,
      %{org_id: org, key: :ar_clearing, account_id: new_account(org, "1200", :asset, :debit).id},
      scope: scope
    )
    |> Ash.create!()

    invoice = new_invoice(org, amount_due_cents: 5_000)

    assert {:error, error} = issue(invoice, scope)
    assert inspect(error) =~ "unmapped_posting_account"
    assert inspect(error) =~ "income"
    assert entries_for(org, invoice.id) == []
  end

  test "a closed period refuses the issue and leaves no entry", %{org: org, scope: scope} do
    _accounts = seed_posting_accounts(org)

    today = Date.utc_today()

    period =
      FiscalPeriod
      |> Ash.Changeset.for_create(
        :create,
        %{org_id: org, year: today.year, month: today.month},
        scope: scope
      )
      |> Ash.create!()

    _closed =
      period
      |> Ash.Changeset.for_update(:close, %{}, scope: scope)
      |> Ash.update!()

    invoice = new_invoice(org, amount_due_cents: 5_000)

    assert {:error, error} = issue(invoice, scope)
    assert inspect(error) =~ "CLOSED"
    assert entries_for(org, invoice.id) == []
  end

  test "a nil schedule module takes the income path", %{org: org, scope: scope} do
    accounts = seed_posting_accounts(org)
    invoice = new_invoice(org, amount_due_cents: 3_000)

    _issued = issue!(invoice, scope)

    assert [entry] = entries_for(org, invoice.id)
    assert [debit, credit] = lines_for(entry.id)
    assert debit.account_id == accounts.ar_clearing.id
    assert credit.account_id == accounts.income.id
  end

  # ── helpers ─────────────────────────────────────────────────────────────────

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
    accounts =
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

    accounts
  end

  defp new_invoice(org, attrs) do
    attrs =
      Map.merge(
        %{
          org_id: org,
          customer_id: Ash.UUID.generate(),
          amount_due_cents: 1_000,
          amount_paid_cents: 0,
          currency: "USD",
          line_items: []
        },
        Map.new(attrs)
      )

    InvoiceMirror
    |> Ash.Changeset.for_create(:create, attrs, scope: admin_scope(org))
    |> Ash.create!()
  end

  defp issue(invoice, scope) do
    invoice
    |> Ash.Changeset.for_update(:issue, %{}, scope: scope)
    |> Ash.update()
  end

  defp issue!(invoice, scope) do
    invoice
    |> Ash.Changeset.for_update(:issue, %{}, scope: scope)
    |> Ash.update!()
  end

  defp entries_for(org, invoice_id) do
    JournalEntry
    |> Ash.Query.filter(
      org_id == ^org and source_key == "billing_invoice" and source_id == ^invoice_id
    )
    |> Ash.read!(authorize?: false)
  end

  defp lines_for(entry_id) do
    JournalLine
    |> Ash.Query.filter(entry_id == ^entry_id)
    |> Ash.read!(authorize?: false)
    |> Enum.sort_by(& &1.debit_cents, :desc)
  end
end
