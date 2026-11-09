defmodule Samenerp.BankingImportTest do
  @moduledoc """
  Banking statement import against the real mounted `bkl_`/`bki_` schema.

  The parser is pure and tested in `samen_core`; this test proves the governed
  `StatementLine.:import` action, the `StatementImport` audit batch, file-level
  deduplication, line-level deduplication, and transactional refusal all agree
  on the host schema.
  """

  use Samenerp.DataCase, async: false

  alias Samen.Scopes.Banking.Import
  alias Samenerp.Banking
  alias Samenerp.Erp.Account

  defmodule FailingStatementImportDomain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource(Samenerp.BankingImportTest.FailingStatementImport)
    end
  end

  defmodule FailingStatementImport do
    @moduledoc """
    Test-only stand-in for the mounted `StatementImport` whose `:create` action
    always refuses. Being an ETS resource (not the Postgres one) it fails at a
    deterministic point: after `Import.write/10` has inserted every statement
    line inside the transaction, and exactly when it tries to record the audit
    batch.
    """
    use Ash.Resource,
      domain: Samenerp.BankingImportTest.FailingStatementImportDomain,
      validate_domain_inclusion?: false,
      data_layer: Ash.DataLayer.Ets

    attributes do
      uuid_primary_key(:id)
      attribute(:org_id, :uuid, public?: true, allow_nil?: false)
      attribute(:bank_account_id, :uuid, public?: true, allow_nil?: false)
      attribute(:file_hash, :string, public?: true, allow_nil?: false)
      attribute(:filename, :string, public?: true)
      attribute(:line_count, :integer, public?: true, allow_nil?: false, default: 0)
      attribute(:duplicate_count, :integer, public?: true, allow_nil?: false, default: 0)
      attribute(:imported_at, :utc_datetime, public?: true, allow_nil?: false)
    end

    actions do
      defaults([:read])

      create :create do
        accept([
          :org_id,
          :bank_account_id,
          :file_hash,
          :filename,
          :line_count,
          :duplicate_count,
          :imported_at
        ])

        change(fn changeset, _context ->
          Ash.Changeset.add_error(changeset, "audit row insert refused by test resource")
        end)
      end
    end
  end

  setup do
    org = Ecto.UUID.generate()

    scope = %Samen.Scope{
      actor: %{id: "u:#{org}", org_id: org, role: :member, kind: :tenant, plane: :tenant}
    }

    gl =
      Account
      |> Ash.Changeset.for_create(
        :create,
        %{org_id: org, code: "1010", name: "Cash", kind: :asset, normal_side: :debit},
        authorize?: false
      )
      |> Ash.create!(authorize?: false)

    bank =
      Banking.BankAccount
      |> Ash.Changeset.for_create(
        :create,
        %{org_id: org, name: "Import Checking", account_id: gl.id},
        authorize?: false
      )
      |> Ash.create!(authorize?: false)

    {:ok, org: org, scope: scope, bank: bank}
  end

  defp import_statement(org, scope, bank, contents, filename) do
    Import.import(contents,
      line_resource: Banking.StatementLine,
      import_resource: Banking.StatementImport,
      repo: Samenerp.Repo,
      scope: scope,
      org_id: org,
      bank_account_id: bank.id,
      filename: filename
    )
  end

  defp line_count(scope) do
    Banking.StatementLine |> Ash.read!(scope: scope) |> length()
  end

  test "imports a CSV batch through the governed action", %{
    org: org,
    scope: scope,
    bank: bank
  } do
    csv = """
    Date,Amount,Description,Counterparty,Reference
    2026-10-01,-50.00,Coffee Shop,Local Cafe,TX-1
    2026-10-02,1200.00,Acme payment,Acme,INV-9
    """

    assert {:ok, %{batch: batch, lines: lines, duplicate_count: 0}} =
             import_statement(org, scope, bank, csv, "october.csv")

    assert batch.line_count == 2
    assert batch.duplicate_count == 0
    assert batch.filename == "october.csv"
    assert length(lines) == 2
    assert Enum.all?(lines, &(&1.status == :unmatched))
    assert Enum.all?(lines, &(&1.bank_account_id == bank.id))

    assert Enum.any?(lines, fn line ->
             line.amount_cents == -5_000 and line.description == "Coffee Shop" and
               line.counterparty == "Local Cafe" and line.reference == "TX-1"
           end)

    assert line_count(scope) == 2
  end

  test "refuses the same file twice", %{org: org, scope: scope, bank: bank} do
    csv = "Date,Amount,Description\n2026-10-01,-50.00,Coffee Shop\n"

    assert {:ok, %{batch: batch}} =
             import_statement(org, scope, bank, csv, "october.csv")

    assert {:error, {:duplicate_file, duplicate_id}} =
             import_statement(org, scope, bank, csv, "october.csv")

    assert duplicate_id == batch.id
    assert line_count(scope) == 1
  end

  test "skips existing and within-file duplicate lines", %{
    org: org,
    scope: scope,
    bank: bank
  } do
    first = "Date,Amount,Description\n2026-10-01,-50.00,Coffee Shop\n"
    assert {:ok, _} = import_statement(org, scope, bank, first, "one.csv")

    second = """
    Date,Amount,Description
    2026-10-01,-50.00,Coffee Shop
    2026-10-03,-25.00,New charge
    2026-10-03,-25.00,New charge
    """

    assert {:ok, %{lines: [line], duplicate_count: 2}} =
             import_statement(org, scope, bank, second, "two.csv")

    assert line.amount_cents == -2_500
    assert line.description == "New charge"
    assert line_count(scope) == 2
  end

  test "skips a repeated line hash across separate files", %{
    org: org,
    scope: scope,
    bank: bank
  } do
    first_csv = "Date,Amount,Description\n2026-10-01,-50.00,Coffee Shop\n"

    assert {:ok, %{lines: [line]}} =
             import_statement(org, scope, bank, first_csv, "first.csv")

    second_csv = """
    Date,Amount,Description
    2026-10-01,-50.00,Coffee Shop
    2026-10-03,-25.00,New charge
    """

    assert {:ok, %{batch: batch, lines: [new_line], duplicate_count: 1}} =
             import_statement(org, scope, bank, second_csv, "second.csv")

    assert batch.line_count == 1
    assert batch.duplicate_count == 1
    assert new_line.description == "New charge"
    assert line_count(scope) == 2

    persisted = Banking.StatementLine |> Ash.read!(scope: scope)
    assert Enum.any?(persisted, &(&1.id == line.id))
    assert Enum.count(persisted, &(&1.description == "Coffee Shop")) == 1
  end

  test "an invalid row refuses the whole CSV without writing a batch", %{
    org: org,
    scope: scope,
    bank: bank
  } do
    bad = """
    Date,Amount,Description
    2026-10-01,-10.00,Valid-looking first row
    not-a-date,-20.00,Broken second row
    """

    assert {:error, {:invalid_row, 3, {:invalid_date, "not-a-date"}}} =
             import_statement(org, scope, bank, bad, "bad.csv")

    assert line_count(scope) == 0
    assert Banking.StatementImport |> Ash.read!(scope: scope) == []
  end

  test "rolls back earlier lines when a later statement line insert fails", %{
    org: org,
    scope: scope,
    bank: bank
  } do
    csv = """
    Date,Amount,Description
    2026-10-01,-10.00,First row
    2026-10-02,92233720368547758.08,Overflow row
    """

    assert {:ok, %{transactions: [_, _]}} = Import.parse(csv)

    assert {:error, %Ash.Changeset{} = changeset} =
             import_statement(org, scope, bank, csv, "overflow.csv")

    assert %Ash.Resource.Actions.Create{name: :import, type: :create} = changeset.action
    assert changeset.attributes.description == "Overflow row"
    assert changeset.attributes.amount_cents == 9_223_372_036_854_775_808

    assert [%Ash.Error.Unknown.UnknownError{error: message}] = changeset.errors

    assert message =~ "DBConnection.EncodeError"
    assert message =~ "Postgrex expected an integer in -9223372036854775808..9223372036854775807"

    assert line_count(scope) == 0,
           "the first line survived the failed second-line insert"

    assert Banking.StatementImport |> Ash.read!(scope: scope) == [],
           "a batch row survived the rolled-back line insert"
  end

  test "rolls back written lines when the StatementImport audit row insert fails", %{
    org: org,
    scope: scope,
    bank: bank
  } do
    csv = """
    Date,Amount,Description
    2026-10-01,-10.00,First row
    2026-10-02,25.00,Second row
    """

    assert {:ok, %{transactions: [_, _]}} = Import.parse(csv)

    assert {:error, %Ash.Error.Invalid{changeset: %Ash.Changeset{} = changeset} = error} =
             Import.import(csv,
               line_resource: Banking.StatementLine,
               import_resource: FailingStatementImport,
               repo: Samenerp.Repo,
               scope: scope,
               org_id: org,
               bank_account_id: bank.id,
               filename: "audit-failure.csv"
             )

    # The failure is the AUDIT row, not a statement line: the changeset belongs
    # to the import resource and its :create action. `line_count` is computed
    # from the lines `insert_lines/5` already persisted in the transaction, so
    # observing 2 here proves the batch insert ran after the lines were written.
    assert changeset.resource == FailingStatementImport
    assert %Ash.Resource.Actions.Create{name: :create, type: :create} = changeset.action
    assert changeset.attributes.filename == "audit-failure.csv"

    assert changeset.attributes.line_count == 2,
           "the audit-row insert did not see both statement lines as written"

    assert [
             %Ash.Error.Changes.InvalidChanges{
               message: "audit row insert refused by test resource"
             }
           ] = error.errors

    assert line_count(scope) == 0,
           "the two statement lines survived the failed audit-row insert"

    assert Banking.StatementImport |> Ash.read!(scope: scope) == [],
           "an audit row survived its own refused insert"
  end
end
