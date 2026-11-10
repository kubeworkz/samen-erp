defmodule Samen.FinanceArCollectionsTest do
  @moduledoc """
  #8 — AR statement delivery and manual collections over the ledger read.

  Delivery records the honest chokepoint outcome (`:captured` in test) without
  storing an email. Collections snapshot the ledger AR and append timeline
  events; neither path creates a journal entry.
  """

  use ExUnit.Case, async: false

  alias Samen.Scopes.Finance.{
    ArCollections,
    ArStatementDelivery,
    CollectionDunning,
    CollectionDunningWorker
  }

  alias Samen.Scopes.Finance.CollectionCadence, as: CadenceSettings

  alias SamenCore.Support.FinanceFixture.{
    CollectionCadence,
    CollectionCase,
    CreditNote,
    InvoiceMirror,
    JournalEntry,
    PaymentReceipt,
    ReceiptAllocation,
    StatementDelivery
  }

  @repo SamenCore.TestRepo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(@repo)
    org = Ash.UUID.generate()
    {:ok, org: org, scope: tenant_scope(org)}
  end

  describe "statement delivery" do
    test "records a captured chokepoint delivery and the currency snapshot", %{
      org: org,
      scope: scope
    } do
      customer_id = Ash.UUID.generate()
      invoice = invoice!(org, customer_id, 12_500)

      assert {:ok, delivery} =
               ArStatementDelivery.deliver(
                 statement_delivery: StatementDelivery,
                 invoice: InvoiceMirror,
                 receipt: PaymentReceipt,
                 receipt_allocation: ReceiptAllocation,
                 credit_note: CreditNote,
                 org_id: org,
                 scope: scope,
                 customer_id: customer_id,
                 as_of: ~D[2026-11-08],
                 delivery_opts: [env: :test, fallback_adapter: nil]
               )

      assert delivery.status == :captured
      assert delivery.currency == "USD"
      assert delivery.outstanding_cents == 12_500
      assert delivery.invoice_count == 1
      assert delivery.invoice_ids == [invoice.id]
      assert delivery.customer_id == customer_id
      refute Map.has_key?(Map.from_struct(delivery), :billing_email)

      assert [stored] = Ash.read!(StatementDelivery, scope: scope)
      assert stored.id == delivery.id
    end

    test "records a blocked attempt instead of faking a send", %{org: org, scope: scope} do
      customer_id = Ash.UUID.generate()
      invoice!(org, customer_id, 10_000)

      assert {:error, :adapter_unconfigured} =
               ArStatementDelivery.deliver(
                 statement_delivery: StatementDelivery,
                 invoice: InvoiceMirror,
                 receipt: PaymentReceipt,
                 receipt_allocation: ReceiptAllocation,
                 credit_note: CreditNote,
                 org_id: org,
                 scope: scope,
                 customer_id: customer_id,
                 as_of: ~D[2026-11-08],
                 delivery_opts: [env: :prod, fallback_adapter: nil, fallback_config: %{}]
               )

      assert [stored] = Ash.read!(StatementDelivery, scope: scope)
      assert stored.status == :blocked
      assert stored.error =~ "adapter_unconfigured"
    end

    test "requires an explicit currency when the statement is mixed", %{org: org, scope: scope} do
      customer_id = Ash.UUID.generate()
      invoice!(org, customer_id, 10_000, "USD")
      invoice!(org, customer_id, 20_000, "EUR")

      assert {:error, :currency_required} =
               ArStatementDelivery.deliver(
                 statement_delivery: StatementDelivery,
                 invoice: InvoiceMirror,
                 receipt: PaymentReceipt,
                 receipt_allocation: ReceiptAllocation,
                 credit_note: CreditNote,
                 org_id: org,
                 scope: scope,
                 customer_id: customer_id,
                 as_of: ~D[2026-11-08],
                 delivery_opts: [env: :test, fallback_adapter: nil]
               )
    end
  end

  describe "collections" do
    test "opens from ledger AR, appends every action, and resolves terminally", %{
      org: org,
      scope: scope
    } do
      customer_id = Ash.UUID.generate()
      invoice!(org, customer_id, 25_000)

      assert {:ok, collection_case} =
               ArCollections.open_case(
                 collection_case: CollectionCase,
                 invoice: InvoiceMirror,
                 receipt: PaymentReceipt,
                 receipt_allocation: ReceiptAllocation,
                 credit_note: CreditNote,
                 org_id: org,
                 scope: scope,
                 customer_id: customer_id,
                 as_of: ~D[2026-11-08],
                 notes: "Collections opened"
               )

      assert collection_case.status == :open
      assert collection_case.stage == :reminder
      assert collection_case.outstanding_cents == 25_000
      assert collection_case.invoice_count == 1
      assert length(collection_case.actions["events"]) == 1

      assert {:error, :active_case_exists} =
               ArCollections.open_case(
                 collection_case: CollectionCase,
                 invoice: InvoiceMirror,
                 receipt: PaymentReceipt,
                 org_id: org,
                 scope: scope,
                 customer_id: customer_id,
                 as_of: ~D[2026-11-08]
               )

      assert {:ok, noticed} =
               ArCollections.record_action(
                 collection_case: CollectionCase,
                 case_id: collection_case.id,
                 kind: :notice,
                 note: "Emailed notice",
                 org_id: org,
                 scope: scope
               )

      assert noticed.stage == :notice
      assert noticed.last_contacted_at != nil
      assert length(noticed.actions["events"]) == 2

      assert {:ok, promised} =
               ArCollections.record_action(
                 collection_case: CollectionCase,
                 case_id: collection_case.id,
                 kind: :promise,
                 note: "Customer promised",
                 promise_to_pay_on: ~D[2026-11-20],
                 promised_cents: 25_000,
                 org_id: org,
                 scope: scope
               )

      assert promised.promise_to_pay_on == ~D[2026-11-20]
      assert promised.promised_cents == 25_000
      assert promised.next_action_on == ~D[2026-11-20]

      assert {:ok, resolved} =
               ArCollections.record_action(
                 collection_case: CollectionCase,
                 case_id: collection_case.id,
                 kind: :resolve,
                 note: "Paid in full",
                 org_id: org,
                 scope: scope
               )

      assert resolved.status == :resolved
      assert resolved.next_action_on == nil
      assert length(resolved.actions["events"]) == 4

      assert {:error, :case_resolved} =
               ArCollections.record_action(
                 collection_case: CollectionCase,
                 case_id: collection_case.id,
                 kind: :reminder,
                 org_id: org,
                 scope: scope
               )

      # Collections is a workflow, not a second ledger.
      assert Ash.read!(JournalEntry, authorize?: false) == []
    end

    test "a case in another org is invisible", %{org: org, scope: scope} do
      customer_id = Ash.UUID.generate()
      invoice!(org, customer_id, 9_000)

      assert {:ok, collection_case} =
               ArCollections.open_case(
                 collection_case: CollectionCase,
                 invoice: InvoiceMirror,
                 receipt: PaymentReceipt,
                 org_id: org,
                 scope: scope,
                 customer_id: customer_id,
                 as_of: ~D[2026-11-08]
               )

      other_org = Ash.UUID.generate()

      assert {:error, :case_not_found} =
               ArCollections.record_action(
                 collection_case: CollectionCase,
                 case_id: collection_case.id,
                 kind: :note,
                 note: "foreign",
                 org_id: other_org,
                 scope: tenant_scope(other_org)
               )
    end
  end

  describe "scheduled dunning" do
    test "advances a due case once and appends an idempotent event", %{org: org, scope: scope} do
      customer_id = Ash.UUID.generate()
      invoice!(org, customer_id, 18_000)

      collection_case =
        open_case!(org, scope, customer_id, next_action_on: ~D[2026-11-08])

      assert {:ok, %{recorded: [%{id: id, stage: :notice}], skipped: []}} =
               CollectionDunning.run(
                 collection_case: CollectionCase,
                 today: ~D[2026-11-08]
               )

      assert id == collection_case.id

      advanced = Ash.get!(CollectionCase, collection_case.id, scope: scope)
      assert advanced.stage == :notice
      assert advanced.status == :open
      assert advanced.next_action_on == ~D[2026-11-22]
      assert advanced.last_contacted_at != nil

      [event | _] = advanced.actions["events"]
      assert event["kind"] == "notice"
      assert event["idempotency_key"] == "dunning:#{collection_case.id}:2026-11-08"
      assert event["note"] =~ "Scheduled dunning"

      assert {:ok, duplicate} =
               ArCollections.record_action(
                 collection_case: CollectionCase,
                 case_id: collection_case.id,
                 kind: :notice,
                 idempotency_key: "dunning:#{collection_case.id}:2026-11-08",
                 next_action_on: ~D[2027-01-01],
                 org_id: org,
                 scope: scope
               )

      assert length(duplicate.actions["events"]) == length(advanced.actions["events"])
      assert duplicate.next_action_on == advanced.next_action_on

      assert {:ok, %{recorded: [], skipped: []}} =
               CollectionDunning.run(
                 collection_case: CollectionCase,
                 today: ~D[2026-11-09]
               )

      assert Ash.read!(JournalEntry, authorize?: false) == []
    end

    test "a targeted sweep only advances the named case", %{org: org, scope: scope} do
      customer_id = Ash.UUID.generate()
      invoice!(org, customer_id, 31_000)
      first = open_case!(org, scope, customer_id, next_action_on: ~D[2026-11-08])

      other_customer_id = Ash.UUID.generate()
      invoice!(org, other_customer_id, 32_000)
      other = open_case!(org, scope, other_customer_id, next_action_on: ~D[2026-11-08])

      assert {:ok, %{recorded: [%{id: id, stage: :notice}], skipped: []}} =
               CollectionDunning.run(
                 collection_case: CollectionCase,
                 case_id: first.id,
                 today: ~D[2026-11-08]
               )

      assert id == first.id
      assert Ash.get!(CollectionCase, first.id, scope: scope).stage == :notice
      assert Ash.get!(CollectionCase, other.id, scope: scope).stage == :reminder
    end

    test "walks the reminder -> notice -> final notice -> collections ladder", %{
      org: org,
      scope: scope
    } do
      customer_id = Ash.UUID.generate()
      invoice!(org, customer_id, 42_000)

      collection_case =
        open_case!(org, scope, customer_id, next_action_on: ~D[2026-11-08])

      assert {:ok, %{recorded: [%{stage: :notice}]}} =
               CollectionDunning.run(
                 collection_case: CollectionCase,
                 today: ~D[2026-11-08]
               )

      assert {:ok, %{recorded: [%{stage: :final_notice}]}} =
               CollectionDunning.run(
                 collection_case: CollectionCase,
                 today: ~D[2026-11-22]
               )

      assert {:ok, %{recorded: [%{stage: :collections}]}} =
               CollectionDunning.run(
                 collection_case: CollectionCase,
                 today: ~D[2026-12-13]
               )

      assert {:ok, %{recorded: [%{stage: :collections}]}} =
               CollectionDunning.run(
                 collection_case: CollectionCase,
                 today: ~D[2027-01-12]
               )

      final = Ash.get!(CollectionCase, collection_case.id, scope: scope)
      assert final.stage == :collections
      assert final.next_action_on == ~D[2027-02-11]
      assert length(final.actions["events"]) == 5
    end

    test "applies per-org intervals and skips disabled stages", %{org: org, scope: scope} do
      admin = admin_scope(org)

      create_cadence!(org, admin, %{
        notice_enabled: false,
        final_notice_enabled: true,
        collections_enabled: true,
        final_notice_days: 5,
        collections_days: 9
      })

      customer_id = Ash.UUID.generate()
      invoice!(org, customer_id, 23_000)

      collection_case =
        open_case!(org, scope, customer_id, next_action_on: ~D[2026-11-08])

      assert {:ok, %{recorded: [%{stage: :final_notice}]}} =
               CollectionDunning.run(
                 collection_case: CollectionCase,
                 collection_cadence: CollectionCadence,
                 today: ~D[2026-11-08]
               )

      advanced = Ash.get!(CollectionCase, collection_case.id, scope: scope)
      assert advanced.stage == :final_notice
      assert advanced.next_action_on == ~D[2026-11-13]

      assert {:ok, %{recorded: [%{stage: :collections}]}} =
               CollectionDunning.run(
                 collection_case: CollectionCase,
                 collection_cadence: CollectionCadence,
                 today: ~D[2026-11-13]
               )

      final = Ash.get!(CollectionCase, collection_case.id, scope: scope)
      assert final.stage == :collections
      assert final.next_action_on == ~D[2026-11-22]
    end

    test "repeats collections and skips disabled escalation stages" do
      defaults = CadenceSettings.defaults()

      assert CadenceSettings.next_stage(:collections, defaults) == :collections

      assert CadenceSettings.next_stage(:reminder, %{defaults | notice_enabled: false}) ==
               :final_notice

      assert CadenceSettings.next_stage(:reminder, %{
               defaults
               | notice_enabled: false,
                 final_notice_enabled: false,
                 collections_enabled: false
             }) == nil

      assert CadenceSettings.next_action_on(:notice, ~D[2026-11-08], %{
               defaults
               | notice_days: 4
             }) == ~D[2026-11-12]
    end

    test "skips a case when every escalation stage is disabled", %{org: org, scope: scope} do
      create_cadence!(org, admin_scope(org), %{
        notice_enabled: false,
        final_notice_enabled: false,
        collections_enabled: false
      })

      customer_id = Ash.UUID.generate()
      invoice!(org, customer_id, 24_000)
      collection_case = open_case!(org, scope, customer_id, next_action_on: ~D[2026-11-08])

      assert {:ok, %{recorded: [], skipped: [%{id: id, reason: :no_enabled_stage}]}} =
               CollectionDunning.run(
                 collection_case: CollectionCase,
                 collection_cadence: CollectionCadence,
                 today: ~D[2026-11-08]
               )

      assert id == collection_case.id
      assert Ash.get!(CollectionCase, collection_case.id, scope: scope).stage == :reminder
    end

    test "cadence settings are admin-owned and validate intervals", %{org: org, scope: scope} do
      assert {:error, %Ash.Error.Forbidden{}} =
               CollectionCadence
               |> Ash.Changeset.for_create(:create, %{org_id: org}, scope: scope)
               |> Ash.create()

      admin = admin_scope(org)

      assert {:ok, cadence} =
               CollectionCadence
               |> Ash.Changeset.for_create(:create, %{org_id: org}, scope: admin)
               |> Ash.create()

      assert cadence.notice_days == 14
      assert cadence.final_notice_days == 21
      assert cadence.collections_days == 30

      assert {:error, %Ash.Error.Invalid{}} =
               cadence
               |> Ash.Changeset.for_update(:update, %{notice_days: 0}, scope: admin)
               |> Ash.update()

      assert {:ok, updated} =
               cadence
               |> Ash.Changeset.for_update(:update, %{notice_days: 10}, scope: admin)
               |> Ash.update()

      assert updated.notice_days == 10
    end

    test "skips paused and resolved cases but sweeps every org", %{org: org, scope: scope} do
      open_customer = Ash.UUID.generate()
      invoice!(org, open_customer, 10_000)
      open_case = open_case!(org, scope, open_customer, next_action_on: ~D[2026-11-08])

      paused_customer = Ash.UUID.generate()
      invoice!(org, paused_customer, 11_000)
      paused_case = open_case!(org, scope, paused_customer, next_action_on: ~D[2026-11-08])

      assert {:ok, _paused} =
               ArCollections.record_action(
                 collection_case: CollectionCase,
                 case_id: paused_case.id,
                 kind: :pause,
                 org_id: org,
                 scope: scope
               )

      resolved_customer = Ash.UUID.generate()
      invoice!(org, resolved_customer, 12_000)
      resolved_case = open_case!(org, scope, resolved_customer, next_action_on: ~D[2026-11-08])

      assert {:ok, _resolved} =
               ArCollections.record_action(
                 collection_case: CollectionCase,
                 case_id: resolved_case.id,
                 kind: :resolve,
                 org_id: org,
                 scope: scope
               )

      other_org = Ash.UUID.generate()
      other_scope = tenant_scope(other_org)
      other_customer = Ash.UUID.generate()
      invoice!(other_org, other_customer, 13_000)

      other_case =
        open_case!(other_org, other_scope, other_customer, next_action_on: ~D[2026-11-08])

      assert {:ok, summary} =
               CollectionDunning.run(
                 collection_case: CollectionCase,
                 today: ~D[2026-11-08]
               )

      assert Enum.sort(Enum.map(summary.recorded, & &1.id)) ==
               Enum.sort([open_case.id, other_case.id])

      assert summary.skipped == []
      assert Ash.get!(CollectionCase, paused_case.id, scope: scope).status == :paused
      assert Ash.get!(CollectionCase, resolved_case.id, scope: scope).status == :resolved
      assert Ash.get!(CollectionCase, other_case.id, scope: other_scope).stage == :notice
    end

    test "the Oban worker runs the configured sweep and rides the canonical crontab", %{
      org: org,
      scope: scope
    } do
      prior = Application.get_env(:samen_core, CollectionDunning)

      Application.put_env(:samen_core, CollectionDunning,
        collection_case: CollectionCase,
        collection_cadence: CollectionCadence
      )

      on_exit(fn -> restore_env(prior) end)

      today = Date.utc_today()
      customer_id = Ash.UUID.generate()
      invoice!(org, customer_id, 14_000)

      collection_case =
        open_case!(
          org,
          scope,
          customer_id,
          as_of: today,
          next_action_on: today
        )

      assert :ok = CollectionDunningWorker.perform(%Oban.Job{args: %{}})

      assert Ash.get!(CollectionCase, collection_case.id, scope: scope).stage == :notice
      assert {"10 1 * * *", CollectionDunningWorker} in Samen.Jobs.default_crontab()
    end
  end

  defp create_cadence!(org, scope, attrs) do
    attrs = Map.put(attrs, :org_id, org)

    assert {:ok, cadence} =
             CollectionCadence
             |> Ash.Changeset.for_create(:create, attrs, scope: scope)
             |> Ash.create()

    cadence
  end

  defp admin_scope(org_id) do
    %Samen.Scope{
      actor: %{id: "u:#{org_id}", org_id: org_id, role: :admin, kind: :tenant, plane: :tenant}
    }
  end

  defp open_case!(org, scope, customer_id, opts) do
    attrs = [
      collection_case: CollectionCase,
      invoice: InvoiceMirror,
      receipt: PaymentReceipt,
      receipt_allocation: ReceiptAllocation,
      credit_note: CreditNote,
      org_id: org,
      scope: scope,
      customer_id: customer_id,
      as_of: ~D[2026-11-08]
    ]

    assert {:ok, collection_case} = ArCollections.open_case(Keyword.merge(attrs, opts))
    collection_case
  end

  defp restore_env(nil), do: Application.delete_env(:samen_core, CollectionDunning)
  defp restore_env(prior), do: Application.put_env(:samen_core, CollectionDunning, prior)

  defp invoice!(org, customer_id, cents, currency \\ "USD") do
    InvoiceMirror
    |> Ash.Changeset.for_create(
      :create,
      %{
        org_id: org,
        customer_id: customer_id,
        status: :open,
        amount_due_cents: cents,
        amount_paid_cents: 0,
        currency: currency,
        line_items: []
      },
      authorize?: false
    )
    |> Ash.create!()
  end

  defp tenant_scope(org_id) do
    %Samen.Scope{
      actor: %{id: "u:#{org_id}", org_id: org_id, role: :member, kind: :tenant, plane: :tenant}
    }
  end
end
