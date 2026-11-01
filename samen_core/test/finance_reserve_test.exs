defmodule Samen.FinanceReserveTest do
  @moduledoc """
  WS-ACCT Phase 9 (ADR-054 D10) — the obsolescence / NRV reserve, mounted via
  `test/support/finance_fixture.ex` + `test/support/inventory_fixture.ex`.

  Every refusal is paired with a positive control (`Samen.RedPath` discipline):

    * r1 the FIFO aging arithmetic consumes the oldest layers first (pure);
    * r2 an :age policy flags only stock older than the threshold, and the
      assessment mutates nothing;
    * r3 drafting persists the assessment and posts NOTHING;
    * r4 the Gate refuses an ungated post, a distinct approver lands it exactly
      once, and a posted write-down can never be posted again;
    * r5 the :item basis reproduces JE-034 (250 dies at 2.00 written to zero);
    * r6 a partial percentage rounds to whole cents and the assessment nets
      every posted write-down, so a second review proposes only what remains;
    * r7 a draft whose stock moved refuses to post (assessment drift);
    * r8 R10: a closed period refuses the posting and leaves the draft alone;
    * r9 fail-honest: an unmapped write-down account refuses; mapping it posts;
      an eligible item with no inventory account refuses the DRAFT by SKU;
    * r10 the policy rung: a member cannot author a policy; an admin can;
    * r11 DB belts: assessed lines are append-only and a posted header is final.
  """
  use ExUnit.Case, async: false

  require Ash.Query

  alias Samen.Scopes.Finance.ReserveAssessment

  alias SamenCore.Support.FinanceFixture.{
    Account,
    FiscalPeriod,
    InventoryReserve,
    JournalEntry,
    JournalLine,
    PostingAccount,
    ReserveWriteDown,
    ReserveWriteDownLine
  }

  alias SamenCore.Support.InventoryFixture.{Item, StockLedger, StockLevel, Warehouse}

  @repo SamenCore.TestRepo
  @approval_resource SamenCore.Support.ApprovalsFixture.Approval

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(@repo)
    org = Ash.UUID.generate()

    {:ok, org: org, admin: admin_scope(org), tenant: tenant_scope(org)}
  end

  # ── r1: the arithmetic ─────────────────────────────────────────────────────

  test "FIFO aging consumes the oldest layers first" do
    events = [
      %{qty: 100, inserted_at: ~U[2026-01-01 00:00:00Z]},
      %{qty: 50, inserted_at: ~U[2026-03-01 00:00:00Z]},
      %{qty: -30, inserted_at: ~U[2026-04-01 00:00:00Z]}
    ]

    # 30 of the 30 consumed came out of January's layer, so 70 January units
    # remain; the March layer is untouched.
    assert ReserveAssessment.aged_quantity(events, ~D[2026-02-01], 120) == 70

    # A cut after both receipts sees all 120 on hand as aged.
    assert ReserveAssessment.aged_quantity(events, ~D[2026-04-15], 120) == 120

    # No events, no aged quantity — never a negative or invented number.
    assert ReserveAssessment.aged_quantity([], ~D[2026-04-15], 10) == 0
  end

  # ── r2: the age assessment ─────────────────────────────────────────────────

  test "an :age policy flags only stock older than the threshold and mutates nothing", %{
    org: org,
    admin: admin
  } do
    ctx = books!(admin, org)
    item = item!(admin, org, ctx.inventory, %{sku: "SOC-AGE"})
    warehouse = warehouse!(admin, org)
    _stock = stock!(org, item, warehouse, 100, 100)

    policy = policy!(admin, org, %{name: "18-month FG", basis: :age, age_months: 18, pct: 100})

    levels_before = levels(org)
    ledger_before = ledger(org)

    # Today's receipt is NOT 18 months old yet.
    fresh = assess(org, policy, ~D[2026-11-01])
    assert fresh.cutoff == ~D[2025-05-01]
    assert fresh.candidates == []
    assert fresh.total_cents == 0

    # 19 months ahead, the cut (2026-12-01) is past the receipt's date.
    aged = assess(org, policy, ~D[2028-06-01])
    assert aged.cutoff == ~D[2026-12-01]

    [candidate] = aged.candidates
    assert candidate.item_id == item.id
    assert candidate.sku == "SOC-AGE"
    assert candidate.quantity == 100
    assert candidate.cost_cents == 10_000
    assert candidate.write_down_cents == 10_000
    assert candidate.inventory_account_id == ctx.inventory.id

    # The read has no writes: the level, its value and the ledger are identical.
    assert levels(org) == levels_before
    assert ledger(org) == ledger_before
  end

  # ── r3: drafting is not posting ────────────────────────────────────────────

  test "drafting persists the assessment and posts nothing", %{
    org: org,
    admin: admin,
    tenant: tenant
  } do
    ctx = books!(admin, org)
    item = item!(admin, org, ctx.inventory, %{sku: "SOC-DRAFT"})
    warehouse = warehouse!(admin, org)
    _stock = stock!(org, item, warehouse, 100, 100)

    policy = policy!(admin, org, %{name: "18-month FG", basis: :age, age_months: 18, pct: 100})

    assert {:ok, draft} = draft(tenant, org, policy, ~D[2028-06-01])

    assert draft.status == :draft
    assert draft.amount_cents == 10_000
    assert draft.entry_id == nil
    assert draft.posted_at == nil

    assert [line] = lines(org, draft.id)
    assert line.item_id == item.id
    assert line.quantity == 100
    assert line.cost_cents == 10_000
    assert line.write_down_cents == 10_000
    assert line.inventory_account_id == ctx.inventory.id

    # NOTHING hit the GL: no entry, no reserve balance.
    assert entries(org) == []
  end

  # ── r4: the Gate ───────────────────────────────────────────────────────────

  test "the Gate refuses an ungated write-down and a distinct approver lands it once", %{
    org: org,
    admin: admin,
    tenant: tenant
  } do
    ctx = books!(admin, org)
    item = item!(admin, org, ctx.inventory, %{sku: "SOC-GATE"})
    warehouse = warehouse!(admin, org)
    _stock = stock!(org, item, warehouse, 100, 100)
    policy = policy!(admin, org, %{name: "18-month FG", basis: :age, age_months: 18, pct: 100})

    assert {:ok, draft} = draft(tenant, org, policy, ~D[2028-06-01])

    assert {:gated, approval_id} = gate(draft, tenant)

    # The row is still a draft; the pending approval names the write-down.
    assert reload(draft).status == :draft
    assert entries(org) == []

    {:ok, approval} =
      Samen.Approvals.get(approval_id,
        approval_resource: @approval_resource,
        repo: @repo
      )

    assert approval.subject_ref == "samen:fsq:#{draft.id}"
    assert approval.requested_by == "u:#{org}"

    # The requester cannot approve their own proposal.
    assert {:error, :self_approval} =
             Samen.Approvals.approve(approval_id, "u:#{org}",
               approval_resource: @approval_resource,
               repo: @repo
             )

    assert {:ok, approved, %{executed: "post"}} = decide(approval_id)
    assert approved.state == :approved

    posted = reload(draft)
    assert posted.status == :posted
    assert posted.entry_id != nil
    assert posted.posted_at != nil

    [entry] = entries(org)
    assert entry.id == posted.entry_id
    assert entry.status == :posted
    assert entry.entry_date == ~D[2028-06-01]
    assert entry.source_key == "reserve_write_down"
    assert entry.source_id == draft.id

    assert Enum.sort(
             Enum.map(
               entry_lines(org, entry.id),
               &{&1.account_id, &1.debit_cents, &1.credit_cents}
             )
           ) ==
             Enum.sort([
               {ctx.write_down.id, 10_000, 0},
               {ctx.inventory.id, 0, 10_000}
             ])

    # Exactly once: a second decision is refused by the engine's state machine.
    assert {:error, :not_pending} = decide(approval_id)
    assert length(entries(org)) == 1

    # A second `:post` is refused BEFORE a new approval can open (the draft-only
    # validation), so a posted write-down can never queue a dead approval.
    assert {:error, %Ash.Error.Invalid{} = err} =
             posted
             |> Ash.Changeset.for_update(:post, %{}, scope: tenant)
             |> Ash.update()

    assert Exception.message(err) =~ "already posted"
    assert length(entries(org)) == 1
  end

  # ── r5: JE-034 ─────────────────────────────────────────────────────────────

  test "the :item basis reproduces JE-034 — 250 dies at 2.00 written to zero", %{
    org: org,
    admin: admin,
    tenant: tenant
  } do
    ctx = books!(admin, org)
    item = item!(admin, org, ctx.inventory, %{sku: "SOC-250"})
    warehouse = warehouse!(admin, org)
    _stock = stock!(org, item, warehouse, 250, 200)

    policy =
      policy!(admin, org, %{
        name: "No alternative use",
        basis: :item,
        pct: 100,
        applies_to: [item.id]
      })

    assert {:ok, draft} = draft(tenant, org, policy, ~D[2026-11-01])
    assert draft.amount_cents == 50_000

    assert {:gated, id} = gate(draft, tenant)
    assert {:ok, _, _} = decide(id)

    [entry] = entries(org)

    assert Enum.sort(
             Enum.map(
               entry_lines(org, entry.id),
               &{&1.account_id, &1.debit_cents, &1.credit_cents}
             )
           ) ==
             Enum.sort([
               {ctx.write_down.id, 50_000, 0},
               {ctx.inventory.id, 0, 50_000}
             ])
  end

  # ── r6: percentage + netting ───────────────────────────────────────────────

  test "a partial percentage rounds to cents and the assessment nets what already posted", %{
    org: org,
    admin: admin,
    tenant: tenant
  } do
    ctx = books!(admin, org)
    item = item!(admin, org, ctx.inventory, %{sku: "SOC-33"})
    warehouse = warehouse!(admin, org)
    _stock = stock!(org, item, warehouse, 3, 333)

    policy = policy!(admin, org, %{name: "Third", basis: :item, pct: 33, applies_to: [item.id]})

    # 3 × 3.33 = 9.99; 33% = 3.2967 → 3.30 (half-up on whole cents).
    assert {:ok, first} = draft(tenant, org, policy, ~D[2026-11-01])
    assert first.amount_cents == 330

    assert {:gated, id1} = gate(first, tenant)
    assert {:ok, _, _} = decide(id1)

    # Remaining 6.69; 33% = 2.2077 → 2.21.
    assert {:ok, second} = draft(tenant, org, policy, ~D[2026-11-01])
    assert second.amount_cents == 221

    assert {:gated, id2} = gate(second, tenant)
    assert {:ok, _, _} = decide(id2)

    # Remaining 4.48; 33% = 1.4784 → 1.48.
    assert {:ok, third} = draft(tenant, org, policy, ~D[2026-11-01])
    assert third.amount_cents == 148

    # The entries stay separate facts; nothing was rewritten.
    assert length(entries(org)) == 2
    assert Enum.sum(Enum.map(entries(org), &entry_debit_total(org, &1.id))) == 551
  end

  test "a fully written-down item drafts nothing on the next review", %{
    org: org,
    admin: admin,
    tenant: tenant
  } do
    ctx = books!(admin, org)
    item = item!(admin, org, ctx.inventory, %{sku: "SOC-DONE"})
    warehouse = warehouse!(admin, org)
    _stock = stock!(org, item, warehouse, 100, 100)

    policy = policy!(admin, org, %{name: "Full", basis: :item, pct: 100, applies_to: [item.id]})

    assert {:ok, draft} = draft(tenant, org, policy, ~D[2026-11-01])
    assert {:gated, id} = gate(draft, tenant)
    assert {:ok, _, _} = decide(id)

    assert {:error, %Ash.Error.Invalid{} = err} = draft(tenant, org, policy, ~D[2026-11-01])
    assert Exception.message(err) =~ "nothing to draft"

    # The read agrees: there is no candidate left.
    assert assess(org, policy, ~D[2026-11-01]).candidates == []
  end

  # ── r7: drift ──────────────────────────────────────────────────────────────

  test "a draft whose stock moved refuses to post, and a fresh draft is the control", %{
    org: org,
    admin: admin,
    tenant: tenant
  } do
    ctx = books!(admin, org)
    item = item!(admin, org, ctx.inventory, %{sku: "SOC-DRIFT"})
    warehouse = warehouse!(admin, org)
    _stock = stock!(org, item, warehouse, 100, 100)
    policy = policy!(admin, org, %{name: "Full", basis: :item, pct: 100, applies_to: [item.id]})

    assert {:ok, stale} = draft(tenant, org, policy, ~D[2026-11-01])
    assert stale.amount_cents == 10_000

    # More stock arrives after the proposal was built: the assessment now says
    # 200 units / 20 000 cents, which the draft does not carry.
    _more = stock!(org, item, warehouse, 100, 100)

    assert {:gated, id} = gate(stale, tenant)
    reason = decide_error(id)
    assert inspect(reason) =~ "assessment changed"

    assert reload(stale).status == :draft
    assert entries(org) == []

    # CONTROL: a draft built from the stock that is actually there posts.
    assert {:ok, fresh} = draft(tenant, org, policy, ~D[2026-11-01])
    assert fresh.amount_cents == 20_000

    assert {:gated, id2} = gate(fresh, tenant)
    assert {:ok, _, _} = decide(id2)
    assert length(entries(org)) == 1
  end

  # ── r8: R10 ────────────────────────────────────────────────────────────────

  test "a closed period refuses the write-down and leaves the draft alone", %{
    org: org,
    admin: admin,
    tenant: tenant
  } do
    ctx = books!(admin, org)
    item = item!(admin, org, ctx.inventory, %{sku: "SOC-CLOSED"})
    warehouse = warehouse!(admin, org)
    _stock = stock!(org, item, warehouse, 100, 100)
    policy = policy!(admin, org, %{name: "Full", basis: :item, pct: 100, applies_to: [item.id]})

    assert {:ok, draft} = draft(tenant, org, policy, ~D[2026-11-01])

    period =
      FiscalPeriod
      |> Ash.Changeset.for_create(:create, %{org_id: org, year: 2026, month: 11}, scope: admin)
      |> Ash.create!()

    assert {:ok, %{status: :closed}} =
             period |> Ash.Changeset.for_update(:close, %{}, scope: admin) |> Ash.update()

    assert {:gated, id} = gate(draft, tenant)
    reason = decide_error(id)
    assert inspect(reason) =~ "closed"

    assert reload(draft).status == :draft
    assert entries(org) == []

    # CONTROL: December is open, so a draft dated there posts.
    assert {:ok, december} = draft(tenant, org, policy, ~D[2026-12-01])
    assert {:gated, id2} = gate(december, tenant)
    assert {:ok, _, _} = decide(id2)
    assert length(entries(org)) == 1
  end

  # ── r9: fail-honest accounts ───────────────────────────────────────────────

  test "an unmapped write-down account refuses; mapping it posts", %{
    org: org,
    admin: admin,
    tenant: tenant
  } do
    # Accounts and an eligible item, but the posting map is NOT bound yet.
    ctx = accounts!(admin, org)
    item = item!(admin, org, ctx.inventory, %{sku: "SOC-NOMAP"})
    warehouse = warehouse!(admin, org)
    _stock = stock!(org, item, warehouse, 100, 100)
    policy = policy!(admin, org, %{name: "Full", basis: :item, pct: 100, applies_to: [item.id]})

    assert {:ok, draft} = draft(tenant, org, policy, ~D[2026-11-01])
    assert {:gated, id} = gate(draft, tenant)

    reason = decide_error(id)
    assert inspect(reason) =~ "write_down_expense"
    assert reload(draft).status == :draft
    assert entries(org) == []

    # CONTROL: bind the account and the same proposal posts.
    map_posting!(admin, org, :write_down_expense, ctx.write_down)

    assert {:gated, id2} = gate(draft, tenant)
    assert {:ok, _, _} = decide(id2)
    assert length(entries(org)) == 1
  end

  test "an eligible item with no inventory account refuses the DRAFT by SKU", %{
    org: org,
    admin: admin,
    tenant: tenant
  } do
    _ = books!(admin, org)
    item = item!(admin, org, nil, %{sku: "SOC-UNLINKED"})
    warehouse = warehouse!(admin, org)
    _stock = stock!(org, item, warehouse, 100, 100)
    policy = policy!(admin, org, %{name: "Full", basis: :item, pct: 100, applies_to: [item.id]})

    assert {:error, %Ash.Error.Invalid{} = err} = draft(tenant, org, policy, ~D[2026-11-01])
    assert Exception.message(err) =~ "SOC-UNLINKED"
    assert journal_entries(org) == []
  end

  # ── r10: the policy rung ───────────────────────────────────────────────────

  test "a member cannot author a policy; an admin can", %{org: org, admin: admin, tenant: tenant} do
    attrs = %{org_id: org, name: "Mine", basis: :age, age_months: 18, pct: 100}

    assert {:error, %Ash.Error.Forbidden{}} =
             InventoryReserve
             |> Ash.Changeset.for_create(:create, attrs, scope: tenant)
             |> Ash.create()

    assert {:ok, policy} =
             InventoryReserve
             |> Ash.Changeset.for_create(:create, attrs, scope: admin)
             |> Ash.create()

    assert policy.basis == :age
    assert policy.age_months == 18

    # The shape guard refuses a policy that cannot be assessed.
    assert {:error, %Ash.Error.Invalid{} = err} =
             InventoryReserve
             |> Ash.Changeset.for_create(
               :create,
               %{org_id: org, name: "Nameless", basis: :item, pct: 50},
               scope: admin
             )
             |> Ash.create()

    assert Exception.message(err) =~ "name at least one item"
  end

  # ── r11: DB belts ──────────────────────────────────────────────────────────

  test "assessed lines are append-only and a posted header is final", %{
    org: org,
    admin: admin,
    tenant: tenant
  } do
    ctx = books!(admin, org)
    item = item!(admin, org, ctx.inventory, %{sku: "SOC-BELT"})
    warehouse = warehouse!(admin, org)
    _stock = stock!(org, item, warehouse, 100, 100)
    policy = policy!(admin, org, %{name: "Full", basis: :item, pct: 100, applies_to: [item.id]})

    assert {:ok, draft} = draft(tenant, org, policy, ~D[2026-11-01])
    assert {:gated, id} = gate(draft, tenant)
    assert {:ok, _, _} = decide(id)

    assert {:error, %Postgrex.Error{postgres: %{message: line_message}}} =
             @repo.query(
               "UPDATE fsz_reserve_write_down_line SET fsz_write_down_cents = 1 WHERE fsz_write_down_id = $1::text::uuid",
               [draft.id]
             )

    assert line_message =~ "append-only"

    assert {:error, %Postgrex.Error{postgres: %{message: header_message}}} =
             @repo.query(
               "UPDATE fsq_reserve_write_down SET fsq_amount_cents = 1 WHERE fsq_id = $1::text::uuid",
               [draft.id]
             )

    assert header_message =~ "final"
  end

  # ── fixture ────────────────────────────────────────────────────────────────

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

  defp new_account(scope, org, code, name) do
    Account
    |> Ash.Changeset.for_create(
      :create,
      %{org_id: org, code: code, name: name, kind: :expense, normal_side: :debit},
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

  defp accounts!(admin, org) do
    %{
      write_down: new_account(admin, org, "8000", "Inventory Write-Down"),
      inventory: new_account(admin, org, "1400", "Inventory – Finished Goods")
    }
  end

  defp books!(admin, org) do
    ctx = accounts!(admin, org)
    map_posting!(admin, org, :write_down_expense, ctx.write_down)
    ctx
  end

  defp item!(admin, org, inventory_account, attrs) do
    attrs =
      Map.merge(
        %{
          org_id: org,
          sku: "SKU-#{System.unique_integer([:positive])}",
          name: "Item #{attrs[:sku] || ""}",
          kind: :stocked
        },
        attrs
      )

    attrs =
      if inventory_account,
        do: Map.put(attrs, :default_inventory_account_id, inventory_account.id),
        else: attrs

    Item
    |> Ash.Changeset.for_create(:create, attrs, scope: admin)
    |> Ash.create!()
  end

  defp warehouse!(admin, org) do
    Warehouse
    |> Ash.Changeset.for_create(
      :create,
      %{org_id: org, code: "WH-#{System.unique_integer([:positive])}", name: "Warehouse"},
      scope: admin
    )
    |> Ash.create!()
  end

  defp stock!(org, item, warehouse, qty, unit_cost_cents) do
    StockLedger
    |> Ash.Changeset.for_create(
      :record,
      %{
        org_id: org,
        kind: :receipt,
        qty: qty,
        unit_cost_cents: unit_cost_cents,
        item_id: item.id,
        warehouse_id: warehouse.id
      },
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end

  defp policy!(admin, org, attrs) do
    attrs =
      Map.merge(
        %{org_id: org, name: "Policy #{System.unique_integer([:positive])}", pct: 100},
        attrs
      )

    InventoryReserve
    |> Ash.Changeset.for_create(:create, attrs, scope: admin)
    |> Ash.create!()
  end

  defp draft(scope, org, policy, assessed_on) do
    ReserveWriteDown
    |> Ash.Changeset.for_create(
      :draft,
      %{org_id: org, policy_id: policy.id, assessed_on: assessed_on},
      scope: scope
    )
    |> Ash.create()
  end

  defp assess(org, policy, as_of) do
    ReserveAssessment.assess(org, policy,
      items: Item,
      levels: StockLevel,
      ledger: StockLedger,
      write_downs: ReserveWriteDown,
      lines: ReserveWriteDownLine,
      as_of: as_of
    )
  end

  # The Gate discipline: an ungated :post fails with ApprovalRequired and
  # returns the pending approval id. NEVER a bare success.
  defp gate(record, scope) do
    case record
         |> Ash.Changeset.for_update(:post, %{}, scope: scope)
         |> Ash.update() do
      {:error, %Ash.Error.Forbidden{errors: errors}} ->
        case Enum.find(errors, &match?(%{__struct__: Samen.Approvals.ApprovalRequired}, &1)) do
          nil -> flunk("expected ApprovalRequired, got: #{inspect(errors)}")
          found -> {:gated, found.approval_id}
        end

      {:ok, _} ->
        flunk("the :post action succeeded WITHOUT the Gate — the approval discipline is broken")

      {:error, other} ->
        flunk("unexpected :post failure: #{inspect(other)}")
    end
  end

  defp decide(approval_id) do
    Samen.Approvals.approve(approval_id, "a2:reserve-decider",
      approval_resource: @approval_resource,
      repo: @repo
    )
  end

  # The engine may surface a handler failure either wrapped as
  # `{:gate_action_failed, reason}` or as the reason itself (a changeset),
  # depending on where the action refused. Both mean the decision rolled back;
  # the tests assert the NAMED reason, not the wrapper.
  defp decide_error(approval_id) do
    case decide(approval_id) do
      {:error, {:gate_action_failed, reason}} -> reason
      {:error, reason} -> reason
      {:ok, _, _} -> flunk("the decision unexpectedly succeeded")
    end
  end

  defp reload(record), do: Ash.get!(ReserveWriteDown, record.id, authorize?: false)

  defp lines(org, write_down_id) do
    ReserveWriteDownLine
    |> Ash.Query.filter(org_id == ^org and write_down_id == ^write_down_id)
    |> Ash.read!(authorize?: false)
  end

  defp entries(org) do
    JournalEntry
    |> Ash.Query.filter(org_id == ^org and source_key == "reserve_write_down")
    |> Ash.read!(authorize?: false)
  end

  defp journal_entries(org) do
    JournalEntry
    |> Ash.Query.filter(org_id == ^org)
    |> Ash.read!(authorize?: false)
  end

  defp entry_lines(org, entry_id) do
    JournalLine
    |> Ash.Query.filter(org_id == ^org and entry_id == ^entry_id)
    |> Ash.read!(authorize?: false)
  end

  defp entry_debit_total(org, entry_id) do
    org |> entry_lines(entry_id) |> Enum.reduce(0, &(&1.debit_cents + &2))
  end

  defp levels(org) do
    StockLevel
    |> Ash.Query.filter(org_id == ^org)
    |> Ash.Query.sort(item_id: :asc)
    |> Ash.read!(authorize?: false)
  end

  defp ledger(org) do
    StockLedger
    |> Ash.Query.filter(org_id == ^org)
    |> Ash.Query.sort(id: :asc)
    |> Ash.read!(authorize?: false)
  end
end
