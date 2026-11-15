defmodule Samenerp.PayrollJournalProviderTest do
  @moduledoc """
  The host-side payroll seam: a provider-computed register lands on
  `Samenerp.Erp.JournalEntry` through the configured reference importer. The
  entry is a draft and the host's normal `:post`/approval path still decides
  whether it reaches the ledger.
  """

  use Samenerp.DataCase, async: false

  require Ash.Query

  alias Samen.Hr.Payroll.JournalProvider
  alias Samen.Hr.PayrollProvider

  setup do
    org = Ecto.UUID.generate()

    scope = %Samen.Scope{
      actor: %{id: "a:#{org}", org_id: org, role: :admin, kind: :tenant, plane: :tenant}
    }

    expense =
      Samenerp.Erp.Account
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: org,
          code: "6100",
          name: "Payroll expense",
          kind: :expense,
          normal_side: :debit
        },
        scope: scope
      )
      |> Ash.create!()

    payable =
      Samenerp.Erp.Account
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: org,
          code: "2110",
          name: "Payroll payable",
          kind: :liability,
          normal_side: :credit
        },
        scope: scope
      )
      |> Ash.create!()

    {:ok, org: org, expense: expense, payable: payable}
  end

  test "imports a provider-computed register as a host draft", %{
    org: org,
    expense: expense,
    payable: payable
  } do
    register = %{
      provider: "kubeworkz_payroll",
      external_id: "run-2026-09",
      entry_date: ~D[2026-09-30],
      memo: "September 2026 payroll register",
      lines: [
        %{account_id: expense.id, debit_cents: 240_000},
        %{account_id: payable.id, credit_cents: 240_000}
      ]
    }

    assert {:ok, %{journal_entry_id: entry_id, total_cents: 240_000}} =
             PayrollProvider.run_payroll(org, ~D[2026-09-01],
               provider: JournalProvider,
               register: register
             )

    entry =
      Samenerp.Erp.JournalEntry
      |> Ash.Query.filter(id == ^entry_id)
      |> Ash.Query.ensure_selected([:org_id, :status, :source_key, :entry_date])
      |> Ash.read_one!(authorize?: false)

    assert entry.org_id == org
    assert entry.status == :draft
    assert entry.source_key == "payroll_register:kubeworkz_payroll:run-2026-09"
    assert entry.entry_date == ~D[2026-09-30]
  end
end
