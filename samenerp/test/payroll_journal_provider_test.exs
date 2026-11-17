defmodule Samenerp.PayrollJournalProviderTest do
  @moduledoc """
  The host-side payroll seam: a provider-computed register lands on
  `Samenerp.Erp.JournalEntry` through the configured reference importer. The
  entry is a draft and the host's normal `:post`/approval path still decides
  whether it reaches the ledger.
  """

  use Samenerp.DataCase, async: false

  require Ash.Query

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

    mapping = fn provider, external_code, account ->
      Samenerp.Erp.PayrollAccountMapping
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

    mapping.("kubeworkz_payroll", "6100", expense)
    mapping.("kubeworkz_payroll", "2110", payable)

    {:ok, org: org, scope: scope, expense: expense, payable: payable}
  end

  test "imports a provider-computed register as one host draft, even on retry", %{
    org: org
  } do
    register = %{
      provider: "kubeworkz_payroll",
      external_id: "run-2026-09",
      entry_date: ~D[2026-09-30],
      memo: "September 2026 payroll register",
      lines: [
        %{account_code: "6100", debit_cents: 240_000},
        %{account_code: "2110", credit_cents: 240_000}
      ]
    }

    assert {:ok, %{status: :ready}} =
             PayrollProvider.validate(org, register: register)

    assert {:ok, %{journal_entry_id: entry_id, total_cents: 240_000}} =
             PayrollProvider.run_payroll(org, ~D[2026-09-01],
               register: register,
               imported_by: "u:payroll-host"
             )

    assert {:ok, %{journal_entry_id: ^entry_id}} =
             PayrollProvider.run_payroll(org, ~D[2026-09-01],
               register: register,
               imported_by: "u:payroll-host"
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
    assert entry.prepared_by == "u:payroll-host"

    import =
      Samenerp.Erp.PayrollImport
      |> Ash.Query.filter(org_id == ^org and entry_id == ^entry_id)
      |> Ash.read_one!(authorize?: false)

    assert import.provider == "kubeworkz_payroll"
    assert import.external_id == "run-2026-09"
    assert import.total_cents == 240_000
    assert import.status == :imported
    assert import.imported_by == "u:payroll-host"
    assert import.entry_id == entry.id
    assert byte_size(import.line_set_hash) == 64
  end

  test "amends a posted register through the host journal's governed void path", %{
    org: org,
    scope: scope
  } do
    original_register = register(240_000)

    assert {:ok, %{journal_entry_id: original_id}} =
             PayrollProvider.run_payroll(org, ~D[2026-09-01],
               register: original_register,
               imported_by: "u:payroll-host"
             )

    original = Ash.get!(Samenerp.Erp.JournalEntry, original_id, authorize?: false)

    original =
      original
      |> Ash.Changeset.for_update(:post, %{}, scope: scope)
      |> Ash.update!()

    assert original.status == :posted

    amended = register(250_000)

    assert {:ok,
            %{
              journal_entry_id: replacement_id,
              total_cents: 250_000,
              superseded_entry_id: ^original_id
            }} =
             PayrollProvider.amend_payroll(org, ~D[2026-09-01],
               register: amended,
               imported_by: "u:payroll-host"
             )

    original = Ash.get!(Samenerp.Erp.JournalEntry, original_id, authorize?: false)
    assert original.status == :void
    assert original.voided_entry_id

    reversal = Ash.get!(Samenerp.Erp.JournalEntry, original.voided_entry_id, authorize?: false)
    assert reversal.status == :posted
    assert reversal.source_key == "journal_entry"
    assert reversal.source_id == original.id

    replacement = Ash.get!(Samenerp.Erp.JournalEntry, replacement_id, authorize?: false)
    assert replacement.status == :draft
    assert String.starts_with?(replacement.source_key, original.source_key <> ":revision:")

    original_import =
      Samenerp.Erp.PayrollImport
      |> Ash.Query.filter(org_id == ^org and entry_id == ^original_id)
      |> Ash.read_one!(authorize?: false)

    replacement_import =
      Samenerp.Erp.PayrollImport
      |> Ash.Query.filter(org_id == ^org and entry_id == ^replacement_id)
      |> Ash.read_one!(authorize?: false)

    assert original_import.status == :superseded
    assert original_import.external_id == "run-2026-09"
    assert replacement_import.status == :imported
    assert replacement_import.external_id == original_import.external_id
    assert replacement_import.supersedes_id == original_import.id
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

  defp register(total_cents) do
    %{
      provider: "kubeworkz_payroll",
      external_id: "run-2026-09",
      entry_date: ~D[2026-09-30],
      memo: "September 2026 payroll register",
      lines: [
        %{account_code: "6100", debit_cents: total_cents},
        %{account_code: "2110", credit_cents: total_cents}
      ]
    }
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
