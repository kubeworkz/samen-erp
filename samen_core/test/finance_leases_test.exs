defmodule Samen.FinanceLeasesTest do
  @moduledoc """
  Lease accounting — the derived IFRS 16 schedule, commencement entry,
  exactly-once monthly payment run, append-only facts and register.
  """

  use ExUnit.Case, async: false

  require Ash.Query

  alias Samen.Scopes.Finance.{LeasePaymentRun, LeaseRegister, LeaseSchedule}

  alias SamenCore.Support.FinanceFixture.{
    Account,
    CostObject,
    FiscalPeriod,
    JournalEntry,
    JournalLine,
    LeasePayment
  }

  alias SamenCore.Support.FinanceFixture.Lease, as: LeaseResource

  @repo SamenCore.TestRepo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(@repo)
    org = Ash.UUID.generate()
    admin = admin_scope(org)

    previous = Application.get_env(:samen_core, LeasePaymentRun)

    Application.put_env(:samen_core, LeasePaymentRun,
      modules: [lease: LeaseResource, payment: LeasePayment]
    )

    on_exit(fn ->
      if previous do
        Application.put_env(:samen_core, LeasePaymentRun, previous)
      else
        Application.delete_env(:samen_core, LeasePaymentRun)
      end
    end)

    books = books!(admin, org)

    {:ok, org: org, admin: admin, books: books}
  end

  test "the derived lease schedule closes the liability and ROU exactly", %{books: books} do
    lease = lease_attrs(books.accounts, %{})
    initial = LeaseSchedule.initial_liability(lease)
    slices = LeaseSchedule.slices(lease)

    assert initial > 0
    assert initial < lease.payment_cents * lease.months
    assert length(slices) == lease.months
    assert Enum.sum(Enum.map(slices, & &1.principal_cents)) == initial
    assert Enum.sum(Enum.map(slices, & &1.amortization_cents)) == initial
    assert Enum.sum(Enum.map(slices, & &1.payment_cents)) == lease.payment_cents * lease.months

    assert List.last(slices).liability_closing_cents == 0
    assert List.last(slices).rou_closing_cents == 0
    assert Enum.all?(slices, &(&1.interest_cents >= 0))
    assert LeaseSchedule.parse_period("2026-01") == {:ok, {2026, 1}}
    assert LeaseSchedule.parse_period("2026-1") == :error
  end

  test "creating a lease posts the commencement entry", %{org: org, admin: admin, books: books} do
    lease = create_lease!(admin, org, books)
    initial = LeaseSchedule.initial_liability(lease)

    entry = anchor_entry!(org, "lease_initial", lease.id)
    lines = entry_lines(org, entry.id)

    assert lease.initial_entry_id == entry.id
    assert entry.status == :posted
    assert entry.entry_date == lease.start_on

    assert Enum.sort(Enum.map(lines, &{&1.account_id, &1.debit_cents, &1.credit_cents})) ==
             Enum.sort([
               {books.accounts.rou.id, initial, 0},
               {books.accounts.liability.id, 0, initial}
             ])

    assert Enum.all?(
             lines,
             &(&1.dimension_refs["project"] == books.cost_object.id)
           )
  end

  test "a monthly payment posts interest, principal and ROU amortization once", %{
    org: org,
    admin: admin,
    books: books
  } do
    lease = create_lease!(admin, org, books)
    row = LeaseSchedule.slice(lease, "2026-01") |> elem(1)

    assert {:ok, %{posted: [payment_id]}} = run(2026, 1)

    [payment] = payments(org)
    assert payment.id == payment_id
    assert payment.payment_cents == row.payment_cents
    assert payment.interest_cents == row.interest_cents
    assert payment.principal_cents == row.principal_cents
    assert payment.amortization_cents == row.amortization_cents
    assert payment.paid_on == ~D[2026-01-31]

    entry = anchor_entry!(org, "lease_payment", payment.id)
    lines = entry_lines(org, entry.id)

    assert Enum.sort(Enum.map(lines, &{&1.account_id, &1.debit_cents, &1.credit_cents})) ==
             Enum.sort([
               {books.accounts.interest.id, row.interest_cents, 0},
               {books.accounts.amortization.id, row.amortization_cents, 0},
               {books.accounts.liability.id, row.principal_cents, 0},
               {books.accounts.accumulated.id, 0, row.amortization_cents},
               {books.accounts.cash.id, 0, row.payment_cents}
             ])

    assert Enum.sum(Enum.map(lines, & &1.debit_cents)) ==
             Enum.sum(Enum.map(lines, & &1.credit_cents))

    assert {:ok, %{posted: [], skipped: [{lease_id, :already_paid}]}} = run(2026, 1)
    assert lease_id == lease.id
    assert length(payments(org)) == 1
    assert length(entries(org, "lease_payment")) == 1

    # The unique index is the belt below the run read.
    assert {:error, err} =
             LeasePayment
             |> Ash.Changeset.for_create(
               :pay,
               %{
                 org_id: org,
                 lease_id: lease.id,
                 period_key: "2026-01",
                 paid_on: ~D[2026-01-31]
               },
               authorize?: false
             )
             |> Ash.create(authorize?: false)

    assert Exception.message(err) =~ "lsf_period_unique"

    # Append-only: the trigger refuses a raw UPDATE even below Ash.
    assert {:error, %Postgrex.Error{postgres: %{message: message}}} =
             @repo.query(
               "UPDATE lsf_lease_payment SET lsf_interest_cents = 1 WHERE lsf_id = $1",
               [Ecto.UUID.dump!(payment.id)]
             )

    assert message =~ "append-only"
  end

  test "the full term clears the liability and ROU in the register", %{
    org: org,
    admin: admin,
    books: books
  } do
    lease = create_lease!(admin, org, books)

    for month <- 1..3 do
      assert {:ok, %{posted: [_]}} = run(2026, month)
    end

    register = LeaseRegister.for_org(org, lease: LeaseResource, payment: LeasePayment)
    [row] = register.leases

    assert row.fully_paid?
    assert row.liability_cents == 0
    assert row.rou_net_cents == 0
    assert row.next_open_period == nil
    assert row.paid_cents == lease.payment_cents * lease.months
    assert row.initial_liability_cents == LeaseSchedule.initial_liability(lease)
    assert register.totals.liability_cents == 0
    assert register.totals.rou_net_cents == 0
  end

  test "the account shape guard refuses a non-asset ROU account", %{
    org: org,
    admin: admin,
    books: books
  } do
    bad_rou = new_account(admin, org, "9999", :liability, :credit)

    attrs =
      lease_attrs(books.accounts, %{
        org_id: org,
        code: "LEASE-BAD",
        rou_asset_account_id: bad_rou.id
      })

    assert {:error, %Ash.Error.Invalid{} = err} =
             LeaseResource
             |> Ash.Changeset.for_create(:create, attrs, scope: admin)
             |> Ash.create()

    assert Exception.message(err) =~ "debit-normal asset account"
  end

  test "the account shape guard refuses duplicate accounts", %{
    org: org,
    admin: admin,
    books: books
  } do
    attrs =
      lease_attrs(books.accounts, %{
        org_id: org,
        code: "LEASE-DUPLICATE",
        cash_account_id: books.accounts.rou.id
      })

    assert {:error, %Ash.Error.Invalid{} = err} =
             LeaseResource
             |> Ash.Changeset.for_create(:create, attrs, scope: admin)
             |> Ash.create()

    assert Exception.message(err) =~ "must all be different"
  end

  test "a closed period refuses the payment and leaves no fact", %{
    org: org,
    admin: admin,
    books: books
  } do
    _lease = create_lease!(admin, org, books)
    close!(admin, org, 2026, 1)

    assert {:error, {:lease_payment_failed, [{_lease_id, %Ash.Error.Invalid{} = err}]}} =
             run(2026, 1)

    assert Exception.message(err) =~ "closed"
    assert payments(org) == []
    assert entries(org, "lease_payment") == []
  end

  test "the monthly lease worker rides the canonical crontab" do
    assert {"55 0 1 * *", Samen.Scopes.Finance.LeasePaymentWorker} in Samen.Jobs.default_crontab()
  end

  test "an unconfigured host is an explicit no-op" do
    Application.delete_env(:samen_core, LeasePaymentRun)

    assert {:ok,
            %{
              period: "2026-01",
              posted: [],
              skipped: [],
              state: :not_configured
            }} = run(2026, 1)
  end

  defp run(year, month) do
    LeasePaymentRun.run(period: {year, month})
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
    accounts = %{
      rou: new_account(admin, org, "1600", :asset, :debit),
      accumulated: new_account(admin, org, "1610", :asset, :credit),
      liability: new_account(admin, org, "2500", :liability, :credit),
      interest: new_account(admin, org, "6800", :expense, :debit),
      amortization: new_account(admin, org, "6810", :expense, :debit),
      cash: new_account(admin, org, "1000", :asset, :debit)
    }

    cost_object =
      CostObject
      |> Ash.Changeset.for_create(
        :create,
        %{org_id: org, code: "LEASE-OFFICE", name: "Office lease", kind: :project},
        scope: admin
      )
      |> Ash.create!()

    %{accounts: accounts, cost_object: cost_object}
  end

  defp lease_attrs(accounts, attrs) do
    Map.merge(
      %{
        code: "LEASE-#{System.unique_integer([:positive])}",
        name: "Office lease",
        kind: :office,
        start_on: ~D[2026-01-15],
        months: 3,
        payment_cents: 100_000,
        annual_rate_bps: 500,
        rou_asset_account_id: accounts.rou.id,
        accumulated_amortization_account_id: accounts.accumulated.id,
        lease_liability_account_id: accounts.liability.id,
        interest_expense_account_id: accounts.interest.id,
        amortization_expense_account_id: accounts.amortization.id,
        cash_account_id: accounts.cash.id,
        dimension_key: :project
      },
      attrs
    )
  end

  defp create_lease!(admin, org, books) do
    attrs =
      lease_attrs(books.accounts, %{
        org_id: org,
        cost_object_id: books.cost_object.id
      })

    LeaseResource
    |> Ash.Changeset.for_create(:create, attrs, scope: admin)
    |> Ash.create!()
  end

  defp payments(org) do
    LeasePayment
    |> Ash.Query.filter(org_id == ^org)
    |> Ash.Query.sort(period_key: :asc)
    |> Ash.read!(authorize?: false)
  end

  defp entries(org, source_key) do
    JournalEntry
    |> Ash.Query.filter(org_id == ^org and source_key == ^source_key)
    |> Ash.Query.sort(entry_date: :asc)
    |> Ash.read!(authorize?: false)
  end

  defp anchor_entry!(org, source_key, source_id) do
    JournalEntry
    |> Ash.Query.filter(org_id == ^org and source_key == ^source_key and source_id == ^source_id)
    |> Ash.read_one!(authorize?: false)
  end

  defp entry_lines(org, entry_id) do
    JournalLine
    |> Ash.Query.filter(org_id == ^org and entry_id == ^entry_id)
    |> Ash.read!(authorize?: false)
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
