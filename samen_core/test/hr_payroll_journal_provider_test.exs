defmodule Samen.Hr.PayrollJournalProviderTest do
  @moduledoc """
  The reference payroll integration: an external register becomes a DRAFT on
  the host's journal. These tests pin the three things that must not drift —
  no payroll arithmetic, no second posting path, and repeat-safe import by
  provider/external-id on the sequential retry path.
  """

  use ExUnit.Case, async: false

  require Ash.Query

  alias Samen.Hr.Payroll.JournalProvider
  alias Samen.Hr.PayrollProvider
  alias SamenCore.Support.FinanceFixture.{Account, JournalEntry, JournalLine}

  @repo SamenCore.TestRepo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(@repo)
    org = Ash.UUID.generate()
    admin = admin_scope(org)

    previous = Application.get_env(:samen_core, JournalProvider)
    Application.delete_env(:samen_core, JournalProvider)

    on_exit(fn ->
      if previous do
        Application.put_env(:samen_core, JournalProvider, previous)
      else
        Application.delete_env(:samen_core, JournalProvider)
      end
    end)

    expense = account!(admin, org, "6000", :expense, :debit)
    payable = account!(admin, org, "2100", :liability, :credit)

    {:ok, org: org, admin: admin, expense: expense, payable: payable}
  end

  test "imports a balanced external register as a draft, never as a posting", %{
    org: org,
    expense: expense,
    payable: payable
  } do
    register = register(expense, payable, %{memo: "September 2026 payroll"})

    assert {:ok, %{journal_entry_id: entry_id, total_cents: 125_000}} = run(org, register)

    entry = Ash.get!(JournalEntry, entry_id, authorize?: false)

    assert entry.status == :draft
    assert entry.entry_date == ~D[2026-09-30]
    assert entry.memo == "September 2026 payroll"
    assert entry.source_key == "payroll_register:acme_payroll:run-2026-09"

    lines = entry_lines(org, entry.id)

    assert Enum.sort(Enum.map(lines, &{&1.account_id, &1.debit_cents, &1.credit_cents})) ==
             Enum.sort([
               {expense.id, 125_000, 0},
               {payable.id, 0, 125_000}
             ])

    assert Enum.sum(Enum.map(lines, & &1.debit_cents)) ==
             Enum.sum(Enum.map(lines, & &1.credit_cents))
  end

  test "a repeated import returns the same draft and never creates a second entry", %{
    org: org,
    expense: expense,
    payable: payable
  } do
    register = register(expense, payable)

    assert {:ok, first} = run(org, register)
    assert {:ok, second} = run(org, register)

    assert first == second
    assert length(entries(org)) == 1
  end

  test "a changed total under the same external id is refused as a conflict", %{
    org: org,
    expense: expense,
    payable: payable
  } do
    assert {:ok, _first} = run(org, register(expense, payable))

    changed =
      register(expense, payable, %{
        lines: [
          %{account_id: expense.id, debit_cents: 130_000},
          %{account_id: payable.id, credit_cents: 130_000}
        ]
      })

    assert {:error, :payroll_register_conflict} = run(org, changed)
    assert length(entries(org)) == 1
  end

  test "a changed line set with the same total is refused as a conflict", %{
    org: org,
    expense: expense,
    payable: payable
  } do
    assert {:ok, _first} = run(org, register(expense, payable))

    swapped =
      register(expense, payable, %{
        lines: [
          %{account_id: payable.id, debit_cents: 125_000},
          %{account_id: expense.id, credit_cents: 125_000}
        ]
      })

    assert {:error, :payroll_register_conflict} = run(org, swapped)
    assert length(entries(org)) == 1
  end

  test "a changed entry date under the same external id is refused as a conflict", %{
    org: org,
    expense: expense,
    payable: payable
  } do
    assert {:ok, _first} = run(org, register(expense, payable))

    changed = register(expense, payable, %{entry_date: ~D[2026-10-01]})

    assert {:error, :payroll_register_conflict} = run(org, changed)
    assert length(entries(org)) == 1
  end

  test "URL-encodes colons in provider and external id so naive source keys cannot collide", %{
    org: org,
    expense: expense,
    payable: payable
  } do
    first = register(expense, payable, %{provider: "acme:payroll", external_id: "run-2026-09"})

    second =
      register(expense, payable, %{provider: "acme", external_id: "payroll:run-2026-09"})

    # The pair is deliberately chosen so a naive `provider:external_id`
    # concatenation would produce ONE key for two different runs.
    assert "payroll_register:#{first.provider}:#{first.external_id}" ==
             "payroll_register:#{second.provider}:#{second.external_id}"

    assert {:ok, %{journal_entry_id: first_entry_id}} = run(org, first)
    assert {:ok, %{journal_entry_id: second_entry_id}} = run(org, second)

    assert first_entry_id != second_entry_id

    source_keys =
      entries(org)
      |> Enum.map(& &1.source_key)
      |> Enum.sort()

    assert source_keys == [
             "payroll_register:acme%3Apayroll:run-2026-09",
             "payroll_register:acme:payroll%3Arun-2026-09"
           ]
  end

  test "refuses an unbalanced register before touching the journal", %{
    org: org,
    expense: expense,
    payable: payable
  } do
    register =
      register(expense, payable, %{
        lines: [
          %{account_id: expense.id, debit_cents: 100_000},
          %{account_id: payable.id, credit_cents: 90_000}
        ]
      })

    assert {:error, {:invalid_payroll_register, {:unbalanced, 100_000, 90_000}}} =
             run(org, register)

    assert entries(org) == []
  end

  test "refuses a line with no money side", %{org: org, expense: expense, payable: payable} do
    register =
      register(expense, payable, %{
        lines: [
          %{account_id: expense.id, debit_cents: 0},
          %{account_id: payable.id, credit_cents: 0}
        ]
      })

    assert {:error, {:invalid_payroll_register, {:one_non_zero_side, 0}}} = run(org, register)
    assert entries(org) == []
  end

  test "refuses a register without its provider identity", %{
    org: org,
    expense: expense,
    payable: payable
  } do
    register = register(expense, payable) |> Map.delete(:provider)

    assert {:error, {:invalid_payroll_register, :provider_required}} = run(org, register)
    assert entries(org) == []
  end

  test "fails honest without a register or a host entry module", %{org: org} do
    assert {:error, :payroll_register_required} =
             PayrollProvider.run_payroll(org, ~D[2026-09-01],
               provider: JournalProvider,
               entry_module: JournalEntry
             )

    assert {:error, :not_configured} =
             PayrollProvider.run_payroll(org, ~D[2026-09-01],
               provider: JournalProvider,
               register: %{
                 provider: "acme_payroll",
                 external_id: "run-2026-09",
                 entry_date: ~D[2026-09-30],
                 lines: []
               }
             )

    assert entries(org) == []
  end

  defp run(org, register) do
    PayrollProvider.run_payroll(org, ~D[2026-09-01],
      provider: JournalProvider,
      entry_module: JournalEntry,
      register: register
    )
  end

  defp register(expense, payable, overrides \\ %{}) do
    Map.merge(
      %{
        provider: "acme_payroll",
        external_id: "run-2026-09",
        entry_date: ~D[2026-09-30],
        memo: "September 2026 payroll",
        lines: [
          %{account_id: expense.id, debit_cents: 125_000},
          %{account_id: payable.id, credit_cents: 125_000}
        ]
      },
      overrides
    )
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
end
