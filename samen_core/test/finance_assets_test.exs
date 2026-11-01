defmodule Samen.FinanceAssetsTest do
  @moduledoc """
  WS-ACCT Phase 8 (ADR-054 D9) — the asset register, its DERIVED schedules and
  the exactly-once depreciation run, mounted via
  `test/support/finance_fixture.ex`.

  Every refusal is paired with a positive control (`Samen.RedPath` discipline):

    * a1 the PDK licence's 36-month schedule reproduces the manual's JE-004
      arithmetic in whole cents (the last month absorbs the remainder);
    * a2 a posted slice lands the expense/contra pair, dated the period's last
      day and anchored to the posting;
    * a3 lab equipment books depreciation against `1520`, not the PDK's
      amortization pair — the `1520` correction the books seed documents;
    * a4 the schedule rolls off at end-of-life: Σ == cost − salvage, a month
      past the life posts nothing, and NBV reaches salvage;
    * a5 exactly once: a repeated sweep is a clean no-op, the unique index is
      the belt, and the row is append-only;
    * a6 a disposal stops the schedule from its month, leaves the posted past
      alone, and is one-way;
    * a7 the audit is green on the run and DETECTS an unbacked row and an
      orphaned anchored entry (the anti-tautology leg);
    * a8 R10 on the new door: a CLOSED period refuses the slice and leaves no
      posting; the next open month still posts (CONTROL);
    * a9 fail-honest: an unmapped account refuses the slice, and mapping it
      makes the same month post (CONTROL);
    * a10 the cascade refuses a crafted amount, a mid-period date and a foreign
      asset;
    * a11 the monthly sweep rides the canonical crontab;
    * a12 a member cannot capitalize an asset; an admin can;
    * a13 a dimensioned asset carries its cost object on BOTH legs (R6), and an
      undimensioned one stays undimensioned.
  """
  use ExUnit.Case, async: false

  require Ash.Query

  alias Samen.Scopes.Finance.{AssetRegister, AssetSchedule, DepreciationRun, ReconcileAssets}

  alias SamenCore.Support.FinanceFixture.{
    Account,
    Asset,
    AssetPosting,
    CostObject,
    FiscalPeriod,
    JournalEntry,
    JournalLine,
    PostingAccount
  }

  @repo SamenCore.TestRepo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(@repo)
    org = Ash.UUID.generate()

    prev = Application.get_env(:samen_core, DepreciationRun)

    Application.put_env(:samen_core, DepreciationRun,
      modules: [
        asset: Asset,
        posting: AssetPosting,
        entry: JournalEntry,
        line: JournalLine,
        account: Account
      ]
    )

    on_exit(fn ->
      if prev do
        Application.put_env(:samen_core, DepreciationRun, prev)
      else
        Application.delete_env(:samen_core, DepreciationRun)
      end
    end)

    {:ok, org: org, admin: admin_scope(org), tenant: tenant_scope(org)}
  end

  # ── a1: the PDK arithmetic ────────────────────────────────────────────────

  test "the PDK licence reproduces the manual's 36-month arithmetic in whole cents", %{
    org: org,
    admin: admin
  } do
    _ = books!(admin, org)

    pdk =
      asset!(admin, org, %{
        code: "PDK-PHOTONICS",
        name: "Photonics PDK License",
        kind: :intangible,
        cost_cents: 60_000_000,
        acquired_on: ~D[2026-01-01],
        life_months: 36,
        salvage_cents: 0
      })

    slices = AssetSchedule.slices(pdk)

    assert length(slices) == 36
    assert hd(slices).period_key == "2026-01"
    assert List.last(slices).period_key == "2028-12"

    # 60 000 000 / 36 = 1 666 666.67 cents. The integer schedule carries
    # 16 666.66 for 35 months and 16 666.90 for the last, so the term releases
    # 600 000.00 EXACTLY — the manual's 16 666.67 is the average, not a slice.
    assert hd(slices).amount_cents == 1_666_666
    assert List.last(slices).amount_cents == 1_666_690
    assert Enum.sum(Enum.map(slices, & &1.amount_cents)) == 60_000_000
    assert List.last(slices).cumulative_cents == 60_000_000

    assert 35 * 1_666_666 + 1_666_690 == 60_000_000
    assert round(60_000_000 / 36) == 1_666_667

    assert {:ok, 1_666_666} = AssetSchedule.slice(pdk, "2026-01")
    assert {:ok, 1_666_690} = AssetSchedule.slice(pdk, "2028-12")
    assert :outside_term = AssetSchedule.slice(pdk, "2025-12")
    assert :outside_term = AssetSchedule.slice(pdk, "2029-01")
  end

  # ── a2: the posting ───────────────────────────────────────────────────────

  test "a posted slice lands the expense/contra pair, dated the period's last day", %{
    org: org,
    admin: admin
  } do
    ctx = books!(admin, org)
    pdk = pdk!(admin, org, ctx)

    assert {:ok, %{posted: [posting_id]}} = DepreciationRun.run(period: {2026, 1})

    assert [posting] = postings(org)
    assert posting.id == posting_id
    assert posting.period_key == "2026-01"
    assert posting.amount_cents == 1_666_666
    assert posting.depreciated_on == ~D[2026-01-31]
    assert posting.expense_account_id == ctx.amortization_expense.id
    assert posting.contra_account_id == ctx.accumulated_amortization.id

    [entry] = entries(org)
    assert entry.status == :posted
    assert entry.entry_date == ~D[2026-01-31]
    assert entry.source_key == "asset_posting"
    assert entry.source_id == posting.id

    lines = entry_lines(org, entry.id)

    assert Enum.sort(Enum.map(lines, &{&1.account_id, &1.debit_cents, &1.credit_cents})) ==
             Enum.sort([
               {ctx.amortization_expense.id, 1_666_666, 0},
               {ctx.accumulated_amortization.id, 0, 1_666_666}
             ])

    register = AssetRegister.for_org(org, asset: Asset, posting: AssetPosting)
    [row] = register.assets

    assert row.asset.id == pdk.id
    assert row.accumulated_cents == 1_666_666
    assert row.nbv_cents == 58_333_334
    assert row.monthly_cents == 1_666_666
    assert row.next_open_period == "2026-02"
    assert row.last_posted_period == "2026-01"
    assert Enum.find(row.schedule, &(&1.period_key == "2026-01")).posted?
  end

  # ── a3: the equipment pair ────────────────────────────────────────────────

  test "lab equipment books depreciation against 1520, not the PDK amortization pair", %{
    org: org,
    admin: admin
  } do
    ctx = books!(admin, org)

    _equipment =
      asset!(admin, org, %{
        code: "LAB-EQUIPMENT",
        name: "Lab Equipment",
        kind: :equipment,
        cost_cents: 4_800_000,
        acquired_on: ~D[2026-01-01],
        life_months: 48,
        salvage_cents: 0
      })

    assert {:ok, %{posted: [_]}} = DepreciationRun.run(period: {2026, 1})

    [posting] = postings(org)
    assert posting.amount_cents == 100_000
    assert posting.expense_account_id == ctx.depreciation_expense.id
    assert posting.contra_account_id == ctx.accumulated_depreciation.id

    [entry] = entries(org)

    assert Enum.sort(
             Enum.map(
               entry_lines(org, entry.id),
               &{&1.account_id, &1.debit_cents, &1.credit_cents}
             )
           ) ==
             Enum.sort([
               {ctx.depreciation_expense.id, 100_000, 0},
               {ctx.accumulated_depreciation.id, 0, 100_000}
             ])
  end

  # ── a4: end of life ───────────────────────────────────────────────────────

  test "the schedule rolls off at end-of-life and refuses a month past it", %{
    org: org,
    admin: admin
  } do
    ctx = books!(admin, org)
    pdk = pdk!(admin, org, ctx)

    for year <- 2026..2028, month <- 1..12 do
      assert {:ok, %{posted: [_]}} = DepreciationRun.run(period: {year, month})
    end

    assert length(postings(org)) == 36
    assert Enum.sum(Enum.map(postings(org), & &1.amount_cents)) == 60_000_000

    register = AssetRegister.for_org(org, asset: Asset, posting: AssetPosting)
    [row] = register.assets

    assert row.fully_amortized?
    assert row.accumulated_cents == 60_000_000
    assert row.remaining_cents == 0
    assert row.nbv_cents == 0
    assert row.next_open_period == nil

    # The 37th month has no contractual slice: the sweep reports it and posts
    # nothing, rather than inventing a month past the life.
    assert {:ok, %{posted: [], skipped: [{asset_id, :fully_depreciated}]}} =
             DepreciationRun.run(period: {2029, 1})

    assert asset_id == pdk.id
    assert length(postings(org)) == 36
    assert length(entries(org)) == 36
  end

  # ── a5: exactly once ──────────────────────────────────────────────────────

  test "a second run in the same period is a clean no-op; the anchor is append-only", %{
    org: org,
    admin: admin
  } do
    ctx = books!(admin, org)
    pdk = pdk!(admin, org, ctx)

    assert {:ok, %{posted: [first]}} = DepreciationRun.run(period: {2026, 1})

    # The READ guard: a retried cron sees the row and skips — no error, no
    # duplicate, no second entry.
    assert {:ok, %{posted: [], skipped: [{asset_id, :already_posted}]}} =
             DepreciationRun.run(period: {2026, 1})

    assert asset_id == pdk.id
    assert [%{id: ^first}] = postings(org)
    assert length(entries(org)) == 1

    # The BELT: the unique index refuses a duplicate row even below Ash.
    assert {:error, %Postgrex.Error{}} =
             @repo.query(
               """
               INSERT INTO fsp_asset_posting
                 (fsp_id, fsp_org_id, fsp_asset_id, fsp_period_key, fsp_amount_cents,
                  fsp_depreciated_on, fsp_expense_account_id, fsp_contra_account_id,
                  fsp_inserted_at, fsp_updated_at)
               VALUES (gen_random_uuid(), $1, $2, '2026-01', 1_666_666, '2026-01-31',
                       $3, $4, now(), now())
               """,
               [
                 Ecto.UUID.dump!(org),
                 Ecto.UUID.dump!(pdk.id),
                 Ecto.UUID.dump!(ctx.amortization_expense.id),
                 Ecto.UUID.dump!(ctx.accumulated_amortization.id)
               ]
             )

    # Append-only: the trigger refuses UPDATE and DELETE outright.
    assert {:error, %Postgrex.Error{postgres: %{message: message}}} =
             @repo.query(
               "UPDATE fsp_asset_posting SET fsp_amount_cents = 1 WHERE fsp_id = $1::text::uuid",
               [first]
             )

    assert message =~ "append-only"
  end

  # ── a6: disposal ──────────────────────────────────────────────────────────

  test "a disposal stops the schedule from its month and leaves the past posted", %{
    org: org,
    admin: admin
  } do
    ctx = books!(admin, org)
    pdk = pdk!(admin, org, ctx)

    for month <- 1..12 do
      assert {:ok, %{posted: [_]}} = DepreciationRun.run(period: {2026, month})
    end

    for month <- 1..5 do
      assert {:ok, %{posted: [_]}} = DepreciationRun.run(period: {2027, month})
    end

    assert length(postings(org)) == 17

    disposed =
      pdk
      |> Ash.Changeset.for_update(:dispose, %{disposed_on: ~D[2027-06-15]}, scope: admin)
      |> Ash.update!()

    assert disposed.status == :disposed
    assert disposed.disposed_on == ~D[2027-06-15]

    # June is the disposal month: the schedule stops there, so neither June nor
    # July posts — and the 17 months before it are untouched.
    assert {:ok, %{posted: [], skipped: [{asset_id, :disposed}]}} =
             DepreciationRun.run(period: {2027, 6})

    assert asset_id == pdk.id

    assert {:ok, %{posted: [], skipped: [{_, :disposed}]}} =
             DepreciationRun.run(period: {2027, 7})

    assert length(postings(org)) == 17
    assert Enum.sum(Enum.map(postings(org), & &1.amount_cents)) == 17 * 1_666_666

    register = AssetRegister.for_org(org, asset: Asset, posting: AssetPosting)
    [row] = register.assets

    assert row.status == :disposed
    assert row.disposed_on == ~D[2027-06-15]
    assert row.accumulated_cents == 17 * 1_666_666
    refute row.fully_amortized?

    stopped = Enum.filter(row.schedule, & &1.stopped?)
    assert List.first(stopped).period_key == "2027-06"
    assert Enum.all?(stopped, &(not &1.posted?))

    # One-way: a second disposal is refused, and a disposal before the
    # acquisition is refused.
    assert {:error, %Ash.Error.Invalid{} = err} =
             disposed
             |> Ash.Changeset.for_update(:dispose, %{disposed_on: ~D[2027-08-01]}, scope: admin)
             |> Ash.update()

    assert Exception.message(err) =~ "one-way"

    fresh = pdk!(admin, org, ctx, %{code: "PDK-2"})

    assert {:error, %Ash.Error.Invalid{} = err} =
             fresh
             |> Ash.Changeset.for_update(:dispose, %{disposed_on: ~D[2025-12-31]}, scope: admin)
             |> Ash.update()

    assert Exception.message(err) =~ "before the acquisition"
  end

  # ── a7: the audit ─────────────────────────────────────────────────────────

  test "the audit is green on the run and detects an unbacked row and an orphaned entry", %{
    org: org,
    admin: admin
  } do
    ctx = books!(admin, org)
    pdk = pdk!(admin, org, ctx)

    for month <- 1..3 do
      assert {:ok, %{posted: [_]}} = DepreciationRun.run(period: {2026, month})
    end

    report = audit(org)
    assert report.ok?, inspect(report.violations)
    assert report.contra.agrees?
    assert report.contra.posted_cents == 3 * 1_666_666
    assert report.contra.gl_cents == 3 * 1_666_666
    assert [%{asset_id: asset_id, accumulated_cents: accumulated}] = report.assets
    assert asset_id == pdk.id
    assert accumulated == 3 * 1_666_666

    # An UNBACKED row: a slice with no entry at all, carrying a number the
    # schedule never derives.
    unbacked_id = Ash.UUID.generate()

    assert {:ok, _} =
             @repo.query(
               """
               INSERT INTO fsp_asset_posting
                 (fsp_id, fsp_org_id, fsp_asset_id, fsp_period_key, fsp_amount_cents,
                  fsp_depreciated_on, fsp_expense_account_id, fsp_contra_account_id,
                  fsp_inserted_at, fsp_updated_at)
               VALUES ($1::text::uuid, $2, $3, '2026-04', 999, '2026-04-30', $4, $5, now(), now())
               """,
               [
                 unbacked_id,
                 Ecto.UUID.dump!(org),
                 Ecto.UUID.dump!(pdk.id),
                 Ecto.UUID.dump!(ctx.amortization_expense.id),
                 Ecto.UUID.dump!(ctx.accumulated_amortization.id)
               ]
             )

    # An ORPHANED anchored entry: it claims to be an asset posting, but no row
    # names it.
    orphan = orphan_entry!(org, ctx)

    red = audit(org)

    refute red.ok?
    assert Enum.any?(red.violations, &match?({:unbacked, ^unbacked_id}, &1))
    assert Enum.any?(red.violations, &match?({:amount, ^unbacked_id, _, 999}, &1))
    assert Enum.any?(red.violations, &match?({:orphaned_gl, ^orphan}, &1))
  end

  # ── a8: R10 ───────────────────────────────────────────────────────────────

  test "a closed period refuses the slice and leaves no posting behind", %{
    org: org,
    admin: admin
  } do
    ctx = books!(admin, org)
    _pdk = pdk!(admin, org, ctx)

    assert {:error, {:depreciation_failed, failures}} = close_and_run(admin, org, {2026, 1})
    assert [{_asset_id, _reason}] = failures
    assert postings(org) == []
    assert entries(org) == []

    # CONTROL: the next month is open and posts.
    assert {:ok, %{posted: [_]}} = DepreciationRun.run(period: {2026, 2})
    assert length(postings(org)) == 1
  end

  # ── a9: fail-honest accounts ──────────────────────────────────────────────

  test "an unmapped amortization account refuses the slice", %{org: org, admin: admin} do
    ctx = accounts!(admin, org)

    _pdk = pdk!(admin, org, ctx)

    assert {:error, {:depreciation_failed, [{_asset_id, reason}]}} =
             DepreciationRun.run(period: {2026, 1})

    assert inspect(reason) =~ "accumulated_amortization" or
             inspect(reason) =~ "amortization_expense"

    assert postings(org) == []
    assert entries(org) == []

    # CONTROL: map the pair and the same month posts.
    map_posting!(admin, org, :amortization_expense, ctx.amortization_expense)
    map_posting!(admin, org, :accumulated_amortization, ctx.accumulated_amortization)

    assert {:ok, %{posted: [_]}} = DepreciationRun.run(period: {2026, 1})
    assert length(postings(org)) == 1
  end

  # ── a10: the cascade's own guards ─────────────────────────────────────────

  test "a crafted amount or a mid-period date is refused by the cascade", %{
    org: org,
    admin: admin
  } do
    ctx = books!(admin, org)
    pdk = pdk!(admin, org, ctx)

    assert {:error, %Ash.Error.Invalid{} = err} =
             create_posting(org, pdk, %{amount_cents: 1, depreciated_on: ~D[2026-01-31]})

    assert Exception.message(err) =~ "derived schedule"
    assert postings(org) == []

    assert {:error, %Ash.Error.Invalid{} = err} =
             create_posting(org, pdk, %{
               amount_cents: 1_666_666,
               depreciated_on: ~D[2026-01-15]
             })

    assert Exception.message(err) =~ "last day"
    assert postings(org) == []

    # CONTROL: the exact slice, dated the period's last day, posts.
    assert {:ok, posting} =
             create_posting(org, pdk, %{
               amount_cents: 1_666_666,
               depreciated_on: ~D[2026-01-31]
             })

    assert posting.amount_cents == 1_666_666

    # A foreign asset cannot be posted against.
    other_org = Ash.UUID.generate()
    other_ctx = books!(admin_scope(other_org), other_org)
    foreign = pdk!(admin_scope(other_org), other_org, other_ctx, %{code: "FOREIGN"})

    assert {:error, %Ash.Error.Invalid{} = err} =
             create_posting(org, foreign, %{
               amount_cents: 1_666_666,
               depreciated_on: ~D[2026-01-31]
             })

    # The cascade loads the asset pinned to this org, so a foreign target is
    # invisible and the refusal names that rather than posting across tenants.
    assert Exception.message(err) =~ "does not belong to this org"
  end

  # ── a11: the cron ─────────────────────────────────────────────────────────

  test "the monthly sweep rides the canonical crontab" do
    assert {"45 0 1 * *", Samen.Scopes.Finance.DepreciationWorker} in Samen.Jobs.default_crontab()
  end

  # ── a12: the policy rung ──────────────────────────────────────────────────

  test "a member cannot capitalize an asset; an admin can", %{
    org: org,
    tenant: tenant,
    admin: admin
  } do
    assert {:error, %Ash.Error.Forbidden{}} =
             Asset
             |> Ash.Changeset.for_create(:create, base_attrs(org, %{}), scope: tenant)
             |> Ash.create()

    assert {:ok, asset} =
             Asset
             |> Ash.Changeset.for_create(:create, base_attrs(org, %{}), scope: admin)
             |> Ash.create()

    assert asset.status == :active
  end

  # ── a13: R6 ───────────────────────────────────────────────────────────────

  test "a dimensioned asset carries its cost object on both legs", %{org: org, admin: admin} do
    ctx = books!(admin, org)
    dims = ctx.cost_object

    _dimensioned =
      asset!(admin, org, %{
        code: "PDK-DIM",
        name: "Dimensioned PDK",
        kind: :intangible,
        cost_cents: 60_000_000,
        acquired_on: ~D[2026-01-01],
        life_months: 36,
        cost_object_id: dims.id,
        dimension_key: :project
      })

    _plain =
      asset!(admin, org, %{
        code: "PDK-PLAIN",
        name: "Undimensioned PDK",
        kind: :intangible,
        cost_cents: 36_000,
        acquired_on: ~D[2026-01-01],
        life_months: 36
      })

    assert {:ok, %{posted: posted}} = DepreciationRun.run(period: {2026, 1})
    assert length(posted) == 2

    for posting <- postings(org) do
      [entry] = Enum.filter(entries(org), &(&1.source_id == posting.id))
      lines = entry_lines(org, entry.id)
      assert length(lines) == 2

      if posting.amount_cents == 1_666_666 do
        assert Enum.all?(lines, &(&1.dimension_refs["project"] == dims.id))
      else
        assert Enum.all?(lines, &(&1.dimension_refs == %{}))
      end
    end

    report = audit(org)
    assert report.ok?, inspect(report.violations)
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

  defp map_posting!(admin, org, key, account) do
    PostingAccount
    |> Ash.Changeset.for_create(:create, %{org_id: org, key: key, account_id: account.id},
      scope: admin
    )
    |> Ash.create!()
  end

  defp cost_object!(admin, org) do
    CostObject
    |> Ash.Changeset.for_create(
      :create,
      %{org_id: org, code: "pta", name: "PTA Photonics", kind: :chip},
      scope: admin
    )
    |> Ash.create!()
  end

  # The four GL accounts the register posts against: the PDK pair (7000/1510)
  # and the equipment pair (6030/1520). The accounts exist unbound, so the
  # fail-honest test can map them late.
  defp accounts!(admin, org) do
    %{
      amortization_expense: new_account(admin, org, "7000", :expense, :debit),
      accumulated_amortization: new_account(admin, org, "1510", :asset, :credit),
      depreciation_expense: new_account(admin, org, "6030", :expense, :debit),
      accumulated_depreciation: new_account(admin, org, "1520", :asset, :credit),
      cost_object: nil
    }
  end

  defp books!(admin, org) do
    ctx = accounts!(admin, org)

    map_posting!(admin, org, :amortization_expense, ctx.amortization_expense)
    map_posting!(admin, org, :accumulated_amortization, ctx.accumulated_amortization)
    map_posting!(admin, org, :depreciation_expense, ctx.depreciation_expense)
    map_posting!(admin, org, :accumulated_depreciation, ctx.accumulated_depreciation)

    %{ctx | cost_object: cost_object!(admin, org)}
  end

  defp base_attrs(org, attrs) do
    Map.merge(
      %{
        org_id: org,
        code: "AST-#{System.unique_integer([:positive])}",
        name: "Asset",
        kind: :intangible,
        cost_cents: 60_000_000,
        acquired_on: ~D[2026-01-01],
        life_months: 36,
        salvage_cents: 0
      },
      attrs
    )
  end

  defp asset!(admin, org, attrs) do
    Asset
    |> Ash.Changeset.for_create(:create, base_attrs(org, attrs), scope: admin)
    |> Ash.create!()
  end

  defp pdk!(admin, org, _ctx, attrs \\ %{}) do
    asset!(
      admin,
      org,
      Map.merge(
        %{
          code: "PDK-PHOTONICS",
          name: "Photonics PDK License",
          kind: :intangible,
          cost_cents: 60_000_000,
          acquired_on: ~D[2026-01-01],
          life_months: 36,
          salvage_cents: 0
        },
        attrs
      )
    )
  end

  defp create_posting(org, asset, attrs) do
    AssetPosting
    |> Ash.Changeset.for_create(
      :depreciate,
      %{
        org_id: org,
        asset_id: asset.id,
        period_key: "2026-01",
        amount_cents: 1_666_666,
        depreciated_on: ~D[2026-01-31]
      }
      |> Map.merge(attrs),
      authorize?: false
    )
    |> Ash.create(authorize?: false)
  end

  defp close_and_run(admin, org, {year, month}) do
    period =
      FiscalPeriod
      |> Ash.Changeset.for_create(:create, %{org_id: org, year: year, month: month}, scope: admin)
      |> Ash.create!()

    assert {:ok, %{status: :closed}} =
             period
             |> Ash.Changeset.for_update(:close, %{}, scope: admin)
             |> Ash.update()

    DepreciationRun.run(period: {year, month})
  end

  defp postings(org) do
    AssetPosting
    |> Ash.Query.filter(org_id == ^org)
    |> Ash.Query.sort(period_key: :asc)
    |> Ash.read!(authorize?: false)
  end

  defp entries(org) do
    JournalEntry
    |> Ash.Query.filter(org_id == ^org and source_key == "asset_posting")
    |> Ash.read!(authorize?: false)
  end

  defp entry_lines(org, entry_id) do
    JournalLine
    |> Ash.Query.filter(org_id == ^org and entry_id == ^entry_id)
    |> Ash.read!(authorize?: false)
  end

  defp audit(org) do
    ReconcileAssets.report(org,
      asset: Asset,
      posting: AssetPosting,
      entry: JournalEntry,
      line: JournalLine
    )
  end

  # An anchored entry that claims to be an asset posting but has no row.
  defp orphan_entry!(org, ctx) do
    {:ok, draft} =
      JournalEntry
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: org,
          entry_date: ~D[2026-03-31],
          memo: "crafted orphan",
          source_key: "asset_posting",
          source_id: Ash.UUID.generate(),
          lines: [
            %{account_id: ctx.amortization_expense.id, debit_cents: 1_000},
            %{account_id: ctx.accumulated_amortization.id, credit_cents: 1_000}
          ]
        },
        authorize?: false
      )
      |> Ash.create(authorize?: false)

    {:ok, posted} =
      draft
      |> Ash.Changeset.for_update(:post, %{}, authorize?: false)
      |> Ash.update(authorize?: false)

    posted.id
  end
end
