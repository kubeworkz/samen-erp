defmodule Samen.FinanceVarianceTest do
  @moduledoc """
  WS-ACCT Phase 7 (ADR-054 D4) — standard costing and the variance layer,
  mounted via `test/support/finance_fixture.ex`.

  Every refusal is paired with a positive control (`Samen.RedPath` discipline):

    * v1 all seven classes compute exactly from one card (PPV, yield, BOM,
      labour rate/efficiency, overhead spending/volume);
    * v2 every variance lands on the account the manual's per-type table names —
      yield/BOM absorb into the two finished-goods accounts, PPV/OH volume write
      off to COGS, labour/OH spending write off to R&D;
    * v3 each entry is balanced, anchored, dated the period's last day and
      carries the card's cost-object dimension on BOTH legs (R6);
    * v4 R8 green: every row ties to the in-force card, the arithmetic, the
      entry legs and the family Σ rows == Σ GL;
    * v5 R8 red: a hand-inserted row whose posting pays a different account,
      and an orphaned anchored entry, are DETECTED (the anti-tautology leg);
    * v6 the card in force: a revised card does not price the periods the old
      one governs (the red path sabotage 407 removes);
    * v7 exactly-once: a second run is a clean no-op, the row is append-only,
      and a MEASURED-zero period still records its marker;
    * v8 fail-honest: a card line with no actual refuses the whole run;
    * v9 the reads: the variance report shows all seven classes (labour
      labelled as declared until the Phase 10 driver) and cost of yield derives
      from the card + the absorbed variance.
  """
  use ExUnit.Case, async: false

  require Ash.Query

  alias Samen.Scopes.Finance.{CostOfYield, ReconcileVariance, VarianceReport}

  alias SamenCore.Support.FinanceFixture.{
    Account,
    CostObject,
    CostStandard,
    CostStandardLine,
    CostVariance,
    FiscalPeriod,
    JournalEntry,
    JournalLine,
    PostingAccount
  }

  @repo SamenCore.TestRepo
  @period "2026-03"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(@repo)
    org = Ash.UUID.generate()

    {:ok, org: org, admin: admin_scope(org), tenant: tenant_scope(org)}
  end

  # ── v1: the seven classes ─────────────────────────────────────────────────

  test "all seven variance classes compute exactly from the card", %{org: org, admin: admin} do
    ctx = books!(admin, org)
    card = card!(admin, org, ctx.cost_object)

    lines = card_lines!(admin, org, card)

    assert {:ok, _} = run(admin, card, @period, actuals(lines))

    by_type = by_type(org, @period)

    # material A: BOM, 210 consumed vs 200 allowed, at 1 000 cents → 10 000
    # material B: yield 80 %, 140 consumed vs ceil(100·1/0.8)=125 → 15·5 000
    # PPV: (1 100−1 000)·210 + (4 800−5 000)·140 = 21 000 − 28 000 = −7 000
    assert by_type.ppv.amount_cents == -7_000
    assert by_type.bom.amount_cents == 10_000
    assert by_type.yield.amount_cents == 75_000

    # labour: (105−100)·3 100 = 15 500; (3 100−3 000)·100 = 10 000
    assert by_type.labor_rate.amount_cents == 15_500
    assert by_type.labor_efficiency.amount_cents == 10_000

    # overhead: 3 100·(195−200) = −15 500; (3 100−3 000)·200 = 20 000
    assert by_type.overhead_spending.amount_cents == -15_500
    assert by_type.overhead_volume.amount_cents == 20_000

    assert map_size(by_type) == 7

    for {_type, row} <- by_type do
      assert row.amount_cents == row.actual_amount_cents - row.standard_amount_cents
    end
  end

  # ── v2: the disposition table ─────────────────────────────────────────────

  test "every variance reaches the account the manual's table names", %{
    org: org,
    admin: admin
  } do
    ctx = books!(admin, org)
    card = card!(admin, org, ctx.cost_object)
    lines = card_lines!(admin, org, card)

    assert {:ok, _} = run(admin, card, @period, actuals(lines))

    by_type = by_type(org, @period)

    # absorb into inventory
    assert by_type.yield.disposition == :absorb_inventory
    assert by_type.yield.disposition_account_id == ctx.chip.id
    assert by_type.bom.disposition == :absorb_inventory
    assert by_type.bom.disposition_account_id == ctx.board.id

    # write off to COGS
    assert by_type.ppv.disposition == :write_off_cogs
    assert by_type.ppv.disposition_account_id == ctx.cogs.id
    assert by_type.overhead_volume.disposition == :write_off_cogs
    assert by_type.overhead_volume.disposition_account_id == ctx.cogs.id

    # write off to R&D
    for type <- [:labor_rate, :labor_efficiency, :overhead_spending] do
      assert by_type[type].disposition == :write_off_rd
      assert by_type[type].disposition_account_id == ctx.rd.id
    end

    # the four FAMILY variance accounts
    assert by_type.ppv.variance_account_id == ctx.variance_ppv.id
    assert by_type.yield.variance_account_id == ctx.variance_yield.id
    assert by_type.bom.variance_account_id == ctx.variance_yield.id
    assert by_type.labor_rate.variance_account_id == ctx.variance_labor.id
    assert by_type.overhead_spending.variance_account_id == ctx.variance_overhead.id
  end

  # ── v3: the entry ─────────────────────────────────────────────────────────

  test "each entry is anchored, dated inside the period and dimensioned on both legs", %{
    org: org,
    admin: admin
  } do
    ctx = books!(admin, org)
    card = card!(admin, org, ctx.cost_object)
    lines = card_lines!(admin, org, card)

    assert {:ok, _} = run(admin, card, @period, actuals(lines))

    rows = rows(org, @period)
    assert length(rows) == 7

    for row <- rows do
      [entry] = entries(org) |> Enum.filter(&(&1.id == row.entry_id))

      assert entry.source_key == "cost_variance"
      assert entry.source_id == row.id
      assert entry.entry_date == ~D[2026-03-31]
      assert entry.status == :posted

      entry_lines = entry_lines(org, entry.id)
      assert length(entry_lines) == 2

      # R6: both legs carry the card's cost-object dimension.
      assert Enum.all?(entry_lines, fn line ->
               line.dimension_refs["project"] == ctx.cost_object.id
             end)

      assert Enum.sum(Enum.map(entry_lines, & &1.debit_cents)) ==
               Enum.sum(Enum.map(entry_lines, & &1.credit_cents))
    end

    # The BOM variance is unfavourable: Dr the board FG account, Cr variance_yield.
    # (The yield row's own target is asserted in the disposition test, so the
    # two tests fail for independent reasons.)
    bom_row = by_type(org, @period).bom
    bom_lines = entry_lines(org, bom_row.entry_id)

    assert Enum.any?(bom_lines, fn line ->
             line.account_id == ctx.board.id and line.debit_cents == 10_000
           end)

    assert Enum.any?(bom_lines, fn line ->
             line.account_id == ctx.variance_yield.id and line.credit_cents == 10_000
           end)
  end

  # ── v4/v5: R8 ─────────────────────────────────────────────────────────────

  test "R8 green: rows tie to the in-force card and the families match the GL", %{
    org: org,
    admin: admin
  } do
    ctx = books!(admin, org)
    card = card!(admin, org, ctx.cost_object)
    lines = card_lines!(admin, org, card)

    assert {:ok, _} = run(admin, card, @period, actuals(lines))

    report = ReconcileVariance.report(org, @period, r8_opts())

    assert report.ok?, inspect(report.violations)
    assert length(report.variances) == 7
    assert Enum.all?(report.variances, & &1.ok?)
    assert Enum.all?(report.families, & &1.agrees?)

    families = Map.new(report.families, &{&1.variance_account_id, &1})

    assert families[ctx.variance_yield.id].rows_cents == 85_000
    assert families[ctx.variance_yield.id].gl_cents == 85_000
    assert families[ctx.variance_labor.id].rows_cents == 25_500
    assert families[ctx.variance_overhead.id].rows_cents == 4_500
    assert families[ctx.variance_ppv.id].rows_cents == -7_000
  end

  test "R8 red: a mis-disposed row and an orphaned entry are DETECTED", %{
    org: org,
    admin: admin
  } do
    ctx = books!(admin, org)
    card = card!(admin, org, ctx.cost_object)
    lines = card_lines!(admin, org, card)
    assert {:ok, _} = run(admin, card, @period, actuals(lines))

    # A hand-inserted row that NAMES the chip FG account (the correct policy
    # target) but is backed by an entry that pays COGS — the row and its
    # posting disagree, which R8 must catch independently of the policy table
    # (the table itself is pinned by the disposition test). April has no engine
    # run, so the row does not collide with the exactly-once index.
    entry = anchored_entry!(admin, org, ~D[2026-04-30], ctx.cogs, ctx.variance_yield, 5_000)
    row_id = Ash.UUID.generate()

    insert_variance!(%{
      id: row_id,
      org: org,
      period: "2026-04",
      type: "yield",
      amount: 5_000,
      actual: 105_000,
      standard: 100_000,
      standard_id: card.id,
      cost_object_id: ctx.cost_object.id,
      variance_account_id: ctx.variance_yield.id,
      disposition: "absorb_inventory",
      disposition_account_id: ctx.chip.id,
      entry_id: entry.id
    })

    # An anchored entry with NO row at all.
    orphan = anchored_entry!(admin, org, ~D[2026-04-30], ctx.cogs, ctx.variance_yield, 1_000)

    report = ReconcileVariance.report(org, "2026-04", r8_opts())

    refute report.ok?
    assert Enum.any?(report.violations, &match?({:legs, ^row_id, _, _}, &1))
    assert Enum.any?(report.violations, &match?({:orphaned_gl, _}, &1))

    assert Enum.any?(report.violations, fn
             {:orphaned_gl, entry_id} -> entry_id == orphan.id
             _ -> false
           end)
  end

  # ── v6: the card in force ────────────────────────────────────────────────

  test "a revised card does not price a period it does not govern", %{
    org: org,
    admin: admin
  } do
    ctx = books!(admin, org)
    v1 = card!(admin, org, ctx.cost_object, %{code: "STD-V1", effective_on: ~D[2026-01-01]})
    lines_v1 = card_lines!(admin, org, v1)

    v2 = card!(admin, org, ctx.cost_object, %{code: "STD-V2", effective_on: ~D[2026-05-01]})
    lines_v2 = card_lines!(admin, org, v2)

    # June is governed by v2: v1 must be refused.
    assert {:error, changeset} = run(admin, v1, "2026-06", actuals(lines_v1))
    assert inspect(changeset.errors) =~ "not the card in force"

    # ...and the positive control: v2 prices June.
    assert {:ok, _} = run(admin, v2, "2026-06", actuals(lines_v2))

    assert ReconcileVariance.report(org, "2026-06", r8_opts()).ok?

    # March (before v2) is still governed by v1.
    assert {:ok, _} = run(admin, v1, @period, actuals(lines_v1))
    assert ReconcileVariance.report(org, @period, r8_opts()).ok?
  end

  # ── v7: exactly once ─────────────────────────────────────────────────────

  test "a second run is a clean no-op and a row is append-only", %{org: org, admin: admin} do
    ctx = books!(admin, org)
    card = card!(admin, org, ctx.cost_object)
    lines = card_lines!(admin, org, card)

    assert {:ok, _} = run(admin, card, @period, actuals(lines))
    assert length(rows(org, @period)) == 7
    assert length(entries(org)) == 7

    # A second run with DIFFERENT actuals must not add or change a fact.
    assert {:ok, _} = run(admin, card, @period, actuals(lines, a_qty: 300, b_qty: 10))

    assert length(rows(org, @period)) == 7
    assert length(entries(org)) == 7
    assert by_type(org, @period).yield.amount_cents == 75_000

    row = by_type(org, @period).yield

    assert {:error, %Postgrex.Error{postgres: %{message: message}}} =
             @repo.query(
               "UPDATE fsv_cost_variance SET fsv_amount_cents = 1 WHERE fsv_id = $1::text::uuid",
               [row.id]
             )

    assert message =~ "append-only"
  end

  test "a measured-zero period records its marker and posts nothing", %{org: org, admin: admin} do
    ctx = books!(admin, org)
    card = card!(admin, org, ctx.cost_object)
    lines = card_lines!(admin, org, card)

    # Actuals exactly at standard: every measured class nets to zero.
    zero =
      actuals(lines,
        a_qty: 200,
        a_price: 1_000,
        b_qty: 125,
        b_price: 5_000,
        labor_qty: 3_000,
        labor_price: 100,
        overhead_qty: 3_000,
        overhead_price: 200
      )

    assert {:ok, _} = run(admin, card, @period, zero)

    rows = rows(org, @period)
    assert length(rows) == 7
    assert Enum.all?(rows, &(&1.amount_cents == 0))
    assert Enum.all?(rows, &is_nil(&1.entry_id))
    assert entries(org) == []

    assert ReconcileVariance.report(org, @period, r8_opts()).ok?

    # The zero rows ARE the run marker: a later run with different actuals is
    # still a no-op, so a reported zero cannot be quietly replaced.
    assert {:ok, _} = run(admin, card, @period, actuals(lines))
    assert Enum.all?(rows(org, @period), &(&1.amount_cents == 0))
    assert entries(org) == []
  end

  test "a disposed variance survives the period close", %{org: org, admin: admin} do
    ctx = books!(admin, org)
    card = card!(admin, org, ctx.cost_object)
    lines = card_lines!(admin, org, card)
    assert {:ok, _} = run(admin, card, @period, actuals(lines))

    before =
      rows(org, @period)
      |> Enum.map(&{&1.id, &1.amount_cents, &1.entry_id})
      |> Enum.sort()

    entries_before = entries(org) |> Enum.map(&{&1.id, &1.status}) |> Enum.sort()

    assert ReconcileVariance.report(org, @period, r8_opts()).ok?

    period =
      FiscalPeriod
      |> Ash.Changeset.for_create(:create, %{org_id: org, year: 2026, month: 3}, scope: admin)
      |> Ash.create!()

    assert {:ok, closed} =
             period
             |> Ash.Changeset.for_update(:close, %{}, scope: admin)
             |> Ash.update()

    assert closed.status == :closed

    # The close does not rewrite, move or drop the facts it reported on.
    assert rows(org, @period) |> Enum.map(&{&1.id, &1.amount_cents, &1.entry_id}) |> Enum.sort() ==
             before

    assert entries(org) |> Enum.map(&{&1.id, &1.status}) |> Enum.sort() == entries_before

    assert ReconcileVariance.report(org, @period, r8_opts()).ok?
  end

  # ── v8: fail-honest inputs ───────────────────────────────────────────────

  test "a card line with no actual refuses the whole run", %{org: org, admin: admin} do
    ctx = books!(admin, org)
    card = card!(admin, org, ctx.cost_object)
    lines = card_lines!(admin, org, card)

    incomplete = %{
      "output_units" => 100,
      "lines" => Map.delete(actuals(lines)["lines"], lines.b.id)
    }

    assert {:error, changeset} = run(admin, card, @period, incomplete)
    assert inspect(changeset.errors) =~ "no actual was declared"
    assert rows(org, @period) == []
    assert entries(org) == []
  end

  test "an actual for a line the card does not carry is refused", %{org: org, admin: admin} do
    ctx = books!(admin, org)
    card = card!(admin, org, ctx.cost_object)
    lines = card_lines!(admin, org, card)

    bogus =
      put_in(actuals(lines), ["lines", Ash.UUID.generate()], %{
        "qty" => 1,
        "unit_price_cents" => 1
      })

    assert {:error, changeset} = run(admin, card, @period, bogus)
    assert inspect(changeset.errors) =~ "not on this card"
  end

  # ── v9: the reads ────────────────────────────────────────────────────────

  test "the variance report shows all seven classes and labels labour", %{
    org: org,
    admin: admin
  } do
    ctx = books!(admin, org)
    card = card!(admin, org, ctx.cost_object)
    lines = card_lines!(admin, org, card)
    assert {:ok, _} = run(admin, card, @period, actuals(lines))

    report = VarianceReport.for_period(org, @period, variance: CostVariance)

    assert report.period_key == @period
    assert length(report.rows) == 7
    assert report.labour_basis == :declared_pending_driver
    assert report.totals.by_type.yield == 75_000
    assert report.totals.net_cents == Enum.reduce(report.rows, 0, &(&1.variance_cents + &2))
    assert Enum.all?(report.rows, &(&1.favourability in [:favourable, :unfavourable]))
  end

  test "cost of yield derives from the card and the absorbed yield variance", %{
    org: org,
    admin: admin
  } do
    ctx = books!(admin, org)
    card = card!(admin, org, ctx.cost_object)
    lines = card_lines!(admin, org, card)
    assert {:ok, _} = run(admin, card, @period, actuals(lines))

    [coy] =
      CostOfYield.for_period(org, @period,
        variance: CostVariance,
        standard: CostStandard,
        standard_line: CostStandardLine
      )

    # card allowance: A 200·1 000 + B 125·5 000 + labour 3 000·100 + OH 3 000·200
    assert coy.good_units == 100
    assert coy.standard_cents == 1_725_000
    assert coy.absorbed_cents == 75_000
    assert coy.coy_cents == 1_800_000
    assert coy.coy_per_unit_cents == 18_000
    assert coy.input_units == 140
    assert coy.yield_bp == 7_142
  end

  # ── fixture ───────────────────────────────────────────────────────────────

  defp tenant_scope(org_id) do
    %Samen.Scope{
      actor: %{id: "u:#{org_id}", org_id: org_id, role: :member, kind: :tenant, plane: :tenant}
    }
  end

  defp admin_scope(org_id) do
    %Samen.Scope{
      actor: %{id: "u:#{org_id}", org_id: org_id, role: :admin, kind: :tenant, plane: :tenant}
    }
  end

  defp new_account(scope, org, code, kind, side) do
    Account
    |> Ash.Changeset.for_create(
      :create,
      %{org_id: org, code: code, name: "Account #{code}", kind: kind, normal_side: side},
      scope: scope
    )
    |> Ash.create!()
  end

  defp new_posting_account(admin, org, key, account) do
    PostingAccount
    |> Ash.Changeset.for_create(:create, %{org_id: org, key: key, account_id: account.id},
      scope: admin
    )
    |> Ash.create!()
  end

  defp new_cost_object(admin, org, code) do
    CostObject
    |> Ash.Changeset.for_create(
      :create,
      %{org_id: org, code: code, name: "Cost object #{code}", kind: :project},
      scope: admin
    )
    |> Ash.create!()
  end

  # The org's accounts: the two finished-goods targets, the two write-off
  # targets, the four variance families and a cost object.
  defp books!(admin, org) do
    chip = new_account(admin, org, "1400", :asset, :debit)
    board = new_account(admin, org, "1430", :asset, :debit)
    cogs = new_account(admin, org, "5000", :expense, :debit)
    rd = new_account(admin, org, "6020", :expense, :debit)
    variance_ppv = new_account(admin, org, "5100", :expense, :debit)
    variance_yield = new_account(admin, org, "5120", :expense, :debit)
    variance_labor = new_account(admin, org, "5150", :expense, :debit)
    variance_overhead = new_account(admin, org, "5180", :expense, :debit)

    new_posting_account(admin, org, :finished_goods_chip, chip)
    new_posting_account(admin, org, :finished_goods_board, board)
    new_posting_account(admin, org, :cogs, cogs)
    new_posting_account(admin, org, :rd_expense, rd)
    new_posting_account(admin, org, :variance_ppv, variance_ppv)
    new_posting_account(admin, org, :variance_yield, variance_yield)
    new_posting_account(admin, org, :variance_labor, variance_labor)
    new_posting_account(admin, org, :variance_overhead, variance_overhead)

    %{
      chip: chip,
      board: board,
      cogs: cogs,
      rd: rd,
      variance_ppv: variance_ppv,
      variance_yield: variance_yield,
      variance_labor: variance_labor,
      variance_overhead: variance_overhead,
      cost_object: new_cost_object(admin, org, "soc")
    }
  end

  defp card!(admin, org, cost_object, attrs \\ %{}) do
    defaults = %{
      org_id: org,
      code: "SOC-STD",
      cost_object_id: cost_object.id,
      output_item_id: Ash.UUID.generate(),
      effective_on: ~D[2026-01-01],
      dimension_key: :project
    }

    CostStandard
    |> Ash.Changeset.for_create(:create, Map.merge(defaults, attrs), scope: admin)
    |> Ash.create!()
  end

  defp card_lines!(admin, org, card) do
    a =
      line!(admin, org, card, %{
        element: :material,
        item_id: Ash.UUID.generate(),
        standard_qty: 2,
        standard_unit_price_cents: 1_000,
        usage_basis: :bom
      })

    b =
      line!(admin, org, card, %{
        element: :material,
        item_id: Ash.UUID.generate(),
        standard_qty: 1,
        standard_unit_price_cents: 5_000,
        expected_yield_bp: 8_000,
        usage_basis: :yield
      })

    labor =
      line!(admin, org, card, %{
        element: :labor,
        standard_qty: 30,
        standard_unit_price_cents: 100,
        usage_basis: :none
      })

    overhead =
      line!(admin, org, card, %{
        element: :overhead,
        standard_qty: 30,
        standard_unit_price_cents: 200,
        usage_basis: :none
      })

    %{a: a, b: b, labor: labor, overhead: overhead}
  end

  defp line!(admin, org, card, attrs) do
    CostStandardLine
    |> Ash.Changeset.for_create(:create, Map.merge(%{org_id: org, standard_id: card.id}, attrs),
      scope: admin
    )
    |> Ash.create!()
  end

  defp actuals(lines, opts \\ []) do
    %{
      "output_units" => 100,
      "lines" => %{
        lines.a.id => %{
          "qty" => Keyword.get(opts, :a_qty, 210),
          "unit_price_cents" => Keyword.get(opts, :a_price, 1_100)
        },
        lines.b.id => %{
          "qty" => Keyword.get(opts, :b_qty, 140),
          "unit_price_cents" => Keyword.get(opts, :b_price, 4_800)
        },
        lines.labor.id => %{
          "qty" => Keyword.get(opts, :labor_qty, 3_100),
          "unit_price_cents" => Keyword.get(opts, :labor_price, 105)
        },
        lines.overhead.id => %{
          "qty" => Keyword.get(opts, :overhead_qty, 3_100),
          "unit_price_cents" => Keyword.get(opts, :overhead_price, 195)
        }
      }
    }
  end

  defp run(admin, card, period_key, actuals) do
    card
    |> Ash.Changeset.for_update(
      :post_variances,
      %{period_key: period_key, actuals: actuals},
      scope: admin
    )
    |> Ash.update()
  end

  defp rows(org, period_key) do
    CostVariance
    |> Ash.Query.filter(org_id == ^org and period_key == ^period_key)
    |> Ash.read!(authorize?: false)
  end

  defp by_type(org, period_key), do: Map.new(rows(org, period_key), &{&1.type, &1})

  defp entries(org) do
    JournalEntry
    |> Ash.Query.filter(org_id == ^org and source_key == "cost_variance")
    |> Ash.read!(authorize?: false)
  end

  defp entry_lines(org, entry_id) do
    JournalLine
    |> Ash.Query.filter(org_id == ^org and entry_id == ^entry_id)
    |> Ash.read!(authorize?: false)
  end

  defp r8_opts do
    [
      variance: CostVariance,
      standard: CostStandard,
      standard_line: CostStandardLine,
      entry: JournalEntry,
      line: JournalLine,
      posting_account: PostingAccount
    ]
  end

  # A posted entry with the given two legs, anchored cost_variance. Used by the
  # red-path leg to craft a row the policy MUST reject.
  defp anchored_entry!(_admin, org, date, debit_account, credit_account, amount) do
    dims = %{"project" => cost_object_id(org)}
    entry_id = Ash.UUID.generate()

    {:ok, draft} =
      JournalEntry
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: org,
          entry_date: date,
          memo: "crafted variance",
          source_key: "cost_variance",
          source_id: entry_id,
          lines: [
            %{account_id: debit_account.id, debit_cents: amount, dimension_refs: dims},
            %{account_id: credit_account.id, credit_cents: amount, dimension_refs: dims}
          ]
        },
        authorize?: false
      )
      |> Ash.create(authorize?: false)

    {:ok, posted} =
      draft
      |> Ash.Changeset.for_update(:post, %{}, authorize?: false)
      |> Ash.update(authorize?: false)

    posted
  end

  defp cost_object_id(org) do
    CostObject
    |> Ash.Query.filter(org_id == ^org)
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.read_one!(authorize?: false)
    |> Map.fetch!(:id)
  end

  defp insert_variance!(attrs) do
    {:ok, _} =
      @repo.query(
        """
        INSERT INTO fsv_cost_variance (
          fsv_id, fsv_org_id, fsv_period_key, fsv_type, fsv_amount_cents,
          fsv_actual_amount_cents, fsv_standard_amount_cents, fsv_disposition,
          fsv_variance_account_id, fsv_disposition_account_id, fsv_entry_id,
          fsv_standard_id, fsv_cost_object_id, fsv_inputs, fsv_inserted_at, fsv_updated_at
        ) VALUES (
          $1::text::uuid, $2::text::uuid, $3, $4, $5, $6, $7, $8, $9::text::uuid,
          $10::text::uuid, $11::text::uuid, $12::text::uuid, $13::text::uuid,
          $14::jsonb, now(), now()
        )
        """,
        [
          attrs.id,
          attrs.org,
          attrs.period,
          attrs.type,
          attrs.amount,
          attrs.actual,
          attrs.standard,
          attrs.disposition,
          attrs.variance_account_id,
          attrs.disposition_account_id,
          attrs.entry_id,
          attrs.standard_id,
          attrs.cost_object_id,
          %{"output_units" => 100, "lines" => %{}}
        ]
      )

    :ok
  end
end
