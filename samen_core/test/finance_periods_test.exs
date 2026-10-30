defmodule Samen.FinancePeriodsTest do
  @moduledoc """
  WS-ACCT Phase 3 (ADR-054 D7, design §3 R10) — fiscal periods, the close state
  machine and the posting gate, mounted via `test/support/finance_fixture.ex`.

  Every refusal is paired with a positive control (anti-tautology, `Samen.RedPath`
  discipline):

    * p1 the period is a ROW: born `:open`, unique per org and month, `status`
      not caller input, month range refused;
    * p2 **R10 at the door** — a closed period refuses the post (RED) while the
      same entry posts in an open period (CONTROL); a soft-closed period refuses
      a DOCUMENT anchor (RED) and admits a journal-only adjustment and the
      ledger's own reversal anchor (CONTROLs); a missing period row stays OPEN
      (the pre-Phase-3 behavior, CONTROL); a void dated in a closed period is
      refused up front;
    * p3 the close is ONE-WAY — open → soft_closed → closed, stamped, no edge
      back, and no reopen/destroy route exists at all (the "a period cannot be
      un-closed" proof the build plan asks for);
    * p4 the DATABASE belt — a raw-SQL posted insert into a closed period is
      refused even with the PostGuard marker armed (RED), and the same insert
      into an open period lands (CONTROL);
    * p5 the ASH gate is load-bearing on its own — with the belt trigger
      temporarily disabled, the closed-period post is still refused (this is
      sabotage 404's named test: drop the change and nothing refuses it);
    * p6 the R10 READ mirror — a period closed over entries that were posted
      before the close reads CLEAN (CONTROL), and a posting that lands after its
      period closed is DETECTED (anti-tautology: the row is forced in with the
      belt disabled);
    * p7 the close run — the doc's ten phases seed, complete by key, refuse an
      unknown key, refuse to finish with phases open, and are final once
      completed.
  """
  use ExUnit.Case, async: false

  alias Samen.Scopes.Finance.ClosePhases
  alias Samen.Scopes.Finance.PeriodReconcile
  alias Samen.Scopes.Finance.PostingMarker

  alias SamenCore.Support.FinanceFixture.{
    Account,
    CloseRun,
    FiscalPeriod,
    JournalEntry
  }

  @repo SamenCore.TestRepo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(@repo)
    org = Ash.UUID.generate()
    {:ok, org: org, scope: tenant_scope(org), admin: admin_scope(org)}
  end

  # ── helpers ────────────────────────────────────────────────────────────────

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

  defp new_account(scope, org, code) do
    Account
    |> Ash.Changeset.for_create(
      :create,
      %{org_id: org, code: code, name: "Account #{code}", kind: :asset, normal_side: :debit},
      scope: scope
    )
    |> Ash.create!()
  end

  defp period_changeset(scope, org, year, month) do
    FiscalPeriod
    |> Ash.Changeset.for_create(:create, %{org_id: org, year: year, month: month}, scope: scope)
  end

  defp period!(scope, org, year, month), do: period_changeset(scope, org, year, month) |> Ash.create!()

  defp soft_close!(period, scope) do
    period |> Ash.Changeset.for_update(:soft_close, %{}, scope: scope) |> Ash.update!()
  end

  defp close!(period, scope) do
    period |> Ash.Changeset.for_update(:close, %{}, scope: scope) |> Ash.update!()
  end

  defp draft(scope, org, entry_date, opts \\ []) do
    {cash, wip} = accounts(scope, org)

    JournalEntry
    |> Ash.Changeset.for_create(
      :create,
      %{
        org_id: org,
        entry_date: entry_date,
        memo: "period leg",
        lines: [
          %{account_id: wip.id, debit_cents: 100},
          %{account_id: cash.id, credit_cents: 100}
        ]
      }
      |> Map.merge(Map.new(opts)),
      scope: scope
    )
    |> Ash.create()
  end

  # The accounts are created once per test; both legs use the SAME pair so the
  # codes stay unique per org.
  defp accounts(scope, org) do
    key = {__MODULE__, org}

    case Process.get(key) do
      nil ->
        pair = {new_account(scope, org, "1000"), new_account(scope, org, "1200")}
        Process.put(key, pair)
        pair

      pair ->
        pair
    end
  end

  defp post(entry, scope) do
    entry |> Ash.Changeset.for_update(:post, %{}, scope: scope) |> Ash.update()
  end

  # The DOCUMENT posting shape: the posted-born internal factory, called the way
  # every system cascade calls it (AP approval, the stock-receipt bridge, the
  # sales bridge) — `authorize?: false`. The posting gate is a CHANGE, not a
  # policy, so it still runs on this path, which is exactly the path that
  # matters.
  defp document_reversal(scope, org, entry_date, source_key) do
    {cash, wip} = accounts(scope, org)

    JournalEntry
    |> Ash.Changeset.for_create(
      :create_reversal,
      %{
        org_id: org,
        entry_date: entry_date,
        memo: "document posting",
        source_key: source_key,
        source_id: Ash.UUID.generate(),
        lines: [
          %{account_id: wip.id, debit_cents: 40},
          %{account_id: cash.id, credit_cents: 40}
        ]
      },
      authorize?: false
    )
    |> Ash.create(authorize?: false)
  end

  # ── p1: the period is a row ────────────────────────────────────────────────

  describe "p1 — the fiscal period row" do
    test "born OPEN, unique per org and month (CONTROL: the next month lands)", %{
      org: org,
      admin: admin
    } do
      period = period!(admin, org, 2026, 9)
      assert period.status == :open
      assert period.closed_at == nil

      assert {:error, _} = period_changeset(admin, org, 2026, 9) |> Ash.create()
      assert {:ok, october} = period_changeset(admin, org, 2026, 10) |> Ash.create()
      assert october.status == :open
    end

    test "status is not caller input, and a month outside 1..12 is refused (RED)", %{
      org: org,
      admin: admin
    } do
      create_action = Ash.Resource.Info.action(FiscalPeriod, :create)
      refute :status in create_action.accept

      assert {:error, _} = period_changeset(admin, org, 2026, 13) |> Ash.create()
      assert {:error, _} = period_changeset(admin, org, 2026, 0) |> Ash.create()
    end
  end

  # ── p2: R10 at the door ───────────────────────────────────────────────────

  describe "p2 — R10: the posting gate" do
    test "a CLOSED period refuses the post (RED), the same entry posts in an OPEN period (CONTROL)",
         %{org: org, scope: scope, admin: admin} do
      sept = period!(admin, org, 2026, 9) |> then(&close!(&1, admin))
      _oct = period!(admin, org, 2026, 10)

      {:ok, blocked} = draft(scope, org, ~D[2026-09-15])
      result = post(blocked, scope)

      assert {:error, _} = result
      assert inspect(result) =~ "is CLOSED"
      assert inspect(result) =~ "R10"

      {:ok, open_entry} = draft(scope, org, ~D[2026-10-05])
      assert {:ok, posted} = post(open_entry, scope)
      assert posted.status == :posted
      assert sept.status == :closed
    end

    test "a SOFT-CLOSED period refuses a DOCUMENT post (RED) — sabotage 404's named test",
         %{org: org, scope: scope, admin: admin} do
      _sept = period!(admin, org, 2026, 9) |> then(&soft_close!(&1, admin))

      {:ok, entry} = draft(scope, org, ~D[2026-09-12], source_key: "ap_invoice")
      result = post(entry, scope)

      assert {:error, _} = result
      assert inspect(result) =~ "SOFT-CLOSED"
      assert inspect(result) =~ "documents may no longer land"
    end

    test "a SOFT-CLOSED period admits a journal-only adjustment (CONTROL)", %{
      org: org,
      scope: scope,
      admin: admin
    } do
      _sept = period!(admin, org, 2026, 9) |> then(&soft_close!(&1, admin))

      {:ok, entry} = draft(scope, org, ~D[2026-09-12])
      assert {:ok, posted} = post(entry, scope)
      assert posted.status == :posted
    end

    test "a SOFT-CLOSED period admits the ledger's own reversal anchor (CONTROL)", %{
      org: org,
      scope: scope,
      admin: admin
    } do
      _sept = period!(admin, org, 2026, 9) |> then(&soft_close!(&1, admin))

      {:ok, entry} = draft(scope, org, ~D[2026-09-12], source_key: "journal_entry")
      assert {:ok, posted} = post(entry, scope)
      assert posted.status == :posted
    end

    test "no period row means OPEN — the pre-Phase-3 behavior is unchanged (CONTROL)", %{
      org: org,
      scope: scope,
      admin: admin
    } do
      _sept = period!(admin, org, 2026, 9) |> then(&close!(&1, admin))

      # 2026-11 has no row at all: nothing is declared, so nothing is refused.
      {:ok, entry} = draft(scope, org, ~D[2026-11-03])
      assert {:ok, posted} = post(entry, scope)
      assert posted.status == :posted
    end

    test "a DOCUMENT posting born through the internal factory is refused in a closed period (RED)",
         %{org: org, scope: scope, admin: admin} do
      _sept = period!(admin, org, 2026, 9) |> then(&close!(&1, admin))
      _oct = period!(admin, org, 2026, 10)

      result = document_reversal(scope, org, ~D[2026-09-20], "ap_invoice")
      assert {:error, _} = result
      assert inspect(result) =~ "is CLOSED"

      # CONTROL: the same factory, called the way AP approval / the stock-receipt
      # bridge / the sales bridge call it — from inside an already-armed posting
      # writer — lands POSTED in the open October period. (The factory on its own
      # is not a public door: its marker convention is the calling writer's, which
      # is why the arm is part of the shape here and not a test convenience.)
      prior = PostingMarker.arm_now(@repo)

      try do
        assert {:ok, entry} = document_reversal(scope, org, ~D[2026-10-20], "ap_invoice")
        assert entry.status == :posted
      after
        PostingMarker.restore(@repo, prior)
      end
    end

    test "a void whose entry is dated in a closed period is refused up front (RED)", %{
      org: org,
      scope: scope,
      admin: admin
    } do
      sept = period!(admin, org, 2026, 9)

      {:ok, entry} = draft(scope, org, ~D[2026-09-15])
      {:ok, posted} = post(entry, scope)

      # The period closes over an entry that was posted BEFORE the close — legal.
      _closed = close!(sept, admin)

      result =
        posted |> Ash.Changeset.for_update(:void, %{}, scope: scope) |> Ash.update()

      assert {:error, _} = result
      assert inspect(result) =~ "is CLOSED"
    end
  end

  # ── p3: one-way ───────────────────────────────────────────────────────────

  describe "p3 — the close is one-way" do
    test "open → soft_closed → closed, stamped, with no edge back (RED + CONTROL)", %{
      org: org,
      admin: admin
    } do
      period = period!(admin, org, 2026, 9)

      soft = soft_close!(period, admin)
      assert soft.status == :soft_closed

      # No un-soft-close: the only edges out of :soft_closed lead to :closed.
      again = soft |> Ash.Changeset.for_update(:soft_close, %{}, scope: admin) |> Ash.update()
      assert {:error, _} = again
      assert inspect(again) =~ "one-way"

      closed = close!(soft, admin)
      assert closed.status == :closed
      assert closed.closed_at != nil

      reopen = closed |> Ash.Changeset.for_update(:close, %{}, scope: admin) |> Ash.update()
      assert {:error, _} = reopen

      back = closed |> Ash.Changeset.for_update(:soft_close, %{}, scope: admin) |> Ash.update()
      assert {:error, _} = back
    end

    test "open may close directly, and there is no reopen or destroy route", %{
      org: org,
      admin: admin
    } do
      period = period!(admin, org, 2026, 9)
      assert close!(period, admin).status == :closed

      assert Ash.Resource.Info.action(FiscalPeriod, :reopen) == nil
      assert Ash.Resource.Info.action(FiscalPeriod, :destroy) == nil
      assert Ash.Resource.Info.action(FiscalPeriod, :archive) == nil
    end
  end

  # ── p4: the database belt ─────────────────────────────────────────────────

  describe "p4 — the database belt" do
    test "a raw-SQL posted insert into an OPEN period lands (CONTROL)", %{org: org, admin: admin} do
      _sept = period!(admin, org, 2026, 9)

      assert {:ok, _} = raw_posted_entry(org, ~D[2026-09-10])
    end

    test "a raw-SQL posted insert into a CLOSED period is refused even with the marker armed (RED)",
         %{org: org, admin: admin} do
      _sept = period!(admin, org, 2026, 9) |> then(&close!(&1, admin))

      assert_raise Postgrex.Error, ~r/CLOSED fiscal period for this org/, fn ->
        raw_posted_entry(org, ~D[2026-09-10])
      end
    end
  end

  # ── p5: the Ash gate alone ────────────────────────────────────────────────

  describe "p5 — the Ash gate holds with the belt off (sabotage 404's named test)" do
    test "with the period trigger DISABLED, the closed-period post is still refused (RED)",
         %{org: org, scope: scope, admin: admin} do
      _sept = period!(admin, org, 2026, 9) |> then(&close!(&1, admin))

      {:ok, entry} = draft(scope, org, ~D[2026-09-15])

      disable_belt()

      try do
        result = post(entry, scope)
        assert {:error, _} = result
        assert inspect(result) =~ "is CLOSED"
      after
        enable_belt()
      end
    end
  end

  # ── p6: the R10 read mirror ───────────────────────────────────────────────

  describe "p6 — the R10 read mirror" do
    test "a period closed over entries posted BEFORE the close reads clean (CONTROL)", %{
      org: org,
      scope: scope,
      admin: admin
    } do
      sept = period!(admin, org, 2026, 9)

      {:ok, entry} = draft(scope, org, ~D[2026-09-15])
      {:ok, _posted} = post(entry, scope)

      _closed = close!(sept, admin)

      assert {:ok, true} = r10(org)
    end

    test "a posting that lands AFTER its period closed is DETECTED (anti-tautology)", %{
      org: org,
      admin: admin
    } do
      closed = period!(admin, org, 2026, 9) |> then(&close!(&1, admin))

      # The belt is what would refuse this; disable it to prove the READ is a
      # detector rather than a decoration (the sabotage shape an operator's
      # disabled trigger, a restore, or another process would leave behind).
      disable_belt()

      try do
        # The leg states its OWN ordering — one second after the close — instead
        # of reading `posted_at` off the database's `now()`. In the sandbox that
        # is the test transaction's start, so the verdict would otherwise depend
        # on whether the close happened to cross a wall-clock second.
        after_close = DateTime.add(closed.closed_at, 1, :second)

        assert {:ok, entry_id} = raw_posted_entry(org, ~D[2026-09-10], posted_at: after_close)
        assert {:ok, false} = r10(org)

        assert {:ok, [violation]} = r10_violations(org)
        assert violation.entry_id == entry_id
        assert violation.year == 2026
        assert violation.month == 9
        assert violation.posted_at != nil
      after
        enable_belt()
      end
    end
  end

  # ── p7: the close run ─────────────────────────────────────────────────────

  describe "p7 — the close run" do
    test "start seeds the doc's ten phases, one run per period", %{org: org, admin: admin} do
      period = period!(admin, org, 2026, 9)

      run = start_run!(admin, org, period.id)

      assert run.status == :in_progress
      assert run.started_at != nil
      assert length(run.phases) == 10
      assert Enum.map(run.phases, & &1["key"]) == ClosePhases.keys()
      assert Enum.all?(run.phases, &(&1["done_at"] == nil))

      # The phase list IS the manual's table, in its calendar order.
      assert ClosePhases.keys() == [
               "pre_close",
               "transaction_processing",
               "inventory_and_wip",
               "accruals_and_provisions",
               "grant_accounting",
               "variance_analysis",
               "reconciliations",
               "financial_statements",
               "rolling_forecast_update",
               "review_and_reporting"
             ]

      assert {:error, _} =
               CloseRun
               |> Ash.Changeset.for_create(:start, %{org_id: org, period_id: period.id}, scope: admin)
               |> Ash.create()
    end

    test "a phase completes by key; an unknown key is refused (RED); finish needs every phase",
         %{org: org, admin: admin} do
      period = period!(admin, org, 2026, 9)
      run = start_run!(admin, org, period.id)

      done = complete!(run, admin, "pre_close")
      assert Enum.find(done.phases, &(&1["key"] == "pre_close"))["done_at"] != nil

      unknown = complete(run, admin, "invented_phase")
      assert {:error, _} = unknown
      assert inspect(unknown) =~ "unknown close phase"

      early = run |> Ash.Changeset.for_update(:finish, %{}, scope: admin) |> Ash.update()
      assert {:error, _} = early
      assert inspect(early) =~ "still open"

      finished =
        Enum.reduce(ClosePhases.keys(), run, fn key, acc -> complete!(acc, admin, key) end)
        |> then(fn r -> r |> Ash.Changeset.for_update(:finish, %{}, scope: admin) |> Ash.update!() end)

      assert finished.status == :completed
      assert finished.completed_at != nil

      # A completed run is final.
      assert {:error, _} = finished |> Ash.Changeset.for_update(:finish, %{}, scope: admin) |> Ash.update()
      later = complete(finished, admin, "reconciliations")
      assert {:error, _} = later
      assert inspect(later) =~ "COMPLETED"
    end
  end

  # ── plumbing ───────────────────────────────────────────────────────────────

  # The read mirror takes the per-mount resources (the scope is materialized per
  # host namespace), so the p6 legs hand it this fixture's pair.
  defp r10(org) do
    PeriodReconcile.clean?(org, @repo, entry_resource: JournalEntry, period_resource: FiscalPeriod)
  end

  defp r10_violations(org) do
    PeriodReconcile.violations(org, @repo,
      entry_resource: JournalEntry,
      period_resource: FiscalPeriod
    )
  end

  defp start_run!(scope, org, period_id) do
    CloseRun
    |> Ash.Changeset.for_create(:start, %{org_id: org, period_id: period_id}, scope: scope)
    |> Ash.create!()
  end

  defp complete(run, scope, key) do
    run
    |> Ash.Changeset.for_update(:complete_phase, %{phase: key}, scope: scope)
    |> Ash.update()
  end

  defp complete!(run, scope, key) do
    assert {:ok, updated} = complete(run, scope, key)
    updated
  end

  # The PostGuard marker is armed the way any sanctioned posting writer arms it,
  # so the raw insert gets PAST the immutability belt and reaches the period belt
  # (the point of the leg: the period belt does not consult the marker at all).
  # `posted_at` is a caller choice so a leg can state its ordering against a
  # known close stamp rather than against the transaction's `now()`. The value
  # goes over as a naive UTC datetime, matching the column.
  defp raw_posted_entry(org, %Date{} = entry_date, opts \\ []) do
    posted_at =
      opts
      |> Keyword.get(:posted_at, DateTime.utc_now())
      |> DateTime.to_naive()

    Ecto.Adapters.SQL.query!(@repo, "SELECT set_config('samen.finance_posting', 'on', true)", [])

    %{rows: [[entry_bin]]} =
      Ecto.Adapters.SQL.query!(
        @repo,
        "INSERT INTO sje_journal_entry (sje_id, sje_org_id, sje_entry_date, sje_memo, " <>
          "sje_status, sje_posted_at, sje_inserted_at, sje_updated_at) VALUES " <>
          "(gen_random_uuid(), $1, $2, 'raw period leg', 'posted', $3, " <>
          "timezone('utc', now()), timezone('utc', now())) RETURNING sje_id",
        [Ecto.UUID.dump!(org), entry_date, posted_at]
      )

    {:ok, Ecto.UUID.load!(entry_bin)}
  end

  defp disable_belt do
    Ecto.Adapters.SQL.query!(
      @repo,
      "ALTER TABLE sje_journal_entry DISABLE TRIGGER sje_journal_entry_period_guard_tg",
      []
    )
  end

  defp enable_belt do
    Ecto.Adapters.SQL.query!(
      @repo,
      "ALTER TABLE sje_journal_entry ENABLE TRIGGER sje_journal_entry_period_guard_tg",
      []
    )
  end
end
