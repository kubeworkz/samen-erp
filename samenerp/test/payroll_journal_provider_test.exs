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

  test "imports a provider-computed register as one host draft, even on retry", %{
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

    assert {:ok, %{journal_entry_id: ^entry_id}} =
             PayrollProvider.run_payroll(org, ~D[2026-09-01],
               provider: JournalProvider,
               register: register
             )

    entries =
      Samenerp.Erp.JournalEntry
      |> Ash.Query.filter(org_id == ^org)
      |> Ash.Query.ensure_selected([:org_id, :status, :source_key, :entry_date])
      |> Ash.read!(authorize?: false)

    assert [entry] = entries
    assert entry.org_id == org
    assert entry.status == :draft
    assert entry.source_key == "payroll_register:kubeworkz_payroll:run-2026-09"
    assert entry.entry_date == ~D[2026-09-30]
  end

  test "escaped payroll index constrains literal keys but allows lookalike duplicates" do
    org = Ecto.UUID.generate()
    literal = "payroll_register:index-probe"
    lookalike = "payroll-register:index-probe"

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

  defp insert_index_probe(org, source_key) do
    Repo.query(
      """
      INSERT INTO ecj_journal_entry
        (ecj_org_id, ecj_entry_date, ecj_source_key, ecj_inserted_at, ecj_updated_at)
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
      Repo.query(
        "SELECT count(*)::int FROM ecj_journal_entry WHERE ecj_org_id = $1::text::uuid AND ecj_source_key = $2",
        [org, source_key]
      )

    count
  end
end
