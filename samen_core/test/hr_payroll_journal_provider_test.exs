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
  alias Samen.Scopes.Finance.PayrollCloseCheck

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

    for provider <- ~w(acme_payroll acme:payroll acme manual_control) do
      mapping!(admin, org, provider, "6000", expense)
      mapping!(admin, org, provider, "2100", payable)
    end

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

  test "records durable provenance for the imported register", %{
    org: org,
    expense: expense,
    payable: payable
  } do
    register = register(expense, payable)

    assert {:ok, %{journal_entry_id: entry_id}} = run(org, register)

    import =
      PayrollImport
      |> Ash.Query.filter(org_id == ^org and entry_id == ^entry_id)
      |> Ash.read_one!(authorize?: false)

    expected_hash =
      JournalProvider.line_set_hash([
        %{
          account_id: expense.id,
          debit_cents: 125_000,
          credit_cents: 0,
          memo: nil,
          dimension_refs: %{}
        },
        %{
          account_id: payable.id,
          debit_cents: 0,
          credit_cents: 125_000,
          memo: nil,
          dimension_refs: %{}
        }
      ])

    assert import.provider == "acme_payroll"
    assert import.external_id == "run-2026-09"
    assert import.entry_date == ~D[2026-09-30]
    assert import.total_cents == 125_000
    assert import.line_set_hash == expected_hash
    assert byte_size(import.line_set_hash) == 64
    assert import.status == :imported
    assert import.imported_by == "u:payroll-importer"
    assert %DateTime{} = import.imported_at
  end

  test "line-set hash is stable across line and dimension key order", %{
    expense: expense,
    payable: payable
  } do
    first = [
      %{
        account_id: expense.id,
        debit_cents: 125_000,
        credit_cents: 0,
        memo: "payroll",
        dimension_refs: %{project: "p1", cost_pool: "c1"}
      },
      %{
        account_id: payable.id,
        debit_cents: 0,
        credit_cents: 125_000,
        memo: nil,
        dimension_refs: %{}
      }
    ]

    second = [
      %{
        account_id: payable.id,
        debit_cents: 0,
        credit_cents: 125_000,
        memo: nil,
        dimension_refs: %{}
      },
      %{
        account_id: expense.id,
        debit_cents: 125_000,
        credit_cents: 0,
        memo: "payroll",
        dimension_refs: %{"cost_pool" => "c1", "project" => "p1"}
      }
    ]

    assert JournalProvider.line_set_hash(first) == JournalProvider.line_set_hash(second)
  end

  test "a repeated import returns the same draft and record and never creates a second entry", %{
    org: org,
    expense: expense,
    payable: payable
  } do
    register = register(expense, payable)

    assert {:ok, first} = run(org, register)
    assert {:ok, second} = run(org, register)

    assert first == second
    assert length(entries(org)) == 1
    assert length(imports(org)) == 1
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
          %{account_code: "6000", debit_cents: 130_000},
          %{account_code: "2100", credit_cents: 130_000}
        ]
      })

    assert {:error, :payroll_register_conflict} = run(org, changed)
    assert length(entries(org)) == 1

    conflict = Enum.find(imports(org), &(&1.status == :conflict))
    assert conflict != nil
    assert conflict.entry_id == List.first(entries(org)).id
    assert conflict.total_cents == 130_000
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
          %{account_code: "2100", debit_cents: 125_000},
          %{account_code: "6000", credit_cents: 125_000}
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

  test "amends a posted register by voiding the original and importing a replacement draft", %{
    org: org,
    admin: admin,
    expense: expense,
    payable: payable
  } do
    original_register = register(expense, payable)
    assert {:ok, %{journal_entry_id: original_id}} = run(org, original_register)

    original = post!(Ash.get!(JournalEntry, original_id, authorize?: false), admin)
    assert original.status == :posted

    amended =
      register(expense, payable, %{
        lines: [
          %{account_code: "6000", debit_cents: 130_000},
          %{account_code: "2100", credit_cents: 130_000}
        ]
      })

    # The old path still refuses the changed register; amendment is the guided
    # correction after that conflict, and the conflict row remains as history.
    assert {:error, :payroll_register_conflict} = run(org, amended)

    assert {:ok,
            %{
              journal_entry_id: replacement_id,
              total_cents: 130_000,
              superseded_entry_id: ^original_id,
              superseded_import_id: superseded_import_id
            }} = amend(org, amended)

    original = Ash.get!(JournalEntry, original_id, authorize?: false)
    assert original.status == :void
    assert original.voided_entry_id

    reversal = Ash.get!(JournalEntry, original.voided_entry_id, authorize?: false)
    assert reversal.status == :posted
    assert reversal.source_key == "journal_entry"
    assert reversal.source_id == original.id
    assert reversal.entry_date == original.entry_date

    replacement = Ash.get!(JournalEntry, replacement_id, authorize?: false)
    assert replacement.status == :draft
    assert replacement.entry_date == ~D[2026-09-30]
    assert String.starts_with?(replacement.source_key, original.source_key <> ":revision:")
    assert sum_debits(org, replacement.id) == 130_000

    imports = imports(org)

    original_import = Enum.find(imports, &(&1.id == superseded_import_id))
    replacement_import = Enum.find(imports, &(&1.entry_id == replacement_id))

    assert original_import.entry_id == original_id
    assert original_import.status == :superseded
    assert original_import.external_id == "run-2026-09"
    assert original_import.supersedes_id == nil

    assert replacement_import.status == :imported
    assert replacement_import.provider == "acme_payroll"
    assert replacement_import.external_id == original_import.external_id
    assert replacement_import.supersedes_id == original_import.id
    assert replacement_import.line_set_hash != original_import.line_set_hash

    conflict_import =
      Enum.find(
        imports,
        &(&1.line_set_hash == replacement_import.line_set_hash and &1.status == :superseded)
      )

    assert conflict_import.entry_id == original_id
    assert conflict_import.id != original_import.id
    assert length(imports) == 3

    post!(replacement, admin)

    assert %{status: :clear} =
             PayrollCloseCheck.report(org, %{year: 2026, month: 9}, import_module: PayrollImport)
  end

  test "refuses to amend a draft target without voiding anything", %{
    org: org,
    expense: expense,
    payable: payable
  } do
    assert {:ok, %{journal_entry_id: original_id}} = run(org, register(expense, payable))

    amended =
      register(expense, payable, %{
        lines: [
          %{account_code: "6000", debit_cents: 130_000},
          %{account_code: "2100", credit_cents: 130_000}
        ]
      })

    assert {:error, :payroll_register_not_posted} = amend(org, amended)

    assert Ash.get!(JournalEntry, original_id, authorize?: false).status == :draft
    assert length(entries(org)) == 1
    assert length(imports(org)) == 1
  end

  test "refuses to amend a register that has a posted settlement, preserving its cash leg", %{
    org: org,
    admin: admin,
    expense: expense,
    payable: payable
  } do
    cash = account!(admin, org, "1010", :asset, :debit)
    assert {:ok, %{journal_entry_id: original_id}} = run(org, register(expense, payable))
    post!(Ash.get!(JournalEntry, original_id, authorize?: false), admin)

    original_import =
      PayrollImport
      |> Ash.Query.filter(org_id == ^org and entry_id == ^original_id)
      |> Ash.read_one!(authorize?: false)

    settlement =
      PayrollSettlement
      |> Ash.Changeset.for_create(
        :prepare,
        %{
          org_id: org,
          payroll_import_id: original_import.id,
          cash_account_id: cash.id,
          settlement_date: ~D[2026-10-05]
        },
        scope: admin
      )
      |> Ash.create!()

    settlement =
      settlement
      |> Ash.Changeset.for_update(:post, %{}, scope: admin)
      |> Ash.update!()

    assert settlement.status == :posted

    amended = register(expense, payable, %{lines: payroll_lines(130_000)})

    assert {:error, :payroll_settlement_exists} = amend(org, amended)

    original = Ash.get!(JournalEntry, original_id, authorize?: false)
    assert original.status == :posted
    assert original.voided_entry_id == nil
    assert Ash.get!(PayrollSettlement, settlement.id, authorize?: false).status == :posted
    assert length(entries(org)) == 2
    assert length(imports(org)) == 1
  end

  test "refuses an unchanged amendment without writing a second revision", %{
    org: org,
    admin: admin,
    expense: expense,
    payable: payable
  } do
    register = register(expense, payable)
    assert {:ok, %{journal_entry_id: original_id}} = run(org, register)
    post!(Ash.get!(JournalEntry, original_id, authorize?: false), admin)

    assert {:error, :payroll_register_unchanged} = amend(org, register)
    assert length(entries(org)) == 1
    assert length(imports(org)) == 1
  end

  test "finishes the supersedes link after a partial amendment retry", %{
    org: org,
    admin: admin,
    expense: expense,
    payable: payable
  } do
    assert {:ok, %{journal_entry_id: original_id}} = run(org, register(expense, payable))
    post!(Ash.get!(JournalEntry, original_id, authorize?: false), admin)

    amended = register(expense, payable, %{lines: payroll_lines(130_000)})
    assert {:ok, %{journal_entry_id: replacement_id}} = amend(org, amended)

    original_import = Enum.find(imports(org), &(&1.entry_id == original_id))
    assert original_import.status == :superseded
    original_import_id = original_import.id

    # Simulate a crash after the replacement landed but before the original's
    # status write. The retry must finish the chain, not report "unchanged".
    @repo.query!(
      "UPDATE pfs_payroll_import SET pfs_status = 'imported', pfs_imported_at = now() - interval '1 hour' WHERE pfs_id = $1::text::uuid",
      [original_import.id]
    )

    assert {:ok,
            %{
              journal_entry_id: ^replacement_id,
              superseded_entry_id: ^original_id,
              superseded_import_id: ^original_import_id
            }} = amend(org, amended)

    assert Ash.get!(PayrollImport, original_import.id, authorize?: false).status == :superseded
    assert length(entries(org)) == 3
    assert length(imports(org)) == 2
  end

  test "chains multiple revisions while preserving the external id and original entry", %{
    org: org,
    admin: admin,
    expense: expense,
    payable: payable
  } do
    assert {:ok, %{journal_entry_id: first_id}} = run(org, register(expense, payable))
    post!(Ash.get!(JournalEntry, first_id, authorize?: false), admin)

    second = register(expense, payable, %{lines: payroll_lines(130_000)})
    assert {:ok, %{journal_entry_id: second_id}} = amend(org, second)
    post!(Ash.get!(JournalEntry, second_id, authorize?: false), admin)

    third = register(expense, payable, %{lines: payroll_lines(140_000)})
    assert {:ok, %{journal_entry_id: third_id}} = amend(org, third)

    first = Ash.get!(JournalEntry, first_id, authorize?: false)
    second_entry = Ash.get!(JournalEntry, second_id, authorize?: false)
    third_entry = Ash.get!(JournalEntry, third_id, authorize?: false)

    assert first.status == :void
    assert second_entry.status == :void
    assert third_entry.status == :draft
    assert first.source_key == "payroll_register:acme_payroll:run-2026-09"
    assert String.starts_with?(second_entry.source_key, first.source_key <> ":revision:")
    assert String.starts_with?(third_entry.source_key, first.source_key <> ":revision:")
    assert second_entry.source_key != third_entry.source_key

    imports = imports(org)
    first_import = Enum.find(imports, &(&1.entry_id == first_id))
    second_import = Enum.find(imports, &(&1.entry_id == second_id))
    third_import = Enum.find(imports, &(&1.entry_id == third_id))

    assert first_import.status == :superseded
    assert second_import.status == :superseded
    assert third_import.status == :imported
    assert first_import.external_id == second_import.external_id
    assert second_import.external_id == third_import.external_id
    assert first_import.supersedes_id == nil
    assert second_import.supersedes_id == first_import.id
    assert third_import.supersedes_id == second_import.id
    assert length(imports) == 3
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

  test "refuses a PII-shaped header memo before any GL or provenance row lands", %{
    org: org,
    expense: expense,
    payable: payable
  } do
    register =
      register(expense, payable, %{
        memo: "Payroll for jane.doe@example.com"
      })

    assert {:error, {:invalid_payroll_register, {:pii_memo, :memo, :email}}} =
             run(org, register)

    assert entries(org) == []
    assert journal_lines(org) == []
    assert imports(org) == []
  end

  test "keeps ordinary payroll prose without a name-taking context", %{
    org: org,
    expense: expense,
    payable: payable
  } do
    register = register(expense, payable, %{memo: "Payroll Reversal"})

    assert {:ok, %{journal_entry_id: entry_id}} = run(org, register)

    entry = Ash.get!(JournalEntry, entry_id, authorize?: false)
    assert entry.memo == "Payroll Reversal"
  end

  test "refuses a bare-name memo before any GL or provenance row lands", %{
    org: org,
    expense: expense,
    payable: payable
  } do
    register =
      register(expense, payable, %{
        memo: "Payroll for Jane Doe"
      })

    assert {:error, {:invalid_payroll_register, {:pii_memo, :memo, :bare_name}}} =
             run(org, register)

    assert entries(org) == []
    assert journal_lines(org) == []
    assert imports(org) == []
  end

  test "keeps ordinary words after a name-taking preposition", %{
    org: org,
    expense: expense,
    payable: payable
  } do
    for memo <- ["Payroll for audit", "Payroll for off-cycle"] do
      register =
        register(expense, payable, %{
          external_id: "run-#{Ash.UUID.generate()}",
          memo: memo
        })

      assert {:ok, %{journal_entry_id: entry_id}} = run(org, register)
      assert Ash.get!(JournalEntry, entry_id, authorize?: false).memo == memo
    end
  end

  test "refuses lowercase and all-caps bare-name memos before any GL row lands", %{
    org: org,
    expense: expense,
    payable: payable
  } do
    for memo <- ["Payroll for jane doe", "Payroll for JANE DOE"] do
      assert {:error, {:invalid_payroll_register, {:pii_memo, :memo, :bare_name}}} =
               run(org, register(expense, payable, %{memo: memo}))
    end

    assert entries(org) == []
    assert journal_lines(org) == []
    assert imports(org) == []
  end

  test "refuses a PII-shaped line memo before any GL or provenance row lands", %{
    org: org,
    expense: expense,
    payable: payable
  } do
    register =
      register(expense, payable, %{
        lines: [
          %{account_code: "6000", debit_cents: 125_000, memo: "employee: Jane Doe"},
          %{account_code: "2100", credit_cents: 125_000}
        ]
      })

    assert {:error, {:invalid_payroll_register, {:pii_memo, {:line_memo, 0}, :employee_name}}} =
             run(org, register)

    assert entries(org) == []
    assert journal_lines(org) == []
    assert imports(org) == []
  end

  test "refuses an unbalanced register before touching the journal", %{
    org: org,
    expense: expense,
    payable: payable
  } do
    register =
      register(expense, payable, %{
        lines: [
          %{account_code: "6000", debit_cents: 100_000},
          %{account_code: "2100", credit_cents: 90_000}
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
          %{account_code: "6000", debit_cents: 100},
          %{account_code: "2100", credit_cents: 100},
          %{account_code: "6000", debit_cents: 0, credit_cents: 0}
        ]
      })

    assert {:error, {:invalid_payroll_register, {:one_non_zero_side, 2}}} = run(org, register)
    assert entries(org) == []
  end

  test "refuses a zero-total register before touching the journal", %{
    org: org,
    expense: expense,
    payable: payable
  } do
    register =
      register(expense, payable, %{
        lines: [
          %{account_code: "6000", debit_cents: 0},
          %{account_code: "2100", credit_cents: 0}
        ]
      })

    assert {:error, {:invalid_payroll_register, :zero_total}} = run(org, register)
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
               entry_module: JournalEntry,
               import_module: PayrollImport,
               mapping_module: PayrollAccountMapping,
               period_module: FiscalPeriod
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

  describe "validate/2 preflight" do
    test "reports ready, resolves external codes, and writes nothing", %{
      org: org,
      expense: expense,
      payable: payable
    } do
      register = register(expense, payable)

      assert {:ok, report} = validate(org, register)
      assert report.status == :ready
      assert report.total_cents == 125_000
      assert report.line_set_hash == JournalProvider.line_set_hash(report.lines)

      assert Enum.sort(Enum.map(report.lines, &{&1.account_id, &1.debit_cents, &1.credit_cents})) ==
               Enum.sort([{expense.id, 125_000, 0}, {payable.id, 0, 125_000}])

      assert entries(org) == []
      assert imports(org) == []

      assert {:ok, %{journal_entry_id: _entry_id}} = run(org, register)
    end

    test "resolves the same external code per provider, not globally", %{
      org: org,
      admin: admin,
      expense: expense,
      payable: payable
    } do
      mapping!(admin, org, "swapped_provider", "6000", payable)
      mapping!(admin, org, "swapped_provider", "2100", expense)

      register =
        register(expense, payable, %{
          provider: "swapped_provider"
        })

      assert {:ok, %{status: :ready, lines: lines}} = validate(org, register)

      actual = Enum.map(lines, &{&1.account_id, &1.debit_cents, &1.credit_cents})
      assert actual == [{payable.id, 125_000, 0}, {expense.id, 0, 125_000}]

      assert entries(org) == []
      assert imports(org) == []
    end

    test "refuses missing mapping coverage before any write", %{
      org: org,
      expense: expense,
      payable: payable
    } do
      register =
        register(expense, payable, %{
          lines: [
            %{account_code: "6000", debit_cents: 125_000},
            %{account_code: "9999", credit_cents: 125_000}
          ]
        })

      assert {:error, {:payroll_preflight_failed, errors}} = validate(org, register)

      assert Enum.any?(errors, fn error ->
               error.code == :mapping_missing and error.external_code == "9999"
             end)

      assert entries(org) == []
      assert imports(org) == []
    end

    test "refuses a mapped account owned by another org", %{
      org: org,
      admin: admin,
      expense: expense,
      payable: payable
    } do
      foreign_org = Ash.UUID.generate()
      foreign_admin = admin_scope(foreign_org)
      foreign_account = account!(foreign_admin, foreign_org, "6000", :expense, :debit)

      mapping!(admin, org, "foreign_provider", "2100", payable)

      @repo.query!(
        """
        INSERT INTO aab_payroll_account_mapping
          (aab_provider, aab_external_code, aab_org_id, aab_account_id, aab_inserted_at, aab_updated_at)
        VALUES ($1, $2, $3::text::uuid, $4::text::uuid, now(), now())
        """,
        ["foreign_provider", "6000", org, foreign_account.id]
      )

      register =
        register(expense, payable, %{
          provider: "foreign_provider",
          lines: [
            %{account_code: "6000", debit_cents: 125_000},
            %{account_code: "2100", credit_cents: 125_000}
          ]
        })

      assert {:error, {:payroll_preflight_failed, errors}} = validate(org, register)
      assert Enum.any?(errors, &(&1.code == :account_cross_org))
      assert entries(org) == []
      assert imports(org) == []
    end

    test "refuses closed and document-refusing soft-closed periods", %{
      org: org,
      admin: admin,
      expense: expense,
      payable: payable
    } do
      closed_period = period!(admin, org, 2026, 9)
      close!(closed_period, admin)

      assert {:error, {:payroll_preflight_failed, [%{code: :period_closed}]}} =
               validate(org, register(expense, payable))

      soft_period = period!(admin, org, 2026, 10)
      soft_close!(soft_period, admin)

      assert {:error, {:payroll_preflight_failed, [%{code: :period_soft_closed}]}} =
               validate(
                 org,
                 register(expense, payable, %{entry_date: ~D[2026-10-01]})
               )

      assert entries(org) == []
      assert imports(org) == []
    end

    test "reports duplicate/conflict status without writing conflict provenance", %{
      org: org,
      expense: expense,
      payable: payable
    } do
      register = register(expense, payable)

      assert {:ok, %{status: :ready}} = validate(org, register)
      assert {:ok, %{journal_entry_id: entry_id}} = run(org, register)

      assert {:ok, %{status: :duplicate, existing_entry_id: ^entry_id}} =
               validate(org, register)

      assert length(imports(org)) == 1

      changed =
        register(expense, payable, %{
          lines: [
            %{account_code: "6000", debit_cents: 130_000},
            %{account_code: "2100", credit_cents: 130_000}
          ]
        })

      assert {:ok, %{status: :conflict, existing_entry_id: ^entry_id}} = validate(org, changed)

      # validate/2 is write-free: the conflict provenance row appears only when
      # run_payroll/3 actually attempts the import.
      assert length(imports(org)) == 1
      assert {:error, :payroll_register_conflict} = run(org, changed)
      assert length(imports(org)) == 2
    end

    test "refuses malformed lines and zero-total registers before any write", %{
      org: org,
      expense: expense,
      payable: payable
    } do
      malformed =
        register(expense, payable, %{
          lines: [
            %{debit_cents: 125_000},
            %{account_code: "2100", credit_cents: 125_000}
          ]
        })

      assert {:error, {:invalid_payroll_register, {:account_code_required, 0}}} =
               validate(org, malformed)

      zero =
        register(expense, payable, %{
          lines: [
            %{account_code: "6000", debit_cents: 0},
            %{account_code: "2100", credit_cents: 0}
          ]
        })

      assert {:error, {:invalid_payroll_register, :zero_total}} = validate(org, zero)
      assert entries(org) == []
      assert imports(org) == []
    end
  end

  describe "org isolation" do
    test "PayrollImport reads and creates are org-scoped (RED) with owning-org CONTROL", %{
      org: org,
      expense: expense,
      payable: payable
    } do
      own_scope = Samen.RedPath.actor_scope(org, :admin)
      foreign_org = Ash.UUID.generate()
      foreign_scope = Samen.RedPath.actor_scope(foreign_org, :admin)

      assert {:ok, %{journal_entry_id: own_entry_id}} = run(org, register(expense, payable))
      assert [own_import] = imports(org)
      assert own_import.entry_id == own_entry_id

      # CONTROL: the owning org can read its provenance row through the real
      # authorizer (the denial below is OrgScope, not a broken read).
      assert [read] =
               PayrollImport
               |> Ash.Query.select([:id, :org_id])
               |> Ash.Query.filter(id == ^own_import.id)
               |> Ash.read!(scope: own_scope)

      assert read.org_id == org

      # RED: another org's actor cannot see the row. OrgScope is a filter, so
      # the foreign row is invisible rather than leaking its existence.
      assert [] =
               PayrollImport
               |> Ash.Query.filter(id == ^own_import.id)
               |> Ash.read!(scope: foreign_scope)

      # A second draft gives the direct-create controls a real linked entry.
      assert {:ok, %{journal_entry_id: second_entry_id}} =
               run(
                 org,
                 register(expense, payable, %{
                   provider: "manual_control",
                   external_id: "entry-for-create"
                 })
               )

      attrs = %{
        org_id: org,
        provider: "manual_import",
        external_id: "manual-1",
        line_set_hash: String.duplicate("b", 64),
        total_cents: 100,
        entry_date: ~D[2026-09-30],
        imported_at: DateTime.utc_now() |> DateTime.truncate(:second),
        imported_by: "u:manual-import",
        status: :imported,
        entry_id: second_entry_id
      }

      # CONTROL: the owning org can create a provenance row through the real
      # create policy, linked to its own draft.
      assert {:ok, created} =
               PayrollImport
               |> Ash.Changeset.for_create(:create, attrs, scope: own_scope)
               |> Ash.create()

      assert [created_read] =
               PayrollImport
               |> Ash.Query.select([:id, :org_id, :entry_id])
               |> Ash.Query.filter(id == ^created.id)
               |> Ash.read!(scope: own_scope)

      assert created_read.org_id == org
      assert created_read.entry_id == second_entry_id

      # RED: a foreign-org actor cannot create a row in the owning org. The
      # OrgScope create policy forbids it, and no row may land.
      forged = %{attrs | external_id: "manual-foreign"}

      assert {:error, %Ash.Error.Forbidden{}} =
               PayrollImport
               |> Ash.Changeset.for_create(:create, forged, scope: foreign_scope)
               |> Ash.create()

      assert [] =
               PayrollImport
               |> Ash.Query.filter(external_id == "manual-foreign")
               |> Ash.read!(authorize?: false)
    end
  end

  defp run(org, register) do
    PayrollProvider.run_payroll(org, ~D[2026-09-01],
      provider: JournalProvider,
      entry_module: JournalEntry,
      import_module: PayrollImport,
      mapping_module: PayrollAccountMapping,
      period_module: FiscalPeriod,
      imported_by: "u:payroll-importer",
      register: register
    )
  end

  defp validate(org, register) do
    JournalProvider.validate(org,
      entry_module: JournalEntry,
      import_module: PayrollImport,
      mapping_module: PayrollAccountMapping,
      period_module: FiscalPeriod,
      register: register
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
      imported_by: "u:payroll-importer",
      register: register
    )
  end

  defp post!(entry, scope) do
    entry
    |> Ash.Changeset.for_update(:post, %{}, scope: scope)
    |> Ash.update!()
  end

  defp payroll_lines(total_cents) do
    [
      %{account_code: "6000", debit_cents: total_cents},
      %{account_code: "2100", credit_cents: total_cents}
    ]
  end

  defp sum_debits(org, entry_id) do
    org
    |> entry_lines(entry_id)
    |> Enum.sum_by(& &1.debit_cents)
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

  defp period!(scope, org, year, month) do
    FiscalPeriod
    |> Ash.Changeset.for_create(
      :create,
      %{org_id: org, year: year, month: month},
      scope: scope
    )
    |> Ash.create!()
  end

  defp close!(period, scope) do
    period
    |> Ash.Changeset.for_update(:close, %{}, scope: scope)
    |> Ash.update!()
  end

  defp soft_close!(period, scope) do
    period
    |> Ash.Changeset.for_update(:soft_close, %{}, scope: scope)
    |> Ash.update!()
  end

  defp entries(org) do
    JournalEntry
    |> Ash.Query.filter(org_id == ^org)
    |> Ash.read!(authorize?: false)
  end

  defp imports(org) do
    PayrollImport
    |> Ash.Query.filter(org_id == ^org)
    |> Ash.read!(authorize?: false)
  end

  defp entry_lines(org, entry_id) do
    JournalLine
    |> Ash.Query.filter(org_id == ^org and entry_id == ^entry_id)
    |> Ash.read!(authorize?: false)
  end

  defp journal_lines(org) do
    JournalLine
    |> Ash.Query.filter(org_id == ^org)
    |> Ash.read!(authorize?: false)
  end
end
