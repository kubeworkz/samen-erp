defmodule Samen.FinanceAdjustmentsTest do
  @moduledoc """
  WS-ERP adjustment documents (#6): `CreditNote` and `VendorCredit` are mounted,
  post on open, apply without a second entry, void through the journal's linked
  reversal, and net their target document in the AR/AP aging reads.
  """

  use ExUnit.Case, async: false

  require Ash.Query

  alias Samen.Scopes.Finance.{ApAging, ArAging}

  alias SamenCore.Support.FinanceFixture.{
    Account,
    ApInvoice,
    CreditNote,
    InvoiceMirror,
    JournalEntry,
    JournalLine,
    PaymentReceipt,
    PostingAccount,
    VendorCredit
  }

  @repo SamenCore.TestRepo
  @as_of ~D[2026-09-30]

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(@repo)
    org = Ash.UUID.generate()

    {:ok, org: org, scope: tenant_scope(org), accounts: seed_posting_accounts(org)}
  end

  describe "CreditNote (AR adjustment)" do
    test "opening a credit posts Dr credit_note_clearing / Cr ar_clearing", %{
      org: org,
      scope: scope,
      accounts: accounts
    } do
      invoice = new_invoice(org)
      note = new_credit_note(scope, org, invoice, amount_cents: 6_000)

      assert note.status == :draft

      opened = open(note, scope)
      assert opened.status == :open
      assert opened.entry_id
      assert %DateTime{} = opened.posted_at

      entry = entry!(org, "credit_note", opened.id)
      assert entry.status == :posted

      [debit, credit] = debit_first(entry.id)
      assert debit.debit_cents == 6_000
      assert debit.credit_cents == 0
      assert debit.account_id == accounts.credit_note_clearing.id

      assert credit.credit_cents == 6_000
      assert credit.debit_cents == 0
      assert credit.account_id == accounts.ar_clearing.id
    end

    test "a write-off opens through bad_debt_expense", %{
      org: org,
      scope: scope,
      accounts: accounts
    } do
      invoice = new_invoice(org)

      opened =
        scope
        |> new_credit_note(org, invoice, kind: :write_off, amount_cents: 2_500)
        |> open(scope)

      entry = entry!(org, "credit_note", opened.id)
      [debit, credit] = debit_first(entry.id)

      assert debit.account_id == accounts.bad_debt_expense.id
      assert debit.debit_cents == 2_500
      assert credit.account_id == accounts.ar_clearing.id
    end

    test "applying flips the state without a second entry", %{org: org, scope: scope} do
      invoice = new_invoice(org)
      opened = scope |> new_credit_note(org, invoice) |> open(scope)

      applied =
        opened
        |> Ash.Changeset.for_update(:apply, %{}, scope: scope)
        |> Ash.update!()

      assert applied.status == :applied
      assert %DateTime{} = applied.applied_at
      assert applied.entry_id == opened.entry_id

      assert entry_count(org, "credit_note", opened.id) == 1
    end

    test "voiding an open credit voids its entry and posts the linked reversal", %{
      org: org,
      scope: scope
    } do
      invoice = new_invoice(org)
      opened = scope |> new_credit_note(org, invoice) |> open(scope)

      voided =
        opened
        |> Ash.Changeset.for_update(:void, %{}, scope: scope)
        |> Ash.update!()

      assert voided.status == :void

      original = Ash.get!(JournalEntry, opened.entry_id, authorize?: false)
      assert original.status == :void
      assert original.voided_entry_id

      reversal = Ash.get!(JournalEntry, original.voided_entry_id, authorize?: false)
      assert reversal.status == :posted
      assert reversal.voided_entry_id == original.id
    end

    test "voiding a draft posts nothing", %{org: org, scope: scope} do
      invoice = new_invoice(org)
      note = new_credit_note(scope, org, invoice)

      voided =
        note
        |> Ash.Changeset.for_update(:void, %{}, scope: scope)
        |> Ash.update!()

      assert voided.status == :void
      refute voided.entry_id
      assert entry_count(org, "credit_note", note.id) == 0

      assert {:error, %Ash.Error.Invalid{}} =
               voided
               |> Ash.Changeset.for_update(:void, %{}, scope: scope)
               |> Ash.update()
    end

    test "the guard refuses a missing reference, a foreign customer and an invalid edge", %{
      org: org,
      scope: scope
    } do
      invoice = new_invoice(org)

      no_reference = new_credit_note(scope, org, invoice, invoice_id: nil)
      assert {:error, %Ash.Error.Invalid{}} = open_result(no_reference, scope)

      foreign_customer =
        new_credit_note(scope, org, invoice, customer_id: Ash.UUID.generate())

      assert {:error, %Ash.Error.Invalid{}} = open_result(foreign_customer, scope)

      draft = new_credit_note(scope, org, invoice)

      assert {:error, %Ash.Error.Invalid{}} =
               draft
               |> Ash.Changeset.for_update(:apply, %{}, scope: scope)
               |> Ash.update()

      applied = scope |> new_credit_note(org, invoice) |> open(scope) |> apply!(scope)

      assert {:error, %Ash.Error.Invalid{}} =
               applied
               |> Ash.Changeset.for_update(:void, %{}, scope: scope)
               |> Ash.update()
    end
  end

  describe "VendorCredit (AP adjustment)" do
    test "opening posts Dr ap_clearing / Cr vendor_credit_clearing", %{
      org: org,
      scope: scope,
      accounts: accounts
    } do
      bill = approve_bill!(new_bill(scope, org, accounts.expense, 9_000), scope)
      credit = new_vendor_credit(scope, org, bill, amount_cents: 3_000)

      opened = open(credit, scope)
      assert opened.status == :open
      assert opened.entry_id

      entry = entry!(org, "vendor_credit", opened.id)
      assert entry.status == :posted

      [debit, credit_line] = debit_first(entry.id)
      assert debit.account_id == accounts.ap_clearing.id
      assert debit.debit_cents == 3_000
      assert credit_line.account_id == accounts.vendor_credit_clearing.id
      assert credit_line.credit_cents == 3_000
    end

    test "applying and voiding follow the same rules as an AR adjustment", %{
      org: org,
      scope: scope,
      accounts: accounts
    } do
      bill = approve_bill!(new_bill(scope, org, accounts.expense, 9_000), scope)
      credit = scope |> new_vendor_credit(org, bill) |> open(scope)

      applied = apply!(credit, scope)
      assert applied.status == :applied
      assert entry_count(org, "vendor_credit", credit.id) == 1

      open_credit = scope |> new_vendor_credit(org, bill) |> open(scope) |> void!(scope)
      assert open_credit.status == :void

      original = Ash.get!(JournalEntry, open_credit.entry_id, authorize?: false)
      assert original.status == :void
      assert original.voided_entry_id
    end
  end

  describe "aging nets posted adjustments" do
    test "AR: open and applied credits reduce the invoice; voiding restores it", %{
      org: org,
      scope: scope
    } do
      invoice = new_invoice(org, amount_due_cents: 10_000)
      assert ar_total(org, scope) == 10_000

      credit = scope |> new_credit_note(org, invoice, amount_cents: 4_000) |> open(scope)
      assert ar_total(org, scope) == 6_000

      _applied = apply!(credit, scope)
      assert ar_total(org, scope) == 6_000

      voided =
        scope
        |> new_credit_note(org, invoice, amount_cents: 1_000)
        |> open(scope)

      assert ar_total(org, scope) == 5_000
      _voided = void!(voided, scope)
      assert ar_total(org, scope) == 6_000
    end

    test "AP: open and applied vendor credits reduce the bill; voiding restores it", %{
      org: org,
      scope: scope,
      accounts: accounts
    } do
      bill = approve_bill!(new_bill(scope, org, accounts.expense, 9_000), scope)
      assert ap_total(org, scope) == 9_000

      credit = scope |> new_vendor_credit(org, bill, amount_cents: 3_000) |> open(scope)
      assert ap_total(org, scope) == 6_000

      _applied = apply!(credit, scope)
      assert ap_total(org, scope) == 6_000

      open_credit = scope |> new_vendor_credit(org, bill, amount_cents: 1_000) |> open(scope)
      assert ap_total(org, scope) == 5_000

      _voided = void!(open_credit, scope)
      assert ap_total(org, scope) == 6_000
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp tenant_scope(org_id) do
    %Samen.Scope{
      actor: %{id: "u:#{org_id}", org_id: org_id, role: :member, kind: :tenant, plane: :tenant}
    }
  end

  defp admin_scope(org_id) do
    %Samen.Scope{
      actor: %{
        id: "a:#{org_id}",
        org_id: org_id,
        role: :admin,
        kind: :tenant,
        plane: :tenant
      }
    }
  end

  defp seed_posting_accounts(org) do
    keys = [
      :ap_clearing,
      :ar_clearing,
      :credit_note_clearing,
      :vendor_credit_clearing,
      :bad_debt_expense
    ]

    accounts =
      Map.new(keys, fn key ->
        account = new_account(org, Atom.to_string(key))

        PostingAccount
        |> Ash.Changeset.for_create(
          :create,
          %{org_id: org, key: key, account_id: account.id},
          scope: admin_scope(org)
        )
        |> Ash.create!()

        {key, account}
      end)

    Map.put(accounts, :expense, accounts.bad_debt_expense)
  end

  defp new_account(org, code) do
    Account
    |> Ash.Changeset.for_create(
      :create,
      %{
        org_id: org,
        code: code,
        name: "Adjustment #{code}",
        kind: :asset,
        normal_side: :debit
      },
      scope: admin_scope(org)
    )
    |> Ash.create!()
  end

  defp new_invoice(org, attrs \\ %{}) do
    attrs =
      Map.merge(
        %{
          org_id: org,
          customer_id: Ash.UUID.generate(),
          status: :open,
          amount_due_cents: 10_000
        },
        Map.new(attrs)
      )

    InvoiceMirror
    |> Ash.Changeset.for_create(:create, attrs, scope: admin_scope(org))
    |> Ash.create!()
  end

  defp new_credit_note(scope, org, invoice, attrs \\ %{}) do
    attrs =
      Map.merge(
        %{
          org_id: org,
          customer_id: invoice.customer_id,
          number: "CN-" <> binary_part(Ash.UUID.generate(), 0, 8),
          date: ~D[2026-09-10],
          amount_cents: 4_000,
          kind: :credit,
          invoice_id: invoice.id
        },
        Map.new(attrs)
      )

    CreditNote
    |> Ash.Changeset.for_create(:create, attrs, scope: scope)
    |> Ash.create!()
  end

  defp new_bill(scope, org, account, amount) do
    ApInvoice
    |> Ash.Changeset.for_create(:create, %{
      org_id: org,
      vendor_id: Ash.UUID.generate(),
      number: "V-" <> binary_part(Ash.UUID.generate(), 0, 8),
      bill_date: ~D[2026-09-01],
      lines: [%{account_id: account.id, amount_cents: amount, memo: "adjustment test"}]
    })
    |> Ash.create!(scope: scope)
  end

  defp new_vendor_credit(scope, org, bill, attrs \\ %{}) do
    attrs =
      Map.merge(
        %{
          org_id: org,
          vendor_id: bill.vendor_id,
          number: "VC-" <> binary_part(Ash.UUID.generate(), 0, 8),
          date: ~D[2026-09-10],
          amount_cents: 3_000,
          bill_id: bill.id
        },
        Map.new(attrs)
      )

    VendorCredit
    |> Ash.Changeset.for_create(:create, attrs, scope: scope)
    |> Ash.create!()
  end

  defp open(note, scope) do
    note
    |> Ash.Changeset.for_update(:open, %{}, scope: scope)
    |> Ash.update!()
  end

  defp open_result(note, scope) do
    note
    |> Ash.Changeset.for_update(:open, %{}, scope: scope)
    |> Ash.update()
  end

  defp apply!(note, scope) do
    note
    |> Ash.Changeset.for_update(:apply, %{}, scope: scope)
    |> Ash.update!()
  end

  defp void!(note, scope) do
    note
    |> Ash.Changeset.for_update(:void, %{}, scope: scope)
    |> Ash.update!()
  end

  defp entry!(org, source_key, source_id) do
    JournalEntry
    |> Ash.Query.filter(org_id == ^org and source_key == ^source_key and source_id == ^source_id)
    |> Ash.read_one!(authorize?: false)
  end

  defp entry_count(org, source_key, source_id) do
    JournalEntry
    |> Ash.Query.filter(org_id == ^org and source_key == ^source_key and source_id == ^source_id)
    |> Ash.read!(authorize?: false)
    |> length()
  end

  defp debit_first(entry_id) do
    JournalLine
    |> Ash.Query.filter(entry_id == ^entry_id)
    |> Ash.read!(authorize?: false)
    |> Enum.sort_by(&(-&1.debit_cents))
  end

  defp ar_total(org, scope) do
    {:ok, aging} =
      ArAging.for_org(
        invoice: InvoiceMirror,
        receipt: PaymentReceipt,
        credit_note: CreditNote,
        org_id: org,
        scope: scope,
        as_of: @as_of
      )

    aging.total_cents
  end

  defp ap_total(org, scope) do
    {:ok, aging} =
      ApAging.for_org(
        ap_invoice: ApInvoice,
        vendor_credit: VendorCredit,
        org_id: org,
        scope: scope,
        as_of: @as_of
      )

    aging.total_cents
  end

  defp approve_bill!(bill, scope) do
    {:gated, approval_id} = gate(bill, scope)

    assert {:ok, _, _} =
             Samen.Approvals.approve(approval_id, "a2:decider",
               approval_resource: SamenCore.Support.ApprovalsFixture.Approval,
               repo: @repo
             )

    Ash.get!(ApInvoice, bill.id, authorize?: false)
  end

  defp gate(bill, scope) do
    case bill |> Ash.Changeset.for_update(:approve, %{}, scope: scope) |> Ash.update() do
      {:error, %Ash.Error.Forbidden{errors: errors}} ->
        case Enum.find(errors, &match?(%{__struct__: Samen.Approvals.ApprovalRequired}, &1)) do
          nil -> flunk("expected ApprovalRequired, got: #{inspect(errors)}")
          found -> {:gated, found.approval_id}
        end

      {:ok, _} ->
        flunk("the :approve action succeeded WITHOUT the Gate")

      {:error, other} ->
        flunk("unexpected :approve failure: #{inspect(other)}")
    end
  end
end
