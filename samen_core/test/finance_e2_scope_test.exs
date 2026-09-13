defmodule Samen.FinanceE2ScopeTest do
  @moduledoc """
  The Finance scope's E2 documents + the R2 reconciliation red-path suite
  (WS-ERP E2; design §2.2 + §6.3), mounted via `test/support/finance_fixture.ex`.

  Every red-path pairs denial with a positive control (anti-tautology, the
  house `RedPath` style). Blocks:

    * d1 PostingAccount CRUD: the Tier-0 map is admin-gated (member RED /
      admin CONTROL), same-org FK'd, one row per {org, key}.
    * d2 the AP bill: draft lifecycle (create/edit CONTROL), member create OK
      (a clerk enters bills), line-shape refusals (RED: empty lines, negative
      or non-integer amount — the Ash guard; the DB belt is the c8-style twin).
    * d3 `:approve` rides the ADR-040 Gate: ungated → `ApprovalRequired` (RED)
      with a pending approval row opened (CONTROL on the row), SELF-approval
      refused (`{:error, :self_approval}`, the c12 two-party discipline),
      the DISTINCT approver's `approve/3` re-invokes `:approve` as the
      requester: the bill lands `:approved`, the expense+liability entry
      (anchored `source_key: "ap_invoice"`) lands POSTED, and R1's org
      balance stays zero (the AP entry participates in the ledger's zero).
    * d4 the one-way state machine: re-approve is refused (RED); draft edits
      after approval are refused (RED) with the draft-edit CONTROL.
    * d5 exactly-once posting: a double `:post_receipt` is refused (RED); a
      second receipt for the same anchor posts only while drafts — once both
      are posted the `prc_anchor_unique` belt fires (RED) with a DIFFERENT-
      anchor receipt as the CONTROL.
    * d6 `:post_receipt`: the cash+AR entry lands POSTED in ONE transaction,
      anchored `source_key: "billing_payment"`, linked via `posted_entry_id`.
    * d7 **R2 green**: receipts == GL == mirror (whole ledger), and a bounded
      period window that EXCLUDES one receipt moves all three sums together.
    * d8 **R2 anti-tautology**: a receipt forced into the table below the
      guards (raw SQL with the marker — the sabotage simulation) makes the
      sums DIVERGE: intake claims more cash than the GL holds. The equality
      is load-bearing, not decorative.
    * d9 the belts: raw-SQL non-draft INSERTs and raw-SQL draft→posted/
      draft→approved transitions are refused without the marker (RED); the
      sanctioned marker-armed path lands them (CONTROL).
    * d10 cross-org: a foreign-org posting account is refused (SameOrgFk RED)
      with the same-org CONTROL; a foreign receipt is invisible (OrgScope).
    * d11 catalog registration: every E2 fixture column is catalogued (c11's
      E2 twin, scoped to the four new tables).
    * d12 the no-persisted-inputs rule: the approval row carries only the
      bounded tuple — no lines, no amounts (ADR-040 §4.4 / INV-1).
  """
  use ExUnit.Case, async: false

  require Ash.Query

  alias Samen.Scopes.Finance.ReconcilePayments
  alias Samen.Scopes.Finance.Reconcile
  alias SamenCore.Support.FinanceFixture.{
    Account,
    ApInvoice,
    JournalEntry,
    JournalLine,
    PaymentMirror,
    PaymentReceipt,
    PostingAccount
  }

  @repo SamenCore.TestRepo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(@repo)
    org = Ash.UUID.generate()
    {:ok, org: org, scope: tenant_scope(org)}
  end

  # ── d1: PostingAccount CRUD ─────────────────────────────────────────────────

  describe "d1 — PostingAccount CRUD (the Tier-0 posting map)" do
    test "an admin maps each posting key to its CoA account; a member is refused", %{
      org: org,
      scope: scope
    } do
      cash = new_account(scope, org, "1000")

      assert {:error, %Ash.Error.Forbidden{}} =
               PostingAccount
               |> Ash.Changeset.for_create(:create, %{
                 org_id: org,
                 key: :cash,
                 account_id: cash.id
               })
               |> Ash.create(scope: scope)

      row =
        PostingAccount
        |> Ash.Changeset.for_create(:create, %{org_id: org, key: :cash, account_id: cash.id},
          scope: admin_scope(org)
        )
        |> Ash.create!()

      assert row.key == :cash
    end

    test "a second row for the same {org, key} is refused (the unique map)", %{
      org: org,
      scope: scope
    } do
      seed_posting_accounts(org)

      assert {:error, _} =
               PostingAccount
               |> Ash.Changeset.for_create(:create, %{
                 org_id: org,
                 key: :cash,
                 account_id: new_account(scope, org, "1010").id
               })
               |> Ash.create(scope: admin_scope(org))
    end
  end

  # ── d2: the AP bill draft lifecycle ────────────────────────────────────────

  describe "d2 — the AP bill draft lifecycle" do
    test "a member enters a draft bill and edits it (CONTROL)", %{org: org, scope: scope} do
      expense = seed_posting_accounts(org)

      bill =
        new_bill(scope, org, [bill_line(expense, 12_500)], bill_date: ~D[2026-09-01])

      assert bill.status == :draft

      edited =
        bill
        |> Ash.Changeset.for_update(:update, %{memo: "net-30 vendor terms"}, scope: scope)
        |> Ash.update!()

      assert edited.memo == "net-30 vendor terms"
    end

    test "an empty lines list is refused (RED)", %{org: org, scope: scope} do
      expense = seed_posting_accounts(org)
      _ = expense

      assert {:error, %Ash.Error.Invalid{}} =
               ApInvoice
               |> Ash.Changeset.for_create(:create, %{
                 org_id: org,
                 vendor_id: Ash.UUID.generate(),
                 number: "V-EMPTY",
                 bill_date: ~D[2026-09-01],
                 lines: []
               })
               |> Ash.create(scope: scope)
    end

    test "a negative line amount is refused by the guard (RED)", %{org: org, scope: scope} do
      expense = seed_posting_accounts(org)

      assert {:error, %Ash.Error.Invalid{}} =
               ApInvoice
               |> Ash.Changeset.for_create(:create, %{
                 org_id: org,
                 vendor_id: Ash.UUID.generate(),
                 number: "V-NEG",
                 bill_date: ~D[2026-09-01],
                 lines: [%{account_id: expense.id, amount_cents: -500}]
               })
               |> Ash.create(scope: scope)
    end

    test "a non-integer line amount is refused (RED)", %{org: org, scope: scope} do
      expense = seed_posting_accounts(org)

      assert {:error, %Ash.Error.Invalid{}} =
               ApInvoice
               |> Ash.Changeset.for_create(:create, %{
                 org_id: org,
                 vendor_id: Ash.UUID.generate(),
                 number: "V-STR",
                 bill_date: ~D[2026-09-01],
                 lines: [%{account_id: expense.id, amount_cents: "twelve"}]
               })
               |> Ash.create(scope: scope)
    end
  end

  # ── d3: :approve rides the ADR-040 Gate ────────────────────────────────────

  describe "d3 — :approve rides the ADR-040 approvals engine" do
    test "an ungated :approve is refused with ApprovalRequired and opens a pending approval",
         %{org: org, scope: scope} do
      expense = seed_posting_accounts(org)
      bill = new_bill(scope, org, [bill_line(expense, 7_000)])

      result =
        bill
        |> Ash.Changeset.for_update(:approve, %{}, scope: scope)
        |> Ash.update()

      assert {:error, %Ash.Error.Forbidden{errors: errors}} = result
      approval = Enum.find(errors, &match?(%{__struct__: Samen.Approvals.ApprovalRequired}, &1))
      assert approval, "expected ApprovalRequired, got: #{inspect(errors)}"

      # The pending row was opened OUTSIDE the aborted write's transaction —
      # it is visible, pending, and names this bill.
      {:ok, row} =
        Samen.Approvals.get(approval.approval_id,
          approval_resource: approval_resource(),
          repo: @repo
        )
      assert row.state == :pending
      assert row.kind == Atom.to_string(ApInvoice) <> ":approve"
      assert row.subject_ref == "samen:sap:#{bill.id}"

      # The bill itself is untouched.
      reloaded = Ash.get!(ApInvoice, bill.id, authorize?: false)
      assert reloaded.status == :draft
    end

    test "SELF-approval is refused; the DISTINCT approver's decision posts the bill", %{
      org: org,
      scope: scope
    } do
      expense = seed_posting_accounts(org)
      bill = new_bill(scope, org, [bill_line(expense, 9_000)])

      {:gated, approval_id} = gate(bill, scope)

      requester_id = "u:#{org}"
      approver_id = "a2:#{org}"

      assert {:error, :self_approval} =
               Samen.Approvals.approve(approval_id, requester_id,
                 approval_resource: approval_resource(),
                 repo: @repo
               )

      # The distinct decision: the Gate re-invokes :approve AS THE REQUESTER
      # inside the decision transaction — ApPosting lands the entry there.
      assert {:ok, approved, _meta} =
               Samen.Approvals.approve(approval_id, approver_id,
                 approval_resource: approval_resource(),
                 repo: @repo
               )

      assert approved.state == :approved
      assert approved.decided_by == approver_id

      reloaded = Ash.get!(ApInvoice, bill.id, authorize?: false)
      assert reloaded.status == :approved
      assert %DateTime{} = reloaded.posted_at

      # The anchored POSTED entry exists (source_key "ap_invoice").
      entry =
        JournalEntry
        |> Ash.Query.filter(source_key == ^"ap_invoice" and source_id == ^bill.id)
        |> Ash.read_one!(authorize?: false)

      assert entry.status == :posted
      assert reloaded.posted_entry_id == entry.id

      # R1 holds: the AP entry participates in the org balance (zero).
      assert Reconcile.org_balance(org, @repo, line_resource: JournalLine) == {:ok, 0}

      # The two-sided shape: Σ line debits == Σ line credits == bill total.
      lines =
        JournalLine
        |> Ash.Query.filter(entry_id == ^entry.id)
        |> Ash.read!(authorize?: false)

      debits = Enum.sum(Enum.map(lines, & &1.debit_cents))
      credits = Enum.sum(Enum.map(lines, & &1.credit_cents))
      # (Elixir's == is left-associative — no chained comparison.)
      assert debits == credits
      assert debits == 9_000
    end
  end

  # ── d4: the one-way state machine ──────────────────────────────────────────

  describe "d4 — the approve state machine is one-way" do
    test "re-approve is refused after a decision (RED)", %{org: org, scope: scope} do
      expense = seed_posting_accounts(org)
      bill = new_bill(scope, org, [bill_line(expense, 4_000)])

      {:gated, approval_id} = gate(bill, scope)
      assert {:ok, _, _} = decide(approval_id)

      assert {:error, _} =
               Ash.get!(ApInvoice, bill.id, authorize?: false)
               |> Ash.Changeset.for_update(:approve, %{}, context: %{approval_ok: true})
               |> Ash.update(scope: scope)
    end

    test "a draft edits freely (CONTROL); an approved bill is frozen (RED)", %{
      org: org,
      scope: scope
    } do
      expense = seed_posting_accounts(org)

      draft = new_bill(scope, org, [bill_line(expense, 3_000)])

      assert %{} =
               draft
               |> Ash.Changeset.for_update(:update, %{memo: "still negotiable"}, scope: scope)
               |> Ash.update!()

      bill = new_bill(scope, org, [bill_line(expense, 3_100)])
      {:gated, approval_id} = gate(bill, scope)
      assert {:ok, _, _} = decide(approval_id)

      assert {:error, _} =
               Ash.get!(ApInvoice, bill.id, authorize?: false)
               |> Ash.Changeset.for_update(:update, %{memo: "too late"}, scope: scope)
               |> Ash.update(scope: scope)
    end
  end

  # ── d5: exactly-once receipt posting ───────────────────────────────────────

  describe "d5 — exactly-once per anchor" do
    test "a double :post_receipt is refused (RED)", %{org: org, scope: scope} do
      seed_posting_accounts(org)
      receipt = new_receipt(scope, org, Ash.UUID.generate(), 5_500)

      posted =
        receipt
        |> Ash.Changeset.for_update(:post_receipt, %{}, scope: scope)
        |> Ash.update!()

      assert posted.status == :posted

      assert {:error, _} =
               Ash.get!(PaymentReceipt, receipt.id, authorize?: false)
               |> Ash.Changeset.for_update(:post_receipt, %{}, scope: scope)
               |> Ash.update()
    end

    test "the anchor is one-per-invoice once posted (the unique belt, RED + CONTROL)", %{
      org: org,
      scope: scope
    } do
      seed_posting_accounts(org)
      invoice = Ash.UUID.generate()

      first = new_receipt(scope, org, invoice, 2_000)

      first
      |> Ash.Changeset.for_update(:post_receipt, %{}, scope: scope)
      |> Ash.update!()

      # While the first is posted, a SECOND receipt row for the same anchor
      # can still be CREATED (drafts are not anchors-yet)...
      second = new_receipt(scope, org, invoice, 2_000)

      # ...but posting it hits the unique belt: one settled receipt per
      # upstream invoice event.
      assert {:error, _} =
               second
               |> Ash.Changeset.for_update(:post_receipt, %{}, scope: scope)
               |> Ash.update()

      # CONTROL: a different anchor posts independently.
      other = new_receipt(scope, org, Ash.UUID.generate(), 2_500)

      posted_other =
        other
        |> Ash.Changeset.for_update(:post_receipt, %{}, scope: scope)
        |> Ash.update!()

      assert posted_other.status == :posted
    end
  end

  # ── d6: the receipt posting shape ──────────────────────────────────────────

  describe "d6 — :post_receipt lands the cash+AR entry in one transaction" do
    test "the anchored entry exists, is POSTED, and is linked", %{org: org, scope: scope} do
      seed_posting_accounts(org)
      receipt = new_receipt(scope, org, Ash.UUID.generate(), 15_000)

      posted =
        receipt
        |> Ash.Changeset.for_update(:post_receipt, %{}, scope: scope)
        |> Ash.update!()

      assert posted.status == :posted
      assert %DateTime{} = posted.posted_at
      assert posted.posted_entry_id

      entry = Ash.get!(JournalEntry, posted.posted_entry_id, authorize?: false)
      assert entry.status == :posted
      assert entry.source_key == "billing_payment"
      assert entry.source_id == receipt.id

      lines =
        JournalLine
        |> Ash.Query.filter(entry_id == ^entry.id)
        |> Ash.read!(authorize?: false)

      assert Enum.any?(lines, &(&1.debit_cents == 15_000))
      assert Enum.any?(lines, &(&1.credit_cents == 15_000))
      assert Reconcile.org_balance(org, @repo, line_resource: JournalLine) == {:ok, 0}
    end

    test "a posting-account-less org is refused fail-honest (RED)", %{org: org, scope: scope} do
      receipt = new_receipt(scope, org, Ash.UUID.generate(), 1_000)

      assert {:error, _} =
               receipt
               |> Ash.Changeset.for_update(:post_receipt, %{}, scope: scope)
               |> Ash.update()
    end

    test "a non-positive amount is refused (RED)", %{org: org, scope: scope} do
      seed_posting_accounts(org)

      assert {:error, %Ash.Error.Invalid{}} =
               PaymentReceipt
               |> Ash.Changeset.for_create(:create, %{
                 org_id: org,
                 invoice_key: "billing_invoice",
                 invoice_id: Ash.UUID.generate(),
                 amount_cents: 0,
                 paid_at: DateTime.utc_now() |> DateTime.truncate(:second)
               })
               |> Ash.create(scope: scope)
    end
  end

  # ── d7: R2 green ────────────────────────────────────────────────────────────

  describe "d7 — R2 green: receipts == GL == mirror" do
    test "the three sums agree over the whole ledger", %{org: org, scope: scope} do
      seed_posting_accounts(org)

      for amount <- [10_000, 2_500, 700] do
        receipt = new_receipt(scope, org, Ash.UUID.generate(), amount)

        receipt
        |> Ash.Changeset.for_update(:post_receipt, %{}, scope: scope)
        |> Ash.update!()

        new_mirror(org, amount, status: :succeeded)
      end

      assert {:ok, receipts} = ReconcilePayments.receipts_total(org, @repo, receipt_resource: PaymentReceipt)
      assert {:ok, gl} =
               ReconcilePayments.posted_cash_total(org, @repo,
                 entry_resource: JournalEntry,
                 line_resource: JournalLine
               )

      assert {:ok, mirror} = ReconcilePayments.mirror_total(org, @repo, mirror_resource: PaymentMirror)

      assert receipts == gl
      assert gl == mirror
      assert receipts == 13_200
    end

    test "a bounded period moves all three sums together", %{org: org, scope: scope} do
      seed_posting_accounts(org)

      now = DateTime.utc_now() |> DateTime.truncate(:second)
      yesterday = DateTime.add(now, -86_400)

      for {paid_when, amount} <- [{yesterday, 4_000}, {now, 1_500}] do
        receipt = new_receipt(scope, org, Ash.UUID.generate(), amount, paid_at: paid_when)

        receipt
        |> Ash.Changeset.for_update(:post_receipt, %{}, scope: scope)
        |> Ash.update!()

        new_mirror(org, amount, status: :succeeded, paid_at: paid_when)
      end

      # The window excludes only the `now` receipt (paid_at > from boundary).
      # Each leg bounds its own natural time column: the receipt/mirror legs
      # take DateTimes (paid_at), the GL leg takes DATES (entry_date — the
      # posting is dated by the receipt's date, so a date window aligns).
      moment = [from: DateTime.add(now, -3_600)]
      day = [from: Date.utc_today()]

      assert {:ok, receipts} =
               ReconcilePayments.receipts_total(org, @repo,
                 [receipt_resource: PaymentReceipt] ++ moment
               )

      assert {:ok, gl} =
               ReconcilePayments.posted_cash_total(org, @repo,
                 [entry_resource: JournalEntry, line_resource: JournalLine] ++ day
               )

      assert {:ok, mirror} =
               ReconcilePayments.mirror_total(org, @repo,
                 [mirror_resource: PaymentMirror] ++ moment
               )

      assert receipts == gl
      assert gl == mirror
      assert receipts == 1_500
    end
  end

  # ── d8: R2 anti-tautology ──────────────────────────────────────────────────

  describe "d8 — R2 anti-tautology: a bypassed receipt DIVERGES the sums" do
    test "a receipt forced below the guards breaks the equality (the sabotage simulation)",
         %{org: org, scope: scope} do
      seed_posting_accounts(org)
      receipt = new_receipt(scope, org, Ash.UUID.generate(), 8_888)

      receipt
      |> Ash.Changeset.for_update(:post_receipt, %{}, scope: scope)
      |> Ash.update!()

      # Force a SECOND, posting-less receipt into the table the way the
      # sabotage would (raw SQL with the marker — the exact bypass shape).
      marker = "samen.finance_posting"
      receipt_id = Ecto.UUID.dump!(Ash.UUID.generate())

      Ecto.Adapters.SQL.query!(
        @repo,
        """
        SELECT set_config('#{marker}', 'on', true)
        """,
        []
      )

      Ecto.Adapters.SQL.query!(
        @repo,
        """
        INSERT INTO prc_payment_receipt
          (prc_id, prc_org_id, prc_invoice_key, prc_invoice_id, prc_amount_cents,
           prc_currency, prc_paid_at, prc_status, prc_inserted_at, prc_updated_at)
        VALUES ($1, $2, 'billing_invoice', $3, 8888::bigint, 'USD',
                now() at time zone 'utc', 'draft', now() at time zone 'utc',
                now() at time zone 'utc')
        """,
        [receipt_id, Ecto.UUID.dump!(org), Ecto.UUID.dump!(Ash.UUID.generate())]
      )

      # Flip it posted below the guard (the marker is armed) so
      # receipts_total sees it: the intake WITHOUT its posting — the exact
      # sabotage shape.
      Ecto.Adapters.SQL.query!(
        @repo,
        """
        UPDATE prc_payment_receipt
        SET prc_status = 'posted'
        WHERE prc_id = $1
        """,
        [receipt_id]
      )

      Ecto.Adapters.SQL.query!(
        @repo,
        """
        SELECT set_config('#{marker}', 'off', true)
        """,
        []
      )

      assert {:ok, receipts} = ReconcilePayments.receipts_total(org, @repo, receipt_resource: PaymentReceipt)
      assert {:ok, gl} =
               ReconcilePayments.posted_cash_total(org, @repo,
                 entry_resource: JournalEntry,
                 line_resource: JournalLine
               )

      assert receipts == 17_776
      assert gl == 8_888
      assert receipts != gl, "R2 MUST diverge when a receipt bypasses its posting"
    end
  end

  # ── d9: the DB belts ───────────────────────────────────────────────────────

  describe "d9 — the DB belts refuse raw-SQL facts without the marker" do
    test "a raw-SQL posted ENTRY (insert or transition) is refused without the marker", %{
      org: org
    } do
      seed_posting_accounts(org)
      cash = account_by_code(org, "1000")
      ar = account_by_code(org, "1200")

      # Raw posted INSERT (a one-step forged fact).
      assert {:error, _} =
               Ecto.Adapters.SQL.query(
                 @repo,
                 """
                 INSERT INTO sje_journal_entry
                   (sje_id, sje_org_id, sje_entry_date, sje_status,
                    sje_inserted_at, sje_updated_at)
                 VALUES ($1, $2, current_date, 'posted', now() at time zone 'utc',
                         now() at time zone 'utc')
                 """,
                 [Ecto.UUID.dump!(Ash.UUID.generate()), Ecto.UUID.dump!(org)]
               )

      # Raw draft->posted TRANSITION (the two-step forge).
      entry = new_posted_entry(org, cash, ar, 3_000)

      assert {:error, _} =
               Ecto.Adapters.SQL.query(
                 @repo,
                 "UPDATE sje_journal_entry SET sje_status = 'posted' WHERE sje_id = $1",
                 [Ecto.UUID.dump!(entry.id)]
               )
    end

    test "a raw-SQL approved BILL transition is refused without the marker (RED)", %{
      org: org,
      scope: scope
    } do
      expense = seed_posting_accounts(org)
      bill = new_bill(scope, org, [bill_line(expense, 6_000)])

      assert {:error, _} =
               Ecto.Adapters.SQL.query(
                 @repo,
                 "UPDATE sap_ap_invoice SET sap_status = 'approved' WHERE sap_id = $1",
                 [Ecto.UUID.dump!(bill.id)]
               )
    end

    test "the marker-armed path still lands facts (CONTROL)", %{org: org, scope: scope} do
      expense = seed_posting_accounts(org)
      bill = new_bill(scope, org, [bill_line(expense, 6_400)])

      {:gated, approval_id} = gate(bill, scope)
      assert {:ok, _, _} = decide(approval_id)

      assert Ash.get!(ApInvoice, bill.id, authorize?: false).status == :approved
    end
  end

  # ── d10: cross-org ─────────────────────────────────────────────────────────

  describe "d10 — cross-org discipline" do
    test "a posting account cannot name a FOREIGN org's account (SameOrgFk RED)", %{org: org} do
      foreign_org = Ash.UUID.generate()
      foreign_scope = tenant_scope(foreign_org)
      foreign_account = new_account(foreign_scope, foreign_org, "9000")

      assert {:error, _} =
               PostingAccount
               |> Ash.Changeset.for_create(:create, %{
                 org_id: org,
                 key: :cash,
                 account_id: foreign_account.id
               })
               |> Ash.create(scope: admin_scope(org))
    end

    test "a foreign-org receipt is invisible (OrgScope RED + own-org CONTROL)", %{
      org: org,
      scope: scope
    } do
      seed_posting_accounts(org)
      foreign_org = Ash.UUID.generate()
      foreign_scope = tenant_scope(foreign_org)

      foreign = new_receipt(foreign_scope, foreign_org, Ash.UUID.generate(), 777)
      _mine = new_receipt(scope, org, Ash.UUID.generate(), 999)

      mine =
        PaymentReceipt
        |> Ash.Query.filter(org_id == ^org)
        |> Ash.read!(scope: scope)

      theirs =
        PaymentReceipt
        |> Ash.Query.filter(org_id == ^foreign_org)
        |> Ash.read!(scope: scope)

      assert length(mine) == 1
      assert theirs == []
      assert foreign.id
    end
  end

  # ── d11: catalog registration ───────────────────────────────────────────────

  describe "d11 — catalog registration (c11's E2 twin)" do
    test "every E2 fixture column has a catalog row (in isolation)", %{
      org: _org,
      scope: _scope
    } do
      {:ok, %{rows: rows}} =
        Ecto.Adapters.SQL.query(
          @repo,
          """
          SELECT c.table_name, c.column_name
          FROM information_schema.columns c
          WHERE c.table_name IN
            ('sap_ap_invoice', 'prc_payment_receipt', 'fav_posting_account',
             'sbp_payment_mirror')
          """,
          []
        )

      cataloged = fn table, column ->
        {:ok, %{rows: found}} =
          Ecto.Adapters.SQL.query(
            @repo,
            "SELECT 1 FROM fld_field WHERE fld_table_name = $1 AND fld_column_name = $2",
            [table, column]
          )

        found != []
      end

      for {table, column} <- rows do
        assert cataloged.(table, column),
               "#{table}.#{column} is not catalogued in fld_field"
      end
    end
  end

  # ── d12: no persisted inputs ───────────────────────────────────────────────

  describe "d12 — the approval row persists NO inputs (ADR-040 §4.4)" do
    test "the row carries only the bounded tuple — no lines, no amounts", %{
      org: org,
      scope: scope
    } do
      expense = seed_posting_accounts(org)
      bill = new_bill(scope, org, [bill_line(expense, 44_444, "unit-42 secret memo")])

      {:gated, approval_id} = gate(bill, scope)
      {:ok, row} =
        Samen.Approvals.get(approval_id, approval_resource: approval_resource(), repo: @repo)

      blob = inspect(Map.from_struct(row))
      refute blob =~ "44444"
      refute blob =~ "unit-42"
      refute blob =~ "amount_cents"
      assert row.subject_ref == "samen:sap:#{bill.id}"
      assert row.org_id == org
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────────

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

  defp approval_resource, do: SamenCore.Support.ApprovalsFixture.Approval

  defp seed_posting_accounts(org) do
    expense = new_account(tenant_scope(org), org, "6000")
    income = new_account(tenant_scope(org), org, "4000")

    for {key, account} <- [
          {:ap_clearing, new_account(tenant_scope(org), org, "2000")},
          {:ar_clearing, new_account(tenant_scope(org), org, "1200")},
          {:cash, new_account(tenant_scope(org), org, "1000")},
          {:income, income}
        ] do
      PostingAccount
      |> Ash.Changeset.for_create(:create, %{org_id: org, key: key, account_id: account.id},
        scope: admin_scope(org)
      )
      |> Ash.create!()
    end

    expense
  end

  defp new_account(scope, org, code, attrs \\ %{}) do
    Account
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(%{org_id: org, code: code, name: "Account #{code}", kind: :asset, normal_side: :debit}, attrs),
      scope: scope
    )
    |> Ash.create!()
  end

  defp new_bill(scope, org, lines, attrs \\ %{}) do
    ApInvoice
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(
        %{
          org_id: org,
          vendor_id: Ash.UUID.generate(),
          number: "V-" <> binary_part(Ash.UUID.generate(), 0, 8),
          bill_date: ~D[2026-09-01],
          lines: lines
        },
        Map.new(attrs)
      )
    )
    |> Ash.create!(scope: scope)
  end

  defp bill_line(account, amount, memo \\ nil),
    do: %{account_id: account.id, amount_cents: amount, memo: memo}

  defp new_receipt(scope, org, invoice_id, amount, attrs \\ %{}) do
    PaymentReceipt
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(
        %{
          org_id: org,
          invoice_key: "billing_invoice",
          invoice_id: invoice_id,
          amount_cents: amount,
          paid_at: DateTime.utc_now() |> DateTime.truncate(:second)
        },
        Map.new(attrs)
      )
    )
    |> Ash.create!(scope: scope)
  end

  defp new_mirror(org, amount, attrs) do
    PaymentMirror
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(
        %{org_id: org, amount_cents: amount, status: :succeeded},
        Map.new(attrs)
      ),
      scope: admin_scope(org)
    )
    |> Ash.create!()
  end

  # The Gate discipline: an ungated :approve fails with ApprovalRequired and
  # returns the pending approval id. NEVER a bare success — if the write
  # succeeds ungated the suite must fail loudly (the gate-never-skips control).
  defp gate(bill, scope) do
    result =
      bill
      |> Ash.Changeset.for_update(:approve, %{}, scope: scope)
      |> Ash.update()

    case result do
      {:error, %Ash.Error.Forbidden{errors: errors}} ->
        case Enum.find(errors, &match?(%{__struct__: Samen.Approvals.ApprovalRequired}, &1)) do
          nil -> flunk("expected ApprovalRequired, got: #{inspect(errors)}")
          found -> {:gated, found.approval_id}
        end

      {:ok, _} ->
        flunk("the :approve action succeeded WITHOUT the Gate — the approval discipline is broken")

      {:error, other} ->
        flunk("unexpected :approve failure: #{inspect(other)}")
    end
  end

  defp decide(approval_id) do
    Samen.Approvals.approve(approval_id, "a2:decider",
      approval_resource: approval_resource(),
      repo: @repo
    )
  end

  defp new_posted_entry(org, cash, ar, amount) do
    entry =
      JournalEntry
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: org,
          entry_date: ~D[2026-09-05],
          memo: "posted control",
          lines: [
            %{account_id: cash.id, debit_cents: amount, credit_cents: 0},
            %{account_id: ar.id, debit_cents: 0, credit_cents: amount}
          ]
        },
        scope: tenant_scope(org)
      )
      |> Ash.create!()

    entry
    |> Ash.Changeset.for_update(:post, %{}, scope: tenant_scope(org))
    |> Ash.update!()
  end

  defp account_by_code(org, code) do
    Account
    |> Ash.Query.filter(org_id == ^org and code == ^code)
    |> Ash.read_one!(authorize?: false)
  end
end
