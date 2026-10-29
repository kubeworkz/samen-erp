defmodule Samen.FinanceDimensionsTest do
  @moduledoc """
  WS-ACCT Phase 1 (ADR-054 D1/D2, design §3 R6) — the cost-object seam and the
  posting map, mounted via `test/support/finance_fixture.ex`.

  Every refusal is paired with a positive control (anti-tautology, `Samen.RedPath`
  discipline):

    * d1 `CostObject` — create/read, `code` unique per org, admin-gated writes;
    * d2 the DIMENSION GUARD: the four frozen keys are accepted (CONTROL); an
      unknown key is refused; a free-text value is refused (ids only — the
      de-anonymisation channel); a cross-org cost object is refused;
    * d3 R6a — a partially dimensioned entry is refused, the fully dimensioned
      twin lands (CONTROL);
    * d4 R6b — an entry that balances ORG-WIDE but not per cost object is
      refused (this is sabotage 403's named test), the per-cost-object balanced
      twin lands (CONTROL);
    * d5 the R6 READ is load-bearing: dimensioned lines forced in BELOW the
      guard (raw SQL, the sabotage shape) make `DimensionReconcile.balanced?/3`
      false and show up as a non-zero cost-object balance — the read is a
      detector, not a decoration;
    * d6 a void's reversing entry mirrors the dimensions, so the pair still nets
      to zero per cost object;
    * d7 the posting map (ADR-054 D2) accepts the widened meanings and still
      refuses one it does not know.
  """
  use ExUnit.Case, async: false

  require Ash.Query

  alias Samen.Scopes.Finance.DimensionReconcile
  alias SamenCore.Support.FinanceFixture.{Account, CostObject, JournalEntry, JournalLine, PostingAccount}

  @repo SamenCore.TestRepo
  @lines [line_resource: JournalLine]

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

  defp new_account(scope, org, code, kind \\ :asset, side \\ :debit) do
    Account
    |> Ash.Changeset.for_create(
      :create,
      %{org_id: org, code: code, name: "Account #{code}", kind: kind, normal_side: side},
      scope: scope
    )
    |> Ash.create!()
  end

  defp new_cost_object(scope, org, code, kind \\ :project) do
    CostObject
    |> Ash.Changeset.for_create(
      :create,
      %{org_id: org, code: code, name: "Cost object #{code}", kind: kind},
      scope: scope
    )
    |> Ash.create!()
  end

  defp entry_changeset(scope, org, lines) do
    JournalEntry
    |> Ash.Changeset.for_create(
      :create,
      %{org_id: org, entry_date: ~D[2026-10-28], memo: "dimensioned", lines: lines},
      scope: scope
    )
  end

  defp create_entry(scope, org, lines), do: entry_changeset(scope, org, lines) |> Ash.create()

  defp post!(entry, scope) do
    Ash.Changeset.for_update(entry, :post, %{}, scope: scope) |> Ash.update!()
  end

  defp message(%Ash.Error.Invalid{} = error), do: Exception.message(error)

  # ── d1: the registry ───────────────────────────────────────────────────────

  describe "d1 — CostObject: the cost/analysis registry" do
    test "a cost object is created and read back on the tenant plane", %{
      org: org,
      scope: scope,
      admin: admin
    } do
      co = new_cost_object(admin, org, "RISCV64", :project)
      assert co.kind == :project

      assert [read] = CostObject |> Ash.Query.filter(code: "RISCV64") |> Ash.read!(scope: scope)
      assert read.id == co.id
    end

    test "kind is a closed enum (RED) and every documented kind is accepted (CONTROL)", %{
      org: org,
      admin: admin
    } do
      for kind <- [:project, :chip, :cost_pool, :fund] do
        assert %CostObject{kind: ^kind} = new_cost_object(admin, org, "K#{kind}", kind)
      end

      bad =
        CostObject
        |> Ash.Changeset.for_create(
          :create,
          %{org_id: org, code: "BAD", name: "bad", kind: :department},
          scope: admin
        )
        |> Ash.create()

      assert {:error, %Ash.Error.Invalid{}} = bad
    end

    test "code is unique per org (RED) — the Account discipline", %{org: org, admin: admin} do
      _ = new_cost_object(admin, org, "GPU")

      dup =
        CostObject
        |> Ash.Changeset.for_create(
          :create,
          %{org_id: org, code: "GPU", name: "duplicate", kind: :chip},
          scope: admin
        )
        |> Ash.create()

      assert {:error, _} = dup
      assert length(CostObject |> Ash.read!(scope: admin)) == 1
    end

    test "a member cannot mint a cost object — the axis is an admin decision (RED)", %{
      org: org,
      scope: scope
    } do
      denied =
        CostObject
        |> Ash.Changeset.for_create(
          :create,
          %{org_id: org, code: "GHOST", name: "ghost", kind: :project},
          scope: scope
        )
        |> Ash.create()

      assert {:error, %Ash.Error.Forbidden{}} = denied
      assert CostObject |> Ash.read!(scope: scope) == []
    end
  end

  # ── d2: the dimension guard ────────────────────────────────────────────────

  describe "d2 — DimensionGuard: frozen keys, ids only, same org" do
    test "all four frozen keys are ACCEPTED (CONTROL — not a blanket refusal)", %{
      org: org,
      scope: scope,
      admin: admin
    } do
      project = new_cost_object(admin, org, "PTA", :project)
      lot = new_cost_object(admin, org, "LOT-1", :chip)
      fund = new_cost_object(admin, org, "GRANT-1", :fund)
      pool = new_cost_object(admin, org, "FOUNDRY", :cost_pool)

      wip = new_account(scope, org, "1200")
      cash = new_account(scope, org, "1000")

      refs = %{
        "project" => project.id,
        "lot" => lot.id,
        "fund" => fund.id,
        "cost_pool" => pool.id
      }

      # R6b: with four axes tagged on both legs, every cost object nets to zero.
      assert {:ok, entry} =
               create_entry(scope, org, [
                 %{account_id: wip.id, debit_cents: 500, dimension_refs: refs},
                 %{account_id: cash.id, credit_cents: 500, dimension_refs: refs}
               ])

      assert %JournalEntry{status: :posted} = post!(entry, scope)

      assert {:ok, rows} = DimensionReconcile.balances(org, @repo, @lines)
      assert length(rows) == 4
      assert Enum.all?(rows, &(&1.balance_cents == 0))
      assert Enum.sort(Enum.map(rows, & &1.key)) == ["cost_pool", "fund", "lot", "project"]
      assert {:ok, true} = DimensionReconcile.balanced?(org, @repo, @lines)
    end

    test "an unknown key is REFUSED — the vocabulary is a kernel decision (RED)", %{
      org: org,
      scope: scope,
      admin: admin
    } do
      project = new_cost_object(admin, org, "GPU", :chip)
      wip = new_account(scope, org, "1200")
      cash = new_account(scope, org, "1000")

      result =
        create_entry(scope, org, [
          %{account_id: wip.id, debit_cents: 100, dimension_refs: %{"dept" => project.id}},
          %{account_id: cash.id, credit_cents: 100, dimension_refs: %{"dept" => project.id}}
        ])

      assert {:error, %Ash.Error.Invalid{} = err} = result
      assert message(err) =~ "unknown dimension key"
      assert JournalEntry |> Ash.read!(scope: scope) == []
    end

    test "a FREE-TEXT value is refused — dimensions carry ids, never names (RED)", %{
      org: org,
      scope: scope
    } do
      wip = new_account(scope, org, "1200")
      cash = new_account(scope, org, "1000")

      result =
        create_entry(scope, org, [
          %{
            account_id: wip.id,
            debit_cents: 100,
            dimension_refs: %{"project" => "RISC-V64 SoC (Jane Doe)"}
          },
          %{
            account_id: cash.id,
            credit_cents: 100,
            dimension_refs: %{"project" => "RISC-V64 SoC (Jane Doe)"}
          }
        ])

      assert {:error, %Ash.Error.Invalid{} = err} = result
      assert message(err) =~ "must be a CostObject ID"
      assert JournalLine |> Ash.read!(authorize?: false, scope: scope) == []
    end

    test "a CROSS-ORG cost object is refused (RED), the same-org twin accepted (CONTROL)", %{
      org: org,
      scope: scope,
      admin: admin
    } do
      foreign_org = Ash.UUID.generate()
      foreign = new_cost_object(admin_scope(foreign_org), foreign_org, "FOREIGN", :project)
      own = new_cost_object(admin, org, "PTA", :project)

      wip = new_account(scope, org, "1200")
      cash = new_account(scope, org, "1000")

      cross =
        create_entry(scope, org, [
          %{account_id: wip.id, debit_cents: 100, dimension_refs: %{"project" => foreign.id}},
          %{account_id: cash.id, credit_cents: 100, dimension_refs: %{"project" => foreign.id}}
        ])

      assert {:error, %Ash.Error.Invalid{} = err} = cross
      assert message(err) =~ "not in this org"

      assert {:ok, _entry} =
               create_entry(scope, org, [
                 %{account_id: wip.id, debit_cents: 100, dimension_refs: %{"project" => own.id}},
                 %{account_id: cash.id, credit_cents: 100, dimension_refs: %{"project" => own.id}}
               ])
    end
  end

  # ── d3/d4: R6 ──────────────────────────────────────────────────────────────

  describe "d3/d4 — R6: per-cost-object balance" do
    test "a PARTIALLY dimensioned entry is refused (R6a RED)", %{org: org, scope: scope, admin: admin} do
      project = new_cost_object(admin, org, "PTA", :project)
      wip = new_account(scope, org, "1200")
      cash = new_account(scope, org, "1000")

      result =
        create_entry(scope, org, [
          %{account_id: wip.id, debit_cents: 100, dimension_refs: %{"project" => project.id}},
          %{account_id: cash.id, credit_cents: 100}
        ])

      assert {:error, %Ash.Error.Invalid{} = err} = result
      assert message(err) =~ "partial dimension set"
      assert JournalEntry |> Ash.read!(scope: scope) == []
    end

    test "an entry that balances ORG-WIDE but not per cost object is refused (R6b RED)", %{
      org: org,
      scope: scope,
      admin: admin
    } do
      a = new_cost_object(admin, org, "RISCV64", :project)
      b = new_cost_object(admin, org, "GPU", :project)
      wip = new_account(scope, org, "1200")
      cash = new_account(scope, org, "1000")

      # Σ debits == Σ credits (R1 holds: 100 == 100) but project A is +100/-60
      # and project B is 0/-40 — the money moved OUT of B and only partly back
      # into A.
      result =
        create_entry(scope, org, [
          %{account_id: wip.id, debit_cents: 100, dimension_refs: %{"project" => a.id}},
          %{account_id: cash.id, credit_cents: 60, dimension_refs: %{"project" => a.id}},
          %{account_id: cash.id, credit_cents: 40, dimension_refs: %{"project" => b.id}}
        ])

      assert {:error, %Ash.Error.Invalid{} = err} = result
      assert message(err) =~ "per-cost-object imbalance"
      assert JournalEntry |> Ash.read!(scope: scope) == []
      assert JournalLine |> Ash.read!(authorize?: false, scope: scope) == []
    end

    test "the per-cost-object balanced twin lands and post (CONTROL)", %{
      org: org,
      scope: scope,
      admin: admin
    } do
      a = new_cost_object(admin, org, "RISCV64", :project)
      b = new_cost_object(admin, org, "GPU", :project)
      wip = new_account(scope, org, "1200")
      cash = new_account(scope, org, "1000")

      assert {:ok, entry} =
               create_entry(scope, org, [
                 %{account_id: wip.id, debit_cents: 100, dimension_refs: %{"project" => a.id}},
                 %{account_id: cash.id, credit_cents: 100, dimension_refs: %{"project" => a.id}},
                 %{account_id: wip.id, debit_cents: 40, dimension_refs: %{"project" => b.id}},
                 %{account_id: cash.id, credit_cents: 40, dimension_refs: %{"project" => b.id}}
               ])

      posted = post!(entry, scope)
      assert posted.status == :posted

      assert {:ok, rows} = DimensionReconcile.balances(org, @repo, @lines)
      assert Enum.map(rows, &{&1.cost_object_id, &1.balance_cents}) |> Enum.sort() ==
               Enum.sort([{a.id, 0}, {b.id, 0}])
    end

    test "an UNDIMENSIONED entry still posts (CONTROL — no base-system regression)", %{
      org: org,
      scope: scope
    } do
      wip = new_account(scope, org, "1200")
      cash = new_account(scope, org, "1000")

      assert {:ok, entry} =
               create_entry(scope, org, [
                 %{account_id: wip.id, debit_cents: 100},
                 %{account_id: cash.id, credit_cents: 100}
               ])

      posted = post!(entry, scope)
      assert posted.status == :posted
      assert {:ok, true} = DimensionReconcile.balanced?(org, @repo, @lines)
    end
  end

  # ── d5: the read is load-bearing ───────────────────────────────────────────

  describe "d5 — the R6 read detects what the guard prevents (anti-tautology)" do
    test "raw dimensioned lines forced in below the guard make R6 DIVERGE", %{
      org: org,
      scope: scope,
      admin: admin
    } do
      project = new_cost_object(admin, org, "PTA", :project)
      wip = new_account(scope, org, "1200")
      cash = new_account(scope, org, "1000")

      entry_id = raw_dimensioned_entry(org, wip.id, cash.id, project.id)

      assert {:ok, rows} = DimensionReconcile.balances(org, @repo, @lines)
      assert [row] = rows
      assert row.key == "project"
      assert row.cost_object_id == project.id
      assert row.debit_cents == 100
      assert row.credit_cents == 0
      assert row.balance_cents == 100

      # R6a too: only one of the entry's two lines carries the axis.
      assert {:ok, [violation]} = DimensionReconcile.violations(org, @repo, @lines)
      assert violation.entry_id == entry_id
      assert violation.key == "project"

      assert {:ok, false} = DimensionReconcile.balanced?(org, @repo, @lines)
    end

    test "the same ledger WITHOUT the forced row reads balanced (CONTROL)", %{
      org: org,
      scope: scope
    } do
      wip = new_account(scope, org, "1200")
      cash = new_account(scope, org, "1000")

      assert {:ok, entry} =
               create_entry(scope, org, [
                 %{account_id: wip.id, debit_cents: 100},
                 %{account_id: cash.id, credit_cents: 100}
               ])

      posted = post!(entry, scope)
      assert posted.status == :posted
      assert {:ok, []} = DimensionReconcile.balances(org, @repo, @lines)
      assert {:ok, true} = DimensionReconcile.balanced?(org, @repo, @lines)
    end
  end

  # ── d6: void mirrors the dimension ─────────────────────────────────────────

  describe "d6 — a void mirrors the dimensions (the pair still nets to zero)" do
    test "posting then voiding a dimensioned entry leaves R6 balanced", %{
      org: org,
      scope: scope,
      admin: admin
    } do
      project = new_cost_object(admin, org, "RISCV64", :project)
      wip = new_account(scope, org, "1200")
      cash = new_account(scope, org, "1000")

      assert {:ok, entry} =
               create_entry(scope, org, [
                 %{account_id: wip.id, debit_cents: 250, dimension_refs: %{"project" => project.id}},
                 %{account_id: cash.id, credit_cents: 250, dimension_refs: %{"project" => project.id}}
               ])

      posted = post!(entry, scope)
      voided = Ash.Changeset.for_update(posted, :void, %{}, scope: scope) |> Ash.update!()
      assert voided.voided_entry_id != nil

      assert {:ok, rows} = DimensionReconcile.balances(org, @repo, @lines)
      assert [row] = rows
      assert row.cost_object_id == project.id
      assert row.balance_cents == 0
      assert {:ok, true} = DimensionReconcile.balanced?(org, @repo, @lines)
    end
  end

  # ── d7: the posting map ────────────────────────────────────────────────────

  describe "d7 — the posting map widens in place (ADR-054 D2)" do
    test "the widened meanings are accepted (CONTROL)", %{org: org, admin: admin} do
      gl = new_account(admin, org, "1200")

      for key <- [
            :wip_foundry,
            :wip_photonics,
            :wip_assembly,
            :finished_goods_chip,
            :finished_goods_board,
            :deferred_revenue,
            :grant_deferred,
            :accrued_liabilities,
            :inventory_reserve,
            :amortization_expense,
            :accumulated_amortization,
            :depreciation_expense,
            :write_down_expense,
            :variance_ppv,
            :variance_yield,
            :variance_labor,
            :variance_overhead,
            :mask_expense,
            :eda_expense
          ] do
        assert %PostingAccount{key: ^key} =
                 PostingAccount
                 |> Ash.Changeset.for_create(
                   :create,
                   %{org_id: org, key: key, account_id: gl.id},
                   scope: admin
                 )
                 |> Ash.create!()
      end
    end

    test "a meaning the map does NOT know is still refused (RED — the enum stays closed)", %{
      org: org,
      admin: admin
    } do
      gl = new_account(admin, org, "1200")

      result =
        PostingAccount
        |> Ash.Changeset.for_create(
          :create,
          %{org_id: org, key: :invented_meaning, account_id: gl.id},
          scope: admin
        )
        |> Ash.create()

      assert {:error, %Ash.Error.Invalid{}} = result
    end
  end

  # ── raw SQL: the sabotage shape ────────────────────────────────────────────

  # A posted entry whose debit line names a cost object and whose credit line
  # does not — the exact imbalance R6a/R6b exist to catch, forced into the table
  # BELOW both guards (the PostGuard transaction-local marker is the write
  # guards' own escape hatch, set here the way sabotage 403 would leave it).
  defp raw_dimensioned_entry(org, wip_id, cash_id, project_id) do
    {:ok, entry_id} =
      @repo.transaction(fn ->
        Ecto.Adapters.SQL.query!(@repo, "SELECT set_config('samen.finance_posting', 'on', true)", [])

        %{rows: [[entry_bin]]} =
          Ecto.Adapters.SQL.query!(
            @repo,
            "INSERT INTO sje_journal_entry (sje_id, sje_org_id, sje_entry_date, sje_memo, " <>
              "sje_status, sje_inserted_at, sje_updated_at) VALUES (gen_random_uuid(), $1, " <>
              "(now() AT TIME ZONE 'utc')::date, 'raw', 'posted', " <>
              "timezone('utc', now()), timezone('utc', now())) RETURNING sje_id",
            [Ecto.UUID.dump!(org)]
          )

        entry_id = Ecto.UUID.load!(entry_bin)

        Ecto.Adapters.SQL.query!(
          @repo,
          "INSERT INTO sjl_journal_line (sjl_id, sjl_org_id, sjl_entry_id, sjl_account_id, " <>
            "sjl_debit_cents, sjl_credit_cents, sjl_inserted_at, sjl_updated_at, " <>
            "sjl_dimension_refs) VALUES (gen_random_uuid(), $1, $2, $3, 100, 0, now(), now(), " <>
            "$4::jsonb)",
          [
            Ecto.UUID.dump!(org),
            Ecto.UUID.dump!(entry_id),
            Ecto.UUID.dump!(wip_id),
            # a MAP, not a JSON string: Postgrex's jsonb extension encodes the
            # map itself; a pre-encoded binary would land as a JSON *string*.
            %{"project" => project_id}
          ]
        )

        Ecto.Adapters.SQL.query!(
          @repo,
          "INSERT INTO sjl_journal_line (sjl_id, sjl_org_id, sjl_entry_id, sjl_account_id, " <>
            "sjl_debit_cents, sjl_credit_cents, sjl_inserted_at, sjl_updated_at) " <>
            "VALUES (gen_random_uuid(), $1, $2, $3, 0, 100, now(), now())",
          [Ecto.UUID.dump!(org), Ecto.UUID.dump!(entry_id), Ecto.UUID.dump!(cash_id)]
        )

        entry_id
      end)

    entry_id
  end
end
