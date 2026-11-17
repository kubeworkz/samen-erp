defmodule Samen.Hr.PayrollJournalProviderConcurrencyTest do
  @moduledoc """
  The two-importer proof for the payroll register anchor.

  The importer does not use a read-then-create check as its guarantee: it
  attempts the draft insert and recovers from the partial unique index on
  `(org_id, source_key)`. This test runs two importers on separate database
  connections, starts them together, and proves both converge on the same
  draft. Without the index the loser's insert would succeed, so the assertions
  are refutable.

  This module runs outside the SQL sandbox (`:auto`) because the two importers
  must hold independent transactions; the normal payroll suite still uses the
  sandboxed path.
  """

  use ExUnit.Case, async: false

  require Ash.Query

  alias Samen.Hr.Payroll.JournalProvider
  alias Samen.Hr.PayrollProvider

  alias SamenCore.Support.FinanceFixture.{
    Account,
    FiscalPeriod,
    JournalEntry,
    JournalLine,
    PayrollAccountMapping,
    PayrollImport,
    PayrollSettlement
  }

  @repo SamenCore.TestRepo
  @source_key "payroll_register:acme_payroll:run-2026-09"

  setup_all do
    :ok = Ecto.Adapters.SQL.Sandbox.mode(@repo, :auto)

    org = Ash.UUID.generate()
    admin = admin_scope(org)
    expense = account!(admin, org, "6000", :expense, :debit)
    payable = account!(admin, org, "2100", :liability, :credit)
    mapping!(admin, org, "acme_payroll", "6000", expense)
    mapping!(admin, org, "acme_payroll", "2100", payable)

    previous = Application.get_env(:samen_core, JournalProvider)
    Application.delete_env(:samen_core, JournalProvider)

    on_exit(fn ->
      try do
        cleanup(org)
      after
        if previous do
          Application.put_env(:samen_core, JournalProvider, previous)
        else
          Application.delete_env(:samen_core, JournalProvider)
        end

        Ecto.Adapters.SQL.Sandbox.mode(@repo, :manual)
      end
    end)

    {:ok, org: org, expense: expense, payable: payable}
  end

  test "two concurrent importers create exactly one draft", %{
    org: org,
    expense: expense,
    payable: payable
  } do
    register = register(expense, payable)
    parent = self()

    importers =
      for _ <- 1..2 do
        Task.async(fn ->
          send(parent, {:ready, self()})

          receive do
            :go -> run(org, register)
          end
        end)
      end

    ready =
      for _ <- importers do
        assert_receive {:ready, pid}, 1_000
        pid
      end

    assert MapSet.new(ready) == MapSet.new(Enum.map(importers, & &1.pid))

    Enum.each(importers, &send(&1.pid, :go))
    results = Enum.map(importers, &Task.await(&1, 10_000))

    assert [{:ok, first}, {:ok, second}] = results
    assert first == second
    assert first.total_cents == 125_000

    assert [entry] = entries(org)
    assert entry.status == :draft
    assert entry.source_key == @source_key
    assert length(entry_lines(org, entry.id)) == 2

    assert [import] = imports(org)
    assert import.entry_id == entry.id
    assert import.status == :imported
    assert import.imported_by == "u:concurrent-importer"
  end

  test "a settlement prepared while an amendment waits forces the amendment to refuse" do
    org = Ash.UUID.generate()
    admin = admin_scope(org)
    expense = account!(admin, org, "6000", :expense, :debit)
    payable = account!(admin, org, "2100", :liability, :credit)
    mapping!(admin, org, "acme_payroll", "6000", expense)
    mapping!(admin, org, "acme_payroll", "2100", payable)
    cash = account!(admin, org, "1010", :asset, :debit)
    external_id = "run-race-#{System.unique_integer([:positive])}"
    register = register(expense, payable, %{external_id: external_id})

    on_exit(fn -> cleanup(org) end)

    assert {:ok, %{journal_entry_id: original_id}} = run(org, register)
    post!(Ash.get!(JournalEntry, original_id, authorize?: false), admin)

    import =
      PayrollImport
      |> Ash.Query.filter(org_id == ^org and entry_id == ^original_id)
      |> Ash.read_one!(authorize?: false)

    parent = self()

    assert {:ok, {settlement, task}} =
             @repo.transaction(fn ->
               # Prepare holds the import row lock until this transaction commits.
               settlement = prepare!(admin, org, import, cash, ~D[2026-10-05])

               task =
                 Task.async(fn ->
                   send(parent, {:amendment_started, self()})
                   {self(), amend(org, register)}
                 end)

               assert_receive {:amendment_started, task_pid}, 1_000
               assert task_pid == task.pid

               # The amendment must be waiting on the same row lock, not racing
               # through the settlement check and voiding the original.
               assert nil == Task.yield(task, 500)

               {settlement, task}
             end)

    assert settlement.status == :draft
    assert {_pid, {:error, :payroll_settlement_exists}} = Task.await(task, 5_000)

    original = Ash.get!(JournalEntry, original_id, authorize?: false)
    assert original.status == :posted
    assert original.voided_entry_id == nil
    assert Ash.get!(PayrollSettlement, settlement.id, authorize?: false).status == :draft

    base_key = "payroll_register:acme_payroll:#{external_id}"

    related_entries =
      org
      |> entries()
      |> Enum.filter(&String.starts_with?(&1.source_key || "", base_key))

    assert [%{id: ^original_id}] = related_entries

    assert [remaining_import] =
             org
             |> imports()
             |> Enum.filter(&(&1.external_id == external_id))

    assert remaining_import.status == :imported
  end

  test "escaped payroll index constrains literal keys but allows lookalike duplicates" do
    org = Ash.UUID.generate()
    literal = "payroll_register:index-probe"
    lookalike = "payroll-register:index-probe"

    on_exit(fn ->
      @repo.query!("DELETE FROM sje_journal_entry WHERE sje_org_id = $1::text::uuid", [org])
    end)

    # The partial index matches the literal `payroll_register:` prefix: the
    # duplicate insert is skipped and only one row exists.
    assert {:ok, %{num_rows: 1}} = insert_index_probe(org, literal)
    assert {:ok, %{num_rows: 0}} = insert_index_probe(org, literal)
    assert count_index_probe(org, literal) == 1

    # `-` is not the escaped `_`: both lookalike inserts are outside the
    # partial index and must both land.
    assert {:ok, %{num_rows: 1}} = insert_index_probe(org, lookalike)
    assert {:ok, %{num_rows: 1}} = insert_index_probe(org, lookalike)
    assert count_index_probe(org, lookalike) == 2
  end

  defp run(org, register) do
    PayrollProvider.run_payroll(org, ~D[2026-09-01],
      provider: JournalProvider,
      entry_module: JournalEntry,
      import_module: PayrollImport,
      mapping_module: PayrollAccountMapping,
      period_module: FiscalPeriod,
      imported_by: "u:concurrent-importer",
      register: register
    )
  end

  defp register(_expense, _payable, overrides \\ %{}) do
    Map.merge(
      %{
        provider: "acme_payroll",
        external_id: "run-2026-09",
        entry_date: ~D[2026-09-30],
        memo: "September 2026 payroll",
        lines: [
          %{account_code: "6000", debit_cents: 125_000},
          %{account_code: "2100", credit_cents: 125_000}
        ]
      },
      overrides
    )
  end

  defp amend(org, register) do
    PayrollProvider.amend_payroll(org, ~D[2026-09-01],
      provider: JournalProvider,
      entry_module: JournalEntry,
      import_module: PayrollImport,
      mapping_module: PayrollAccountMapping,
      period_module: FiscalPeriod,
      settlement_module: PayrollSettlement,
      imported_by: "u:concurrent-importer",
      register: register
    )
  end

  defp post!(entry, scope) do
    entry
    |> Ash.Changeset.for_update(:post, %{}, scope: scope)
    |> Ash.update!()
  end

  defp prepare!(scope, org, import, cash, date) do
    PayrollSettlement
    |> Ash.Changeset.for_create(
      :prepare,
      %{
        org_id: org,
        payroll_import_id: import.id,
        cash_account_id: cash.id,
        settlement_date: date
      },
      scope: scope
    )
    |> Ash.create!()
  end

  defp admin_scope(org_id) do
    %Samen.Scope{
      actor: %{id: "u:#{org_id}", org_id: org_id, role: :admin, kind: :tenant, plane: :tenant}
    }
  end

  defp account!(scope, org, code, kind, side) do
    Account
    |> Ash.Changeset.for_create(
      :create,
      %{org_id: org, code: code, name: "Account #{code}", kind: kind, normal_side: side},
      scope: scope
    )
    |> Ash.create!()
  end

  defp mapping!(scope, org, provider, external_code, account) do
    PayrollAccountMapping
    |> Ash.Changeset.for_create(
      :create,
      %{
        org_id: org,
        provider: provider,
        external_code: external_code,
        account_id: account.id
      },
      scope: scope
    )
    |> Ash.create!()
  end

  defp entries(org) do
    JournalEntry
    |> Ash.Query.filter(org_id == ^org)
    |> Ash.read!(authorize?: false)
  end

  defp entry_lines(org, entry_id) do
    JournalLine
    |> Ash.Query.filter(org_id == ^org and entry_id == ^entry_id)
    |> Ash.read!(authorize?: false)
  end

  defp imports(org) do
    PayrollImport
    |> Ash.Query.filter(org_id == ^org)
    |> Ash.read!(authorize?: false)
  end

  defp insert_index_probe(org, source_key) do
    @repo.query(
      """
      INSERT INTO sje_journal_entry
        (sje_org_id, sje_entry_date, sje_source_key, sje_inserted_at, sje_updated_at)
      VALUES ($1::text::uuid, DATE '2026-09-30', $2,
              (CURRENT_TIMESTAMP AT TIME ZONE 'UTC'),
              (CURRENT_TIMESTAMP AT TIME ZONE 'UTC'))
      ON CONFLICT DO NOTHING
      """,
      [org, source_key]
    )
  end

  defp count_index_probe(org, source_key) do
    {:ok, %{rows: [[count]]}} =
      @repo.query(
        "SELECT count(*)::int FROM sje_journal_entry WHERE sje_org_id = $1::text::uuid AND sje_source_key = $2",
        [org, source_key]
      )

    count
  end

  defp cleanup(org) do
    # The journal's append-only belts intentionally refuse DELETE of posted
    # lines. This is test cleanup, so arm the same transaction-local marker the
    # governed posting path uses, return the org's entries to draft, then
    # remove the whole random-org fixture. The marker is transaction-local and
    # cannot leak to another test.
    {:ok, _} =
      @repo.transaction(fn ->
        @repo.query!("SELECT set_config('samen.finance_posting', 'on', true)", [])

        @repo.query!(
          "UPDATE sje_journal_entry SET sje_status = 'draft' WHERE sje_org_id = $1::text::uuid",
          [org]
        )

        @repo.query!("DELETE FROM pss_payroll_settlement WHERE pss_org_id = $1::text::uuid", [org])

        @repo.query!("DELETE FROM pfs_payroll_import WHERE pfs_org_id = $1::text::uuid", [org])
        @repo.query!("DELETE FROM sjl_journal_line WHERE sjl_org_id = $1::text::uuid", [org])

        @repo.query!("DELETE FROM sje_journal_entry WHERE sje_org_id = $1::text::uuid", [org])

        @repo.query!(
          "DELETE FROM aab_payroll_account_mapping WHERE aab_org_id = $1::text::uuid",
          [org]
        )

        @repo.query!("DELETE FROM sac_account WHERE sac_org_id = $1::text::uuid", [org])
      end)

    :ok
  end
end
