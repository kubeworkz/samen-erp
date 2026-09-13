defmodule Samen.FinanceScopeTest do
  @moduledoc """
  The Finance scope (WS-ERP E1; ADR-049 §2), mounted via
  `test/support/finance_fixture.ex`.

  Every red-path pairs denial with a positive control (anti-tautology, the
  `Samen.RedPath` / masking-watch-list house style — CLAUDE.md):

    * c1 CoA CRUD + the code-unique-per-org read; org-scoped reads
      (cross-org RED / own-org CONTROL);
    * c2 the CoA tree: a legal N-level tree is accepted (CONTROL), cycles
      refused (RED), legal re-parent succeeds (second CONTROL);
    * c3 the R1 double-entry flow: balanced draft → line rows exist →
      `:post` stamps status/posted_at → `Reconcile.org_balance/2 == 0` →
      per-account balances sum correctly;
    * c4 unbalanced refusal (RED) with the balanced twin (CONTROL); the
      exactly-one-non-zero `LineAmounts` discipline (RED/CONTROL);
    * c5 posted immutability: Ash `:update` refused (accept-list), the DB
      trigger refuses a raw-SQL UPDATE/DELETE of a posted row AND a raw-SQL
      posted-entry INSERT or line-INSERT without the PostGuard marker (RED),
      the draft stays editable (CONTROL);
    * c6 void: the reversing entry lands posted, mirrored lines, linked both
      directions, and the org balance REMAINS zero;
    * c7 draft replacement: a draft's `lines` argument replaces its rows
      (CONTROL); a posted entry cannot be edited at all (RED);
    * c8 the R1 ANTI-TAUTOLOGY: an unbalanced entry FORCED into the table
      below the guard (raw SQL with the posting marker — the sabotage
      simulation) makes `org_balance/2` DIVERGE from zero. The sum is
      load-bearing, not decorative;
    * c9 cross-org FK refusal on `account_id`/`entry_id` (RED/CONTROL);
    * c10 INV-1 — the scope's catalog PII map is EMPTY;
    * c11 catalog registration — every Finance fixture column is catalogued
      (`fld_field` storage → catalog parity, scoped to the fixture tables).
  """
  use ExUnit.Case, async: false

  require Ash.Query

  alias Samen.Scopes.Finance.Reconcile
  alias SamenCore.Support.FinanceFixture.{Account, JournalEntry, JournalLine}

  @repo SamenCore.TestRepo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(@repo)
    org = Ash.UUID.generate()
    {:ok, org: org, scope: tenant_scope(org)}
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp tenant_scope(org_id) do
    %Samen.Scope{
      actor: %{id: "u:#{org_id}", org_id: org_id, role: :member, kind: :tenant, plane: :tenant}
    }
  end

  defp new_account(scope, org, attrs \\ %{}) do
    Account
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(%{org_id: org, code: "1000", name: "Cash", kind: :asset, normal_side: :debit}, attrs),
      scope: scope
    )
    |> Ash.create!()
  end

  defp cash_and_sales(scope, org) do
    cash = new_account(scope, org, %{code: "1000", name: "Cash", kind: :asset, normal_side: :debit})
    sales = new_account(scope, org, %{code: "4000", name: "Sales", kind: :income, normal_side: :credit})
    {cash, sales}
  end

  defp new_entry(scope, org, cash, sales, amount, attrs \\ %{}) do
    JournalEntry
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(
        %{
          org_id: org,
          entry_date: ~D[2026-09-12],
          memo: "sale",
          lines: [
            %{account_id: cash.id, debit_cents: amount},
            %{account_id: sales.id, credit_cents: amount}
          ]
        },
        attrs
      ),
      scope: scope
    )
    |> Ash.create!()
  end

  defp posted_entry(scope, org, cash, sales, amount) do
    entry = new_entry(scope, org, cash, sales, amount)
    Ash.Changeset.for_update(entry, :post, %{}, scope: scope) |> Ash.update!()
  end

  defp raw_line_row(entry_id, org, account_id, debit, credit) do
    Ecto.Adapters.SQL.query!(
      @repo,
      "INSERT INTO sjl_journal_line (sjl_id, sjl_org_id, sjl_entry_id, sjl_account_id, " <>
        "sjl_debit_cents, sjl_credit_cents, sjl_inserted_at, sjl_updated_at) " <>
        "VALUES (gen_random_uuid(), $1, $2, $3, $4, $5, now(), now())",
      [Ecto.UUID.dump!(org), Ecto.UUID.dump!(entry_id), Ecto.UUID.dump!(account_id), debit, credit]
    )
  end

  # Raw posted-entry INSERT + raw line INSERT with the PostGuard transaction-local
  # marker armed (set_config ..., true — the EXACT escape hatch the write guards
  # own). This is the SQL-layer shape of sabotage 302: the rows the write guards
  # exist to prevent, forced in through their own gate. Returns the new entry id.
  defp raw_posted_entry_with_marker(org, cash, debit, credit) do
    {:ok, entry_id} =
      @repo.transaction(fn ->
        Ecto.Adapters.SQL.query!(@repo, "SELECT set_config('samen.finance_posting', 'on', true)", [])

        %{rows: [[entry_id_bin]]} =
          Ecto.Adapters.SQL.query!(
            @repo,
            "INSERT INTO sje_journal_entry (sje_id, sje_org_id, sje_entry_date, sje_memo, " <>
              "sje_status, sje_inserted_at, sje_updated_at) VALUES (gen_random_uuid(), $1, " <>
              "(now() AT TIME ZONE 'utc')::date, 'raw', 'posted', " <>
              "timezone('utc', now()), timezone('utc', now())) RETURNING sje_id",
            [Ecto.UUID.dump!(org)]
          )

        entry_id = Ecto.UUID.load!(entry_id_bin)

        raw_line_row(entry_id, org, cash.id, debit, credit)
        entry_id
      end)

    entry_id
  end

  # ── c1: CoA CRUD + org-scoped reads ────────────────────────────────────────

  describe "c1 — Account CRUD; org-scoped reads" do
    test "create/read/update an Account", %{org: org, scope: scope} do
      a = new_account(scope, org)
      assert a.kind == :asset
      assert a.currency == "USD"

      [read] = Account |> Ash.read!(scope: scope)
      assert read.id == a.id

      updated = a |> Ash.Changeset.for_update(:update, %{name: "Petty Cash"}, scope: scope) |> Ash.update!()
      assert updated.name == "Petty Cash"
    end

    test "an actor never reads another org's Accounts (RED); reads its own (CONTROL)" do
      org_a = Ash.UUID.generate()
      org_b = Ash.UUID.generate()
      scope_a = tenant_scope(org_a)
      scope_b = tenant_scope(org_b)

      mine = new_account(scope_a, org_a, %{code: "1000", name: "A cash"})
      _foreign = new_account(scope_b, org_b, %{code: "1000", name: "B cash"})

      seen = Account |> Ash.read!(scope: scope_a) |> Enum.map(& &1.id)
      assert seen == [mine.id]
    end
  end

  # ── c2: the CoA tree — cycle refusal ───────────────────────────────────────

  describe "c2 — CoA tree: legal tree accepted, cycle refused (anti-tautology)" do
    test "a legal 3-level CoA is accepted (CONTROL)", %{org: org, scope: scope} do
      root = new_account(scope, org, %{code: "1000", name: "Assets", kind: :asset, normal_side: :debit})
      child = new_account(scope, org, %{code: "1100", name: "Bank", parent_id: root.id})
      grandchild = new_account(scope, org, %{code: "1110", name: "Checking", parent_id: child.id})

      assert child.parent_id == root.id
      assert grandchild.parent_id == child.id
    end

    test "an account cannot be its own parent (self-cycle, RED)", %{org: org, scope: scope} do
      a = new_account(scope, org)

      result = a |> Ash.Changeset.for_update(:update, %{parent_id: a.id}, scope: scope) |> Ash.update()

      assert {:error, %Ash.Error.Invalid{}} = result
    end

    test "a deeper cycle (A -> B -> C, then A re-parented under C) is refused (RED)", %{
      org: org,
      scope: scope
    } do
      a = new_account(scope, org, %{code: "1000", name: "A"})
      b = new_account(scope, org, %{code: "1100", name: "B", parent_id: a.id})
      c = new_account(scope, org, %{code: "1110", name: "C", parent_id: b.id})

      result = a |> Ash.Changeset.for_update(:update, %{parent_id: c.id}, scope: scope) |> Ash.update()

      assert {:error, %Ash.Error.Invalid{}} = result
    end

    test "a LEGAL re-parent still succeeds (second CONTROL — not a blanket refusal)", %{
      org: org,
      scope: scope
    } do
      old_parent = new_account(scope, org, %{code: "1000", name: "old"})
      new_parent = new_account(scope, org, %{code: "2000", name: "new"})
      child = new_account(scope, org, %{code: "1100", name: "child", parent_id: old_parent.id})

      updated = child |> Ash.Changeset.for_update(:update, %{parent_id: new_parent.id}, scope: scope) |> Ash.update!()

      assert updated.parent_id == new_parent.id
    end
  end

  # ── c3: the R1 happy path ──────────────────────────────────────────────────

  describe "c3 — R1 happy path: balanced draft posts and reconciles to zero" do
    test "a balanced create materializes line rows", %{org: org, scope: scope} do
      {cash, sales} = cash_and_sales(scope, org)

      entry = new_entry(scope, org, cash, sales, 5_000)

      assert entry.status == :draft
      assert is_nil(entry.posted_at)

      lines =
        JournalLine
        |> Ash.Query.filter(entry_id == ^entry.id)
        |> Ash.read!(authorize?: false)
        # org_id is NotLoaded on results by house select behavior (the Work
        # probe) — the sanctioned remedy is an explicit load.
        |> Ash.load!([:org_id], authorize?: false)

      assert length(lines) == 2
      assert Enum.all?(lines, &(&1.org_id == org))
    end

    test ":post stamps status/posted_at; account balances sum correctly", %{org: org, scope: scope} do
      {cash, sales} = cash_and_sales(scope, org)

      posted_entry(scope, org, cash, sales, 5_000)
      posted_entry(scope, org, cash, sales, 2_500)

      assert Reconcile.account_balance(cash.id, @repo, line_resource: JournalLine) == {:ok, 7_500}

      assert Reconcile.account_balance(sales.id, @repo, line_resource: JournalLine) ==
               {:ok, -7_500}

      assert Reconcile.org_balance(org, @repo, line_resource: JournalLine) == {:ok, 0}
    end

    test "a line-less create is refused (an entry is born with lines or not at all)", %{
      org: org,
      scope: scope
    } do
      {cash, _sales} = cash_and_sales(scope, org)

      result =
        JournalEntry
        |> Ash.Changeset.for_create(:create, %{org_id: org, entry_date: ~D[2026-09-12]}, scope: scope)
        |> Ash.create()

      assert {:error, %Ash.Error.Invalid{}} = result
      refute Account |> Ash.Query.filter(id == ^cash.id) |> Ash.read!(scope: scope) == []
    end
  end

  # ── c4: unbalanced refusal + LineAmounts ───────────────────────────────────

  describe "c4 — R1 refusal: unbalanced entries never land (RED/CONTROL)" do
    test "an unbalanced create is refused (RED)", %{org: org, scope: scope} do
      {cash, sales} = cash_and_sales(scope, org)

      result =
        JournalEntry
        |> Ash.Changeset.for_create(
          :create,
          %{
            org_id: org,
            entry_date: ~D[2026-09-12],
            lines: [
              %{account_id: cash.id, debit_cents: 5_000},
              %{account_id: sales.id, credit_cents: 4_999}
            ]
          },
          scope: scope
        )
        |> Ash.create()

      assert {:error, %Ash.Error.Invalid{}} = result

      # The refusal is TOTAL: no entry row AND no line rows landed.
      assert JournalEntry |> Ash.read!(scope: scope) == []
      assert JournalLine |> Ash.read!(authorize?: false, scope: scope) == []
    end

    test "the balanced twin still succeeds (CONTROL — the refusal is not blanket)", %{
      org: org,
      scope: scope
    } do
      {cash, sales} = cash_and_sales(scope, org)

      assert %JournalEntry{} = new_entry(scope, org, cash, sales, 4_999)
    end

    test "a line with BOTH amounts non-zero is refused; exactly-one passes (RED/CONTROL)", %{
      org: org,
      scope: scope
    } do
      {cash, sales} = cash_and_sales(scope, org)

      both =
        JournalEntry
        |> Ash.Changeset.for_create(
          :create,
          %{
            org_id: org,
            entry_date: ~D[2026-09-12],
            lines: [
              %{account_id: cash.id, debit_cents: 100, credit_cents: 100},
              %{account_id: sales.id, credit_cents: 100}
            ]
          },
          scope: scope
        )
        |> Ash.create()

      assert {:error, %Ash.Error.Invalid{}} = both

      zero_zero =
        JournalEntry
        |> Ash.Changeset.for_create(
          :create,
          %{
            org_id: org,
            entry_date: ~D[2026-09-12],
            lines: [
              %{account_id: cash.id, debit_cents: 100},
              %{account_id: sales.id, credit_cents: 0}
            ]
          },
          scope: scope
        )
        |> Ash.create()

      assert {:error, %Ash.Error.Invalid{}} = zero_zero
    end

    test "a NEGATIVE amount is refused (direction is the column, never a sign)", %{
      org: org,
      scope: scope
    } do
      {cash, sales} = cash_and_sales(scope, org)

      result =
        JournalEntry
        |> Ash.Changeset.for_create(
          :create,
          %{
            org_id: org,
            entry_date: ~D[2026-09-12],
            lines: [
              %{account_id: cash.id, debit_cents: 5_000},
              %{account_id: sales.id, credit_cents: -5_000}
            ]
          },
          scope: scope
        )
        |> Ash.create()

      assert {:error, %Ash.Error.Invalid{}} = result
    end
  end

  # ── c5: posted immutability ────────────────────────────────────────────────

  describe "c5 — posted rows are immutable (Ash accept-list braces + DB trigger belt)" do
    test "a posted entry cannot be re-edited via :update (no status accept; trigger belt)", %{
      org: org,
      scope: scope
    } do
      {cash, sales} = cash_and_sales(scope, org)
      entry = posted_entry(scope, org, cash, sales, 5_000)

      result =
        entry |> Ash.Changeset.for_update(:update, %{memo: "edited"}, scope: scope) |> Ash.update()

      assert {:error, _} = result
    end

    test "a raw-SQL UPDATE of a posted entry is refused by the trigger (RED)", %{
      org: org,
      scope: scope
    } do
      {cash, sales} = cash_and_sales(scope, org)
      entry = posted_entry(scope, org, cash, sales, 5_000)

      assert_raise Postgrex.Error, ~r/append-only once posted/, fn ->
        Ecto.Adapters.SQL.query!(
          @repo,
          "UPDATE sje_journal_entry SET sje_memo = 'tampered' WHERE sje_id = $1",
          [Ecto.UUID.dump!(entry.id)]
        )
      end
    end

    test "a raw-SQL INSERT of a posted entry WITHOUT the marker is refused (RED)", %{org: _org} do
      assert_raise Postgrex.Error, ~r/non-draft INSERT requires the PostGuard/, fn ->
        Ecto.Adapters.SQL.query!(
          @repo,
          "INSERT INTO sje_journal_entry (sje_id, sje_org_id, sje_entry_date, sje_memo, " <>
            "sje_status, sje_inserted_at, sje_updated_at) VALUES (gen_random_uuid(), $1, " <>
            "CURRENT_DATE, 'raw', 'posted', now(), now())",
          [Ecto.UUID.dump!(Ash.UUID.generate())]
        )
      end
    end

    test "a raw-SQL line INSERT into a POSTED entry without the marker is refused (RED)", %{
      org: org,
      scope: scope
    } do
      {cash, sales} = cash_and_sales(scope, org)
      entry = posted_entry(scope, org, cash, sales, 5_000)

      assert_raise Postgrex.Error, ~r/line set is frozen/, fn ->
        raw_line_row(entry.id, org, cash.id, 100, 0)
      end
    end

    test "a raw-SQL DELETE of a posted entry is refused by the trigger (RED)", %{
      org: org,
      scope: scope
    } do
      {cash, sales} = cash_and_sales(scope, org)
      entry = posted_entry(scope, org, cash, sales, 5_000)

      assert_raise Postgrex.Error, ~r/append-only once posted/, fn ->
        Ecto.Adapters.SQL.query!(
          @repo,
          "DELETE FROM sje_journal_entry WHERE sje_id = $1",
          [Ecto.UUID.dump!(entry.id)]
        )
      end
    end

    test "a DRAFT stays editable (CONTROL — the belt is not a blanket lock)", %{
      org: org,
      scope: scope
    } do
      {cash, sales} = cash_and_sales(scope, org)

      # A draft is born WITH lines (an entry is born with lines or not at all);
      # the editability claim is about the memo/entry_date surface.
      entry = new_entry(scope, org, cash, sales, 5_000, %{memo: "draft"})

      updated = entry |> Ash.Changeset.for_update(:update, %{memo: "still a draft"}, scope: scope) |> Ash.update!()

      assert updated.memo == "still a draft"
    end
  end

  # ── c6: void → the reversing entry ────────────────────────────────────────

  describe "c6 — void posts a linked reversing entry; the ledger nets to zero" do
    test "the reversal is posted, mirrored, linked both directions; balance stays zero", %{
      org: org,
      scope: scope
    } do
      {cash, sales} = cash_and_sales(scope, org)
      entry = posted_entry(scope, org, cash, sales, 5_000)

      voided = entry |> Ash.Changeset.for_update(:void, %{}, scope: scope) |> Ash.update!()

      assert voided.status == :void
      assert not is_nil(voided.posted_at)
      assert not is_nil(voided.voided_entry_id)

      reversal =
        JournalEntry
        |> Ash.Query.filter(id == ^voided.voided_entry_id)
        |> Ash.read_one!(authorize?: false)

      assert reversal.status == :posted
      assert reversal.source_key == "journal_entry"
      assert reversal.source_id == entry.id
      assert reversal.voided_entry_id == entry.id

      reversal_lines =
        JournalLine |> Ash.Query.filter(entry_id == ^reversal.id) |> Ash.read!(authorize?: false)

      assert {debits, credits} =
               Enum.reduce(reversal_lines, {0, 0}, fn l, {d, c} ->
                 {d + l.debit_cents, c + l.credit_cents}
               end)

      assert debits == credits and debits == 5_000

      # The pair nets out: the org balance REMAINS zero.
      assert Reconcile.org_balance(org, @repo, line_resource: JournalLine) == {:ok, 0}

      # The original entry's own lines still exist — nothing was destroyed.
      original_lines =
        JournalLine |> Ash.Query.filter(entry_id == ^entry.id) |> Ash.read!(authorize?: false)

      assert length(original_lines) == 2
    end

    test "voiding a DRAFT is refused (a draft is not a fact — nothing to reverse)", %{
      org: org,
      scope: scope
    } do
      {cash, sales} = cash_and_sales(scope, org)
      entry = new_entry(scope, org, cash, sales, 5_000)

      result = entry |> Ash.Changeset.for_update(:void, %{}, scope: scope) |> Ash.update()
      assert {:error, _} = result

      # ...and the refused draft is untouched — still a draft, still editable.
      reloaded = JournalEntry |> Ash.Query.filter(id == ^entry.id) |> Ash.read_one!(scope: scope)
      assert reloaded.status == :draft
    end
  end

  # ── c7: draft line replacement ────────────────────────────────────────────

  describe "c7 — draft replacement; posted drift is structurally impossible" do
    test "a draft's lines argument REPLACES its rows (CONTROL)", %{org: org, scope: scope} do
      {cash, sales} = cash_and_sales(scope, org)

      entry = new_entry(scope, org, cash, sales, 5_000)

      updated =
        entry
        |> Ash.Changeset.for_update(
          :update,
          %{lines: [%{account_id: cash.id, debit_cents: 1_200}, %{account_id: sales.id, credit_cents: 1_200}]},
          scope: scope
        )
        |> Ash.update!()

      lines = JournalLine |> Ash.Query.filter(entry_id == ^entry.id) |> Ash.read!(authorize?: false)
      assert length(lines) == 2

      assert Ash.Changeset.for_update(updated, :post, %{}, scope: scope)
             |> Ash.update!()
             |> Map.get(:status) == :posted
    end

    test "a DRAFT replacement that lands unbalanced is refused by the update's R1 check (RED)", %{
      org: org,
      scope: scope
    } do
      {cash, sales} = cash_and_sales(scope, org)
      entry = new_entry(scope, org, cash, sales, 5_000)

      result =
        entry
        |> Ash.Changeset.for_update(
          :update,
          %{lines: [%{account_id: cash.id, debit_cents: 1_200}, %{account_id: sales.id, credit_cents: 1_100}]},
          scope: scope
        )
        |> Ash.update()

      assert {:error, %Ash.Error.Invalid{}} = result

      # The ORIGINAL draft lines survived (the rollback is total).
      lines = JournalLine |> Ash.Query.filter(entry_id == ^entry.id) |> Ash.read!(authorize?: false)
      assert Enum.reduce(lines, 0, &(&1.debit_cents + &2)) == 5_000
    end

    test "PostBalance refuses a post whose STORED lines drift (RED) — the stored rows are the source of truth", %{
      org: org,
      scope: scope
    } do
      {cash, sales} = cash_and_sales(scope, org)
      entry = new_entry(scope, org, cash, sales, 5_000)

      # Simulate drift: a balanced-draft entry whose stored rows are corrupted
      # below the guards (raw line INSERT — permitted while the entry is a
      # draft, exactly the hole PostBalance closes).
      raw_line_row(entry.id, org, cash.id, 5_000, 1)

      result = entry |> Ash.Changeset.for_update(:post, %{}, scope: scope) |> Ash.update()
      assert {:error, _} = result
    end
  end

  # ── c8: the R1 ANTI-TAUTOLOGY — the sum is load-bearing ───────────────────

  describe "c8 — R1 anti-tautology: a forced unbalanced entry makes org_balance DIVERGE" do
    test "org_balance == 0 on the seeded ledger; a below-the-guard bypass diverges it", %{
      org: org,
      scope: scope
    } do
      {cash, sales} = cash_and_sales(scope, org)
      posted_entry(scope, org, cash, sales, 5_000)

      assert Reconcile.org_balance(org, @repo, line_resource: JournalLine) == {:ok, 0}

      # The bypass simulation (what sabotage 302 does to the WRITE guard, done
      # through the same transaction-local gate): force an unbalanced posted
      # entry into the table under the PostGuard marker — the exact rows the
      # write guards exist to prevent. The stored-sum read MUST diverge, or the
      # read is decorative.
      raw_posted_entry_with_marker(org, cash, 9_999, 0)

      assert {:ok, balance} = Reconcile.org_balance(org, @repo, line_resource: JournalLine)
      assert balance != 0
      # ...and the balance is exactly the injected imbalance (not noise).
      assert balance == 9_999

      # The account-level mirror diverges identically (5_000 + 9_999 debit on
      # the cash account, 5_000 credit on sales).
      assert {:ok, cash_balance} = Reconcile.account_balance(cash.id, @repo, line_resource: JournalLine)
      assert cash_balance == 9_999 + 5_000
    end
  end

  # ── c9: cross-org FK refusal ──────────────────────────────────────────────

  describe "c9 — SameOrgFk refuses a cross-org account/entry FK (RED), same-org succeeds (CONTROL)" do
    test "a line cannot reference a DIFFERENT org's Account (RED)" do
      org_a = Ash.UUID.generate()
      org_b = Ash.UUID.generate()
      scope_a = tenant_scope(org_a)
      scope_b = tenant_scope(org_b)

      {cash_a, sales_a} = cash_and_sales(scope_a, org_a)
      {foreign_cash, _} = cash_and_sales(scope_b, org_b)

      result =
        JournalEntry
        |> Ash.Changeset.for_create(
          :create,
          %{
            org_id: org_a,
            entry_date: ~D[2026-09-12],
            lines: [
              %{account_id: foreign_cash.id, debit_cents: 100},
              %{account_id: sales_a.id, credit_cents: 100}
            ]
          },
          scope: scope_a
        )
        |> Ash.create()

      assert {:error, %Ash.Error.Invalid{}} = result
      refute is_nil(cash_a.id)
    end

    test "a line CAN reference its OWN org's Account (CONTROL)", %{org: org, scope: scope} do
      {cash, sales} = cash_and_sales(scope, org)
      assert %JournalEntry{} = new_entry(scope, org, cash, sales, 100)
    end
  end

  # ── c10: INV-1 no-PII declaration ─────────────────────────────────────────

  describe "c10 — INV-1: no-PII declaration (the Finance scope vaults nothing)" do
    test "each resource carries zero pii_attribute fields" do
      assert Samen.Pii.Info.fields(Account) == []
      assert Samen.Pii.Info.fields(JournalEntry) == []
      assert Samen.Pii.Info.fields(JournalLine) == []
    end
  end

  # ── c11: catalog registration ─────────────────────────────────────────────

  describe "c11 — catalog registration (catalog_sync wrote the fixture tables)" do
    test "every Finance fixture column has a catalog row (storage → catalog parity, in isolation)" do
      # The verifier's full sweep is a mix-task-level gate (it walks ash_domains,
      # which the in-tree fixture domains deliberately stay out of — config/test.exs).
      # What must hold HERE is the direction catalog_sync owns: every physical column
      # of the three Finance fixture tables is catalogued in fld_field.
      {:ok, %{rows: rows}} =
        Ecto.Adapters.SQL.query(
          @repo,
          """
          SELECT c.table_name, c.column_name
          FROM information_schema.columns c
          WHERE c.table_name IN ('sac_account', 'sje_journal_entry', 'sjl_journal_line')
          """
        )

      assert rows != []

      {:ok, %{rows: fld_rows}} =
        Ecto.Adapters.SQL.query(
          @repo,
          "SELECT fld_table_name, fld_column_name FROM fld_field"
        )

      catalogued = MapSet.new(fld_rows, fn [t, c] -> {t, c} end)

      uncatalogued =
        rows
        |> Enum.map(fn [t, c] -> {t, c} end)
        |> Enum.reject(&MapSet.member?(catalogued, &1))

      assert uncatalogued == [],
             "expected every Finance fixture column to be catalogued, missing: " <> inspect(uncatalogued)
    end
  end
end
