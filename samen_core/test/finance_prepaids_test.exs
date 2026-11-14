defmodule Samen.FinancePrepaidsTest do
  @moduledoc """
  WS-ACCT prepaid expense slice — the derived schedule, exactly-once release
  run, posting cascade and register.

    * p1 the last month absorbs the division remainder and the term sums exactly;
    * p2 a release posts Dr expense / Cr prepaid, anchored and dimensioned;
    * p3 a repeated sweep is a clean no-op (the unique index is the belt);
    * p4 periods outside the term post nothing, while the first term month posts;
    * p5 the full term releases the total and completes the register;
    * p6 the shape guard refuses a non-asset prepaid account (CONTROL: valid one creates);
    * p7 a closed period refuses the release and leaves no row or entry;
    * p8 an unconfigured host is an explicit no-op, not a silent success;
    * p9 the monthly release worker rides the canonical crontab.
  """

  use ExUnit.Case, async: false

  require Ash.Query

  alias Samen.Scopes.Finance.{
    PrepaidRegister,
    PrepaidReleaseRun,
    PrepaidSchedule,
    PrepaidReleasePosting
  }

  alias SamenCore.Support.FinanceFixture.{
    Account,
    CostObject,
    FiscalPeriod,
    JournalEntry,
    JournalLine,
    PrepaidRelease
  }

  alias SamenCore.Support.FinanceFixture.PrepaidSchedule, as: PrepaidScheduleResource

  @repo SamenCore.TestRepo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(@repo)
    org = Ash.UUID.generate()

    prev = Application.get_env(:samen_core, PrepaidReleaseRun)

    Application.put_env(:samen_core, PrepaidReleaseRun,
      modules: [
        schedule: PrepaidScheduleResource,
        release: PrepaidRelease,
        entry: JournalEntry,
        account: Account
      ]
    )

    on_exit(fn ->
      if prev do
        Application.put_env(:samen_core, PrepaidReleaseRun, prev)
      else
        Application.delete_env(:samen_core, PrepaidReleaseRun)
      end
    end)

    {:ok, org: org, admin: admin_scope(org), tenant: tenant_scope(org)}
  end

  # ── p1: the arithmetic ────────────────────────────────────────────────────

  test "the derived prepaid schedule puts the remainder in the final month", %{
    org: org,
    admin: admin
  } do
    books = books!(admin, org)
    schedule = schedule!(admin, org, books, %{total_cents: 10_000, months: 3})

    slices = PrepaidSchedule.slices(schedule)
    assert Enum.map(slices, & &1.amount_cents) == [3_333, 3_333, 3_334]
    assert Enum.map(slices, & &1.period_key) == ["2026-01", "2026-02", "2026-03"]
    assert Enum.sum(Enum.map(slices, & &1.amount_cents)) == 10_000
    assert List.last(slices).cumulative_cents == 10_000

    assert {:ok, 3_333} = PrepaidSchedule.slice(schedule, "2026-01")
    assert {:ok, 3_334} = PrepaidSchedule.slice(schedule, "2026-03")
    assert :outside_term = PrepaidSchedule.slice(schedule, "2025-12")
    assert :outside_term = PrepaidSchedule.slice(schedule, "2026-04")
    assert {:error, :bad_period} = PrepaidSchedule.slice(schedule, "2026-13")
  end

  # ── p2: the release pair ──────────────────────────────────────────────────

  test "a release posts Dr expense / Cr prepaid on the schedule's dimension", %{
    org: org,
    admin: admin
  } do
    books = books!(admin, org)
    _schedule = schedule!(admin, org, books, %{total_cents: 10_000, months: 3})

    assert {:ok, %{posted: [release_id]}} = run(2026, 1)

    [release] = releases(org)
    assert release.id == release_id
    assert release.period_key == "2026-01"
    assert release.amount_cents == 3_333
    assert release.released_on == ~D[2026-01-31]
    assert release.prepaid_account_id == books.prepaid.id
    assert release.expense_account_id == books.expense.id

    entry = entry_for!(org, release.id)
    assert entry.status == :posted
    assert entry.entry_date == ~D[2026-01-31]
    assert entry.source_key == PrepaidReleasePosting.source_key()
    assert entry.source_id == release.id

    assert Enum.sort(
             Enum.map(
               entry_lines(org, entry.id),
               &{&1.account_id, &1.debit_cents, &1.credit_cents}
             )
           ) ==
             Enum.sort([
               {books.expense.id, 3_333, 0},
               {books.prepaid.id, 0, 3_333}
             ])

    assert Enum.all?(
             entry_lines(org, entry.id),
             &(&1.dimension_refs["project"] == books.cost_object.id)
           )

    register = register(org)
    [row] = register.schedules
    assert row.released_cents == 3_333
    assert row.remaining_cents == 6_667
    assert row.next_open_period == "2026-02"
    refute row.fully_released?
  end

  # ── p3: exactly once ──────────────────────────────────────────────────────

  test "a repeated prepaid sweep is a clean no-op", %{org: org, admin: admin} do
    books = books!(admin, org)
    schedule = schedule!(admin, org, books, %{total_cents: 10_000, months: 3})

    assert {:ok, %{posted: [first]}} = run(2026, 1)
    assert {:ok, %{posted: [], skipped: [{schedule_id, :already_released}]}} = run(2026, 1)
    assert schedule_id == schedule.id

    assert length(releases(org)) == 1
    assert length(entries(org)) == 1

    # The unique index is the belt below the run's read: a direct duplicate
    # create is refused even with authorization bypassed.
    assert {:error, err} =
             PrepaidRelease
             |> Ash.Changeset.for_create(
               :release,
               %{
                 org_id: org,
                 schedule_id: schedule.id,
                 period_key: "2026-01",
                 amount_cents: 3_333,
                 released_on: ~D[2026-01-31]
               },
               authorize?: false
             )
             |> Ash.create(authorize?: false)

    assert Exception.message(err) =~ "psf_period_unique"

    # Append-only: the trigger refuses a raw UPDATE even below Ash.
    assert {:error, %Postgrex.Error{postgres: %{message: message}}} =
             @repo.query(
               "UPDATE psf_prepaid_release SET psf_amount_cents = 1 WHERE psf_id = $1",
               [Ecto.UUID.dump!(first)]
             )

    assert message =~ "append-only"
  end

  # ── p4: term boundaries ───────────────────────────────────────────────────

  test "periods outside the prepaid term post nothing", %{org: org, admin: admin} do
    books = books!(admin, org)
    _schedule = schedule!(admin, org, books, %{start_on: ~D[2026-03-15]})

    assert {:ok, %{posted: [], skipped: [{_, :outside_term}]}} = run(2026, 2)
    assert {:ok, %{posted: [], skipped: [{_, :outside_term}]}} = run(2026, 6)
    assert releases(org) == []
    assert entries(org) == []

    # CONTROL: the first term month posts.
    assert {:ok, %{posted: [_]}} = run(2026, 3)
    assert [%{period_key: "2026-03"}] = releases(org)
  end

  # ── p5: full term ─────────────────────────────────────────────────────────

  test "the full term releases the total and completes the register", %{
    org: org,
    admin: admin
  } do
    books = books!(admin, org)
    _schedule = schedule!(admin, org, books, %{total_cents: 10_000, months: 3})

    for month <- 1..3 do
      assert {:ok, %{posted: [_]}} = run(2026, month)
    end

    assert Enum.map(releases(org), & &1.amount_cents) == [3_333, 3_333, 3_334]
    assert Enum.sum(Enum.map(releases(org), & &1.amount_cents)) == 10_000

    register = register(org)
    [row] = register.schedules
    assert row.released_cents == 10_000
    assert row.remaining_cents == 0
    assert row.next_open_period == nil
    assert row.fully_released?

    assert {:ok, %{posted: [], skipped: [{_, :fully_released}]}} = run(2026, 4)
  end

  # ── p6: account shape ─────────────────────────────────────────────────────

  test "the prepaid account must be a debit-normal asset", %{org: org, admin: admin} do
    books = books!(admin, org)
    liability = new_account(admin, org, "2000", :liability, :credit)

    assert {:error, %Ash.Error.Invalid{} = err} =
             PrepaidScheduleResource
             |> Ash.Changeset.for_create(
               :create,
               schedule_attrs(org, books, %{
                 prepaid_account_id: liability.id,
                 code: "PREPAID-BAD"
               }),
               scope: admin
             )
             |> Ash.create()

    assert Exception.message(err) =~ "debit-normal asset account"

    # CONTROL: the same shape with the real prepaid account creates.
    assert {:ok, _schedule} =
             PrepaidScheduleResource
             |> Ash.Changeset.for_create(
               :create,
               schedule_attrs(org, books, %{code: "PREPAID-GOOD"}),
               scope: admin
             )
             |> Ash.create()
  end

  # ── p7: closed period ─────────────────────────────────────────────────────

  test "a closed period refuses the release and leaves no fact", %{org: org, admin: admin} do
    books = books!(admin, org)
    _schedule = schedule!(admin, org, books)
    close!(admin, org, 2026, 1)

    assert {:error, {:prepaid_release_failed, [{_schedule_id, %Ash.Error.Invalid{} = err}]}} =
             run(2026, 1)

    assert Exception.message(err) =~ "closed"
    assert releases(org) == []
    assert entries(org) == []
  end

  # ── p8: unconfigured host ─────────────────────────────────────────────────

  test "an unconfigured host is an explicit no-op", %{org: org} do
    Application.delete_env(:samen_core, PrepaidReleaseRun)

    assert {:ok,
            %{
              period: "2026-01",
              posted: [],
              skipped: [],
              state: :not_configured
            }} = run(2026, 1)

    assert releases(org) == []
  end

  # ── p9: the cron ──────────────────────────────────────────────────────────

  test "the monthly prepaid release worker rides the canonical crontab" do
    assert {"50 0 1 * *", Samen.Scopes.Finance.PrepaidReleaseWorker} in Samen.Jobs.default_crontab()
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

  defp new_account(admin, org, code, kind, side) do
    Account
    |> Ash.Changeset.for_create(
      :create,
      %{org_id: org, code: code, name: "Account #{code}", kind: kind, normal_side: side},
      scope: admin
    )
    |> Ash.create!()
  end

  defp books!(admin, org) do
    %{
      prepaid: new_account(admin, org, "1200", :asset, :debit),
      expense: new_account(admin, org, "7000", :expense, :debit),
      cost_object: cost_object!(admin, org)
    }
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

  defp schedule_attrs(org, books, attrs) do
    Map.merge(
      %{
        org_id: org,
        code: "PREPAID-#{System.unique_integer([:positive])}",
        name: "Prepaid expense",
        total_cents: 10_000,
        start_on: ~D[2026-01-15],
        months: 3,
        prepaid_account_id: books.prepaid.id,
        expense_account_id: books.expense.id,
        cost_object_id: books.cost_object.id,
        dimension_key: :project
      },
      attrs
    )
  end

  defp schedule!(admin, org, books, attrs \\ %{}) do
    PrepaidScheduleResource
    |> Ash.Changeset.for_create(:create, schedule_attrs(org, books, attrs), scope: admin)
    |> Ash.create!()
  end

  defp run(year, month) do
    PrepaidReleaseRun.run(period: {year, month})
  end

  defp releases(org) do
    PrepaidRelease
    |> Ash.Query.filter(org_id == ^org)
    |> Ash.Query.sort(period_key: :asc)
    |> Ash.read!(authorize?: false)
  end

  defp entries(org) do
    JournalEntry
    |> Ash.Query.filter(org_id == ^org and source_key == "prepaid_release")
    |> Ash.read!(authorize?: false)
  end

  defp entry_for!(org, release_id) do
    JournalEntry
    |> Ash.Query.filter(
      org_id == ^org and source_key == "prepaid_release" and source_id == ^release_id
    )
    |> Ash.read_one!(authorize?: false)
  end

  defp entry_lines(org, entry_id) do
    JournalLine
    |> Ash.Query.filter(org_id == ^org and entry_id == ^entry_id)
    |> Ash.read!(authorize?: false)
  end

  defp register(org) do
    PrepaidRegister.for_org(org, schedule: PrepaidScheduleResource, release: PrepaidRelease)
  end

  defp close!(admin, org, year, month) do
    period =
      FiscalPeriod
      |> Ash.Changeset.for_create(:create, %{org_id: org, year: year, month: month}, scope: admin)
      |> Ash.create!()

    period
    |> Ash.Changeset.for_update(:close, %{}, scope: admin)
    |> Ash.update!()
  end
end
