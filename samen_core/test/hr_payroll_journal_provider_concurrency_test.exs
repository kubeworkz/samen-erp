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
  alias SamenCore.Support.FinanceFixture.{Account, JournalEntry, JournalLine}

  @repo SamenCore.TestRepo
  @source_key "payroll_register:acme_payroll:run-2026-09"

  setup_all do
    :ok = Ecto.Adapters.SQL.Sandbox.mode(@repo, :auto)

    org = Ash.UUID.generate()
    admin = admin_scope(org)
    expense = account!(admin, org, "6000", :expense, :debit)
    payable = account!(admin, org, "2100", :liability, :credit)

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
      register: register
    )
  end

  defp register(expense, payable) do
    %{
      provider: "acme_payroll",
      external_id: "run-2026-09",
      entry_date: ~D[2026-09-30],
      memo: "September 2026 payroll",
      lines: [
        %{account_id: expense.id, debit_cents: 125_000},
        %{account_id: payable.id, credit_cents: 125_000}
      ]
    }
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
    @repo.query!("DELETE FROM sjl_journal_line WHERE sjl_org_id = $1::text::uuid", [org])

    @repo.query!("DELETE FROM sje_journal_entry WHERE sje_org_id = $1::text::uuid", [org])

    @repo.query!("DELETE FROM sac_account WHERE sac_org_id = $1::text::uuid", [org])

    :ok
  end
end
