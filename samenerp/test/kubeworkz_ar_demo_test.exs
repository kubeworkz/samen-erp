defmodule Samenerp.KubeworkzArDemoTest do
  @moduledoc """
  The demo AR seed opens one overdue CAD invoice and one real collection case
  through the kernel workflow, advances it through the configured 7/14/21
  cadence with backdated recorded events, and a re-run does not duplicate or
  re-advance it.
  """

  use Samenerp.DataCase, async: false

  require Ash.Query

  alias Samen.Scopes.Finance.ArAging
  alias Samenerp.Billing
  alias Samenerp.Erp
  alias Samenerp.Kubeworkz.ArDemo
  alias Samenerp.Operator, as: Op

  @amount_cents 1_875_000

  defp create_org! do
    Op.Org
    |> Ash.Changeset.for_create(:create, %{name: "Kubeworkz AR Demo"}, authorize?: false)
    |> Ash.create!(authorize?: false)
  end

  defp event_date!(event) do
    assert {:ok, at, 0} = DateTime.from_iso8601(event["at"])
    DateTime.to_date(at)
  end

  defp create_cadence!(org_id) do
    Erp.CollectionCadence
    |> Ash.Changeset.for_create(
      :create,
      %{
        org_id: to_string(org_id),
        notice_enabled: true,
        final_notice_enabled: true,
        collections_enabled: true,
        notice_days: 7,
        final_notice_days: 14,
        collections_days: 21
      },
      scope: admin_scope(org_id)
    )
    |> Ash.create!()
  end

  defp admin_scope(org_id) do
    %Samen.Scope{
      actor: %{
        id: "admin:#{org_id}",
        org_id: org_id,
        role: :admin,
        kind: :tenant,
        plane: :tenant
      }
    }
  end

  test "seeds one overdue invoice and advances its case through the cadence" do
    org = create_org!()
    create_cadence!(org.id)
    today = Date.utc_today()

    first = ArDemo.seed!(org.id)

    assert first.customer_created
    assert first.invoice_created
    assert first.collection_case_created

    assert first.invoice.status == :open
    assert first.invoice.currency == "CAD"
    assert first.invoice.amount_due_cents == @amount_cents
    assert first.invoice.amount_paid_cents == 0
    assert Date.diff(today, DateTime.to_date(first.invoice.due_date)) == 45

    collection_case = first.collection_case
    assert collection_case.status == :open
    assert collection_case.stage == :collections
    assert collection_case.currency == "CAD"
    assert collection_case.outstanding_cents == @amount_cents
    assert collection_case.invoice_count == 1
    assert collection_case.opened_on == Date.add(today, -28)
    assert collection_case.next_action_on == Date.add(today, 21)

    assert [
             %{"kind" => "collections", "next_action_on" => collections_next} = collections,
             %{"kind" => "final_notice", "next_action_on" => final_notice_next} = final_notice,
             %{"kind" => "notice", "next_action_on" => notice_next} = notice,
             %{"kind" => "opened"} = opened
           ] = collection_case.actions["events"]

    assert event_date!(opened) == Date.add(today, -28)
    assert event_date!(notice) == Date.add(today, -21)
    assert event_date!(final_notice) == Date.add(today, -14)
    assert event_date!(collections) == today

    assert notice_next == Date.to_iso8601(Date.add(today, -14))
    assert final_notice_next == Date.to_iso8601(today)
    assert collections_next == Date.to_iso8601(Date.add(today, 21))

    assert {:ok, aging} =
             ArAging.for_org(
               invoice: Billing.Invoice,
               receipt: Erp.PaymentReceipt,
               receipt_allocation: Erp.ReceiptAllocation,
               credit_note: Erp.CreditNote,
               org_id: org.id,
               scope: admin_scope(org.id),
               as_of: today
             )

    assert aging.total_cents == @amount_cents
    assert aging.buckets.days_31_60 == @amount_cents

    second = ArDemo.seed!(org.id)

    refute second.customer_created
    refute second.invoice_created
    refute second.collection_case_created
    assert second.customer.id == first.customer.id
    assert second.invoice.id == first.invoice.id
    assert second.collection_case.id == first.collection_case.id
    assert second.collection_case.stage == :collections
    assert second.collection_case_events == 4
    assert second.collection_case.actions["events"] == collection_case.actions["events"]

    assert length(
             Erp.CollectionCase
             |> Ash.Query.filter(org_id == ^org.id)
             |> Ash.read!(authorize?: false)
           ) == 1
  end
end
