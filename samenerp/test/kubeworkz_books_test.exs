defmodule Samenerp.KubeworkzBooksTest do
  @moduledoc """
  WS-ACCT Phase 2 — the Kubeworkz books are OPEN after a seed (the phase's
  acceptance criterion), proven against the manual's own tables:

    * the chart of accounts (`1000`…`8000` + the variance family), with the
      credit-normal contra `1510` and the `1520` correction;
    * the posting map bound to those accounts, with the four variance meanings
      and `inventory_reserve` DELIBERATELY unmapped (fail-honest — the manual
      gives them no single account);
    * the four programmes, the four cost pools and the grant fund;
    * the FY budget from the manual's R&D dashboard, in cents;
    * idempotence, and the drift REPORT (a re-seed never re-points an operator's
      edit);
    * `verify/1` refutable on a bare org (the non-tautology leg);
    * the mounted ERP `:coa` surface renders the seeded chart.
  """
  use Samenerp.DataCase, async: false

  import Phoenix.ConnTest

  require Ash.Query

  alias Samenerp.Erp
  alias Samenerp.Kubeworkz.Books
  alias Samenerp.Operator, as: Op

  @endpoint SamenerpWeb.Endpoint

  defp create_org!(name) do
    Op.Org
    |> Ash.Changeset.for_create(:create, %{name: name}, authorize?: false)
    |> Ash.create!(authorize?: false)
  end

  defp accounts(org_id) do
    id = to_string(org_id)

    Erp.Account
    |> Ash.Query.filter(org_id == ^id)
    |> Ash.read!(authorize?: false)
  end

  defp posting_map(org_id) do
    id = to_string(org_id)
    accounts_by_id = Map.new(accounts(org_id), fn account -> {account.id, account.code} end)

    Erp.PostingAccount
    |> Ash.Query.filter(org_id == ^id)
    |> Ash.read!(authorize?: false)
    |> Map.new(fn row -> {row.key, Map.fetch!(accounts_by_id, row.account_id)} end)
  end

  defp account!(org_id, code) do
    id = to_string(org_id)
    code = to_string(code)

    Erp.Account
    |> Ash.Query.filter(org_id == ^id and code == ^code)
    |> Ash.read_one!(authorize?: false)
  end

  test "opens the manual's chart of accounts, contra included, in CAD" do
    org = create_org!("Kubeworkz Books CoA")
    Books.seed!(org.id)

    rows = accounts(org.id)

    assert length(rows) == length(Books.chart_of_accounts())

    # Every declared row is present exactly as the manual states it, and the
    # books are opened in the functional currency (ADR-054 D15).
    for {code, name, kind, side} <- Books.chart_of_accounts() do
      assert %{name: ^name, kind: ^kind, normal_side: ^side, currency: "CAD"} =
               account!(org.id, code)
    end

    # The credit-normal contra is expressible as-is (design §0.3): an ASSET row
    # whose normal side is credit.
    assert %{kind: :asset, normal_side: :credit} = account!(org.id, "1510")
    # The documented correction: the manual reuses 1510 for lab equipment, which
    # one unique code cannot name twice.
    assert %{kind: :asset, normal_side: :credit} = account!(org.id, "1520")
    assert %{kind: :expense} = account!(org.id, "8000")
    # The variance family the playbook posts to.
    for code <- ~w(5100 5110 5120 5130 5140 5150 5160 5170 5180 5190) do
      assert %{kind: :expense, normal_side: :debit} = account!(org.id, code)
    end
  end

  test "binds the posting map, and leaves the undecided meanings UNMAPPED" do
    org = create_org!("Kubeworkz Books Posting Map")
    Books.seed!(org.id)

    bound = posting_map(org.id)

    for {key, code} <- Books.posting_map() do
      assert bound[key] == code,
             "posting meaning #{key} should resolve to #{code}, got #{inspect(bound[key])}"
    end

    # The manual keeps ONE deferred-revenue account for both sales deferrals and
    # unearned grant awards (JE-072 credits 2200).
    assert bound[:deferred_revenue] == "2200"
    assert bound[:grant_deferred] == "2200"
    # JE-063 books lab-equipment depreciation straight to R&D prototype/test.
    assert bound[:depreciation_expense] == "6030"

    # The fail-honest posture: no row exists for a meaning the manual gives no
    # single account, so a posting that needs one REFUSES rather than posting to
    # an invented or arbitrary default.
    for {key, reason} <- Books.pending_meanings() do
      refute Map.has_key?(bound, key),
             "#{key} must stay unmapped until its owning phase decides the account"

      assert is_binary(reason) and String.length(reason) > 20,
             "#{key} needs a stated reason, not a silent omission"
    end
  end

  test "opens the four programmes, the four cost pools and the grant fund" do
    org = create_org!("Kubeworkz Books Cost Objects")
    Books.seed!(org.id)

    id = to_string(org.id)

    objects =
      Erp.CostObject
      |> Ash.Query.filter(org_id == ^id)
      |> Ash.read!(authorize?: false)

    assert length(objects) == length(Books.cost_objects())
    assert objects |> Enum.map(& &1.code) |> Enum.uniq() |> length() == length(objects)

    by_kind = Enum.group_by(objects, & &1.kind)
    assert by_kind.chip |> Enum.map(& &1.name) |> Enum.sort() == ["GPU", "PTA Photonics", "RISC-V64 SoC"]
    assert by_kind.project |> Enum.map(& &1.name) == ["PDB Development Board"]
    assert length(by_kind.cost_pool) == 4
    assert by_kind.fund |> Enum.map(& &1.code) == ["fund-grants"]
  end

  test "opens the FY budget from the manual's R&D dashboard" do
    org = create_org!("Kubeworkz Books Budget")
    Books.seed!(org.id)

    id = to_string(org.id)
    year = Books.fiscal_year()

    budget =
      Erp.Budget
      |> Ash.Query.filter(org_id == ^id and period == ^year)
      |> Ash.Query.load(:lines)
      |> Ash.read_one!(authorize?: false)

    assert budget.name == Books.budget_name()
    assert length(budget.lines) == length(Books.budget_lines())

    # The manual's §5.2 budget column, in cents, and the total it reports.
    assert Enum.sum(Enum.map(budget.lines, & &1.planned_cents)) == Books.budget_total_cents()

    codes_by_account = Map.new(accounts(org.id), fn account -> {account.id, account.code} end)

    planned =
      budget.lines
      |> Enum.map(fn line -> {Map.fetch!(codes_by_account, line.account_id), line.planned_cents} end)
      |> Enum.sort()

    expected =
      Books.budget_lines()
      |> Enum.map(fn {code, cents, _memo} -> {code, cents} end)
      |> Enum.sort()

    assert planned == expected
  end

  test "is idempotent — a second run creates nothing" do
    org = create_org!("Kubeworkz Books Idempotence")

    first = Books.seed!(org.id)
    assert first.accounts.created == length(Books.chart_of_accounts())
    assert first.posting_accounts.created == map_size(Books.posting_map())
    assert first.cost_objects.created == length(Books.cost_objects())
    assert first.budget.created

    accounts_before = length(accounts(org.id))

    second = Books.seed!(org.id)

    assert %{created: 0, existing: count} = second.accounts
    assert count == length(Books.chart_of_accounts())
    assert %{created: 0} = second.posting_accounts
    assert %{created: 0} = second.cost_objects
    refute second.budget.created

    # No duplicate rows, and the budget lines were not doubled.
    assert length(accounts(org.id)) == accounts_before
    assert %{created: 0, drifted: []} = second.posting_accounts
  end

  test "reports drift instead of re-pointing an operator's edit" do
    org = create_org!("Kubeworkz Books Drift")
    Books.seed!(org.id)

    # An operator re-points `cash` at the receivable account (a deliberate,
    # wrong-but-real edit). A re-seed must REPORT it, never silently undo it.
    id = to_string(org.id)

    cash_row =
      Erp.PostingAccount
      |> Ash.Query.filter(org_id == ^id and key == :cash)
      |> Ash.read_one!(authorize?: false)

    receivable = account!(org.id, "1100")

    cash_row
    |> Ash.Changeset.for_update(:update, %{account_id: receivable.id}, authorize?: false)
    |> Ash.update!(authorize?: false)

    summary = Books.seed!(org.id)

    assert Enum.any?(summary.posting_accounts.drifted, &String.contains?(&1, "cash"))

    # Still the operator's row, not the manual's.
    assert %{account_id: account_id} =
             Erp.PostingAccount
             |> Ash.Query.filter(org_id == ^id and key == :cash)
             |> Ash.read_one!(authorize?: false)

    assert account_id == receivable.id
  end

  test "verify/1 is refutable — a bare org fails with every gap named" do
    org = create_org!("Kubeworkz Books Verify Red")

    assert {:error, gaps} = Books.verify(org.id)

    assert Enum.any?(gaps, &String.contains?(&1, "account 1000"))
    assert Enum.any?(gaps, &String.contains?(&1, "posting meaning cash"))
    assert Enum.any?(gaps, &String.contains?(&1, "cost object gpu"))
    assert Enum.any?(gaps, &String.contains?(&1, "budget"))
    # The whole chart plus the whole map plus the objects plus the six lines.
    assert length(gaps) > length(Books.chart_of_accounts())

    Books.seed!(org.id)

    assert {:ok, %{accounts: count}} = Books.verify(org.id)
    assert count == length(Books.chart_of_accounts())
  end

  test "the books are org-scoped: one org's seed is invisible to another" do
    seeded = create_org!("Kubeworkz Books Scoped A")
    other = create_org!("Kubeworkz Books Scoped B")

    Books.seed!(seeded.id)
    Books.seed!(other.id)

    assert length(accounts(seeded.id)) == length(Books.chart_of_accounts())
    assert length(accounts(other.id)) == length(Books.chart_of_accounts())

    bare = create_org!("Kubeworkz Books Scoped C")
    assert accounts(bare.id) == []
    assert {:error, _} = Books.verify(bare.id)
  end

  describe "the ERP :coa surface" do
    setup do
      start_supervised!(SamenerpWeb.Endpoint)
      :ok
    end

    test "renders the seeded chart on the host's mounted ERP surface" do
      org = create_org!("Kubeworkz Books Surface")
      Books.seed!(org.id)

      conn = get(build_conn(), "/erp/coa?org=#{org.id}")
      assert conn.status == 200
      html = conn.resp_body

      assert html =~ "Chart of Accounts"
      # Rows rendered (the sorted-by-inserted_at page), not the honest empty state.
      refute html =~ "Nothing here yet."
      assert html =~ "/erp/coa/"

      # And what rendered is the manual's chart — at least one seeded account's
      # name is on the page. (The surface pages, so this is "some", not "all".)
      names = Enum.map(Books.chart_of_accounts(), fn {_code, name, _kind, _side} -> name end)
      assert Enum.any?(names, &String.contains?(html, &1))
    end

    test "an org whose books were never opened shows the empty state, not someone else's chart" do
      bare = create_org!("Kubeworkz Books Surface Bare")

      conn = get(build_conn(), "/erp/coa?org=#{bare.id}")
      assert conn.status == 200
      assert conn.resp_body =~ "Nothing here yet."
    end
  end
end
