defmodule Samen.Web.ErpSurfaceTest do
  @moduledoc """
  WS-ERP E8 UI proof — the generic ERP surface renders inside the SAME app shell as every
  other module page (sidebar + topbar), with every ERP nav item reachable FROM the
  page (it used to serve a bare table with no navigation at all) and the current surface
  highlighted; an unknown surface name renders the honest not-found state instead of
  raising in the heading.

  Write-side proof (detail pages + write affordances): the seeded row's first cell links
  to `/erp/<surface>/:id`, the bounded create modal rides the REAL
  `Samen.WebTest.Erp.Account` `:create` action — blank required fields render inline
  errors and persist nothing, a valid submit persists and the fresh row links to its
  detail page — and the operator plane carries NO write affordance.
  """
  use Samen.WebTest.DataCase, async: false

  require Ash.Query

  alias Samen.Web.Erp.SurfaceLive

  @org "11111111-2222-3333-4444-555555555555"

  test "an ERP surface renders the app shell with the ERP nav group and the active item" do
    html = mount_smoke(SurfaceLive, build_mount(:erp), %{"org" => @org, "surface" => "coa"})

    # The shell + sidebar every other module page has (the surface used to render neither).
    assert html =~ ~s(id="erp-surface")
    assert html =~ ~s(class="app")
    assert html =~ ~s(class="side")

    # The page's own surface is the active nav item...
    assert html =~ ~s(href="/erp/coa?org=#{@org}" class="on")

    # ...and every ERP surface is one click away, org-threaded (the nav island closed).
    for surface <- Samen.Web.Erp.surfaces() do
      assert html =~ ~s(href="/erp/#{surface}?org=#{@org}")
    end

    # Registry-driven heading (topbar h1 + grid header) and breadcrumb trail.
    assert html =~ "Chart of Accounts"
    assert html =~ "ERP"
  end

  test "the goods receipts list renders seeded rows and filters them by number" do
    {receipt_a, _line_a, _po_line_a} = Samen.WebTest.ErpFixtures.seed_goods_receipt(@org)
    {receipt_b, _line_b, _po_line_b} = Samen.WebTest.ErpFixtures.seed_goods_receipt(@org)

    socket = open(%{"org" => @org, "surface" => "goods_receipts"})
    html = render(socket)

    assert html =~ ~s(id="erp-filter")
    assert html =~ receipt_a.number
    assert html =~ receipt_b.number
    assert html =~ ~s(href="/erp/goods_receipts/#{receipt_a.id}?org=#{@org}")

    socket = event(socket, "filter", %{"filter" => receipt_a.number})
    html = render(socket)

    assert html =~ receipt_a.number
    refute html =~ receipt_b.number
    assert html =~ ~s(value="#{receipt_a.number}")
  end

  test "clearing the filter restores both rows and a no-match filter renders the empty state" do
    {receipt_a, _line_a, _po_line_a} = Samen.WebTest.ErpFixtures.seed_goods_receipt(@org)
    {receipt_b, _line_b, _po_line_b} = Samen.WebTest.ErpFixtures.seed_goods_receipt(@org)

    socket = open(%{"org" => @org, "surface" => "goods_receipts"})
    socket = event(socket, "filter", %{"filter" => receipt_a.number})
    assert render(socket) =~ receipt_a.number
    refute render(socket) =~ receipt_b.number

    socket = event(socket, "filter", %{"filter" => ""})
    html = render(socket)

    assert html =~ receipt_a.number
    assert html =~ receipt_b.number

    socket = event(socket, "filter", %{"filter" => "NO-SUCH-RECEIPT"})
    html = render(socket)

    assert html =~ "Nothing here yet."
    refute html =~ receipt_a.number
    refute html =~ receipt_b.number
  end

  test "the goods receipts list filters by received date and status" do
    {receipt_a, _line_a, _po_line_a} =
      Samen.WebTest.ErpFixtures.seed_goods_receipt(@org,
        received_date: ~D[2026-10-05],
        status: :draft
      )

    {receipt_b, _line_b, _po_line_b} =
      Samen.WebTest.ErpFixtures.seed_goods_receipt(@org,
        received_date: ~D[2026-11-01],
        status: :posted
      )

    socket = open(%{"org" => @org, "surface" => "goods_receipts"})
    html = render(socket)

    assert html =~ receipt_a.number
    assert html =~ receipt_b.number

    socket =
      event(socket, "filter", %{
        "filter" => "",
        "received_date" => "2026-10-05",
        "status" => ""
      })

    html = render(socket)
    assert html =~ receipt_a.number
    refute html =~ receipt_b.number
    assert html =~ ~s(value="2026-10-05")

    socket =
      event(socket, "filter", %{
        "filter" => "",
        "received_date" => "",
        "status" => "posted"
      })

    html = render(socket)
    assert html =~ receipt_b.number
    refute html =~ receipt_a.number
  end

  test "pagination over filtered goods receipts never leaks the unfiltered row" do
    date = ~D[2026-10-05]

    {draft_a, _line_a, _po_line_a} =
      Samen.WebTest.ErpFixtures.seed_goods_receipt(@org, received_date: date, status: :draft)

    {draft_b, _line_b, _po_line_b} =
      Samen.WebTest.ErpFixtures.seed_goods_receipt(@org, received_date: date, status: :draft)

    {posted, _line_c, _po_line_c} =
      Samen.WebTest.ErpFixtures.seed_goods_receipt(@org,
        received_date: ~D[2026-11-01],
        status: :posted
      )

    mount = build_mount(:erp)
    scope = Samen.Web.Mount.scope(mount, @org)

    query =
      Samen.WebTest.Erp.GoodsReceipt
      |> Ash.Query.filter(status == :draft and received_date == ^date)

    state = %Samen.Web.ListState{page_size: 1, filter: "GR-"}

    first =
      Samen.Web.Reads.page!(query, state, scope: scope, filter_fields: [:number])

    assert [first_receipt] = first.items
    assert first_receipt.id in [draft_a.id, draft_b.id]
    assert first.has_more
    assert first.next_cursor != nil

    second =
      Samen.Web.Reads.page!(query, %{state | cursor: first.next_cursor},
        scope: scope,
        filter_fields: [:number]
      )

    assert [second_receipt] = second.items
    assert second_receipt.id in [draft_a.id, draft_b.id]
    assert second_receipt.id != first_receipt.id
    refute second.has_more
    refute Enum.any?([first_receipt, second_receipt], &(&1.id == posted.id))
  end

  test "an unknown surface name renders the honest not-found state (no crash in the heading)" do
    html = mount_smoke(SurfaceLive, build_mount(:erp), %{"org" => @org, "surface" => "bogus"})

    assert html =~ "Not found"
    assert html =~ "not available on this workspace's mounted modules"
  end

  test "the adjustment-document surfaces resolve to their mounted resources and render" do
    mount = build_mount(:erp)

    assert Samen.Web.Erp.resource(mount, :credit_notes) == Samen.WebTest.Erp.CreditNote
    assert Samen.Web.Erp.resource(mount, :vendor_credits) == Samen.WebTest.Erp.VendorCredit

    assert Samen.Web.Erp.columns(:credit_notes) == [
             :number,
             :customer_id,
             :date,
             :kind,
             :amount_cents,
             :status
           ]

    assert Samen.Web.Erp.transitions(:vendor_credits) == [
             {:open, "Open vendor credit", [:draft]},
             {:apply, "Apply vendor credit", [:open]},
             {:void, "Void vendor credit", [:draft, :open]}
           ]

    for {surface, label} <- [
          {"credit_notes", "Credit Notes"},
          {"vendor_credits", "Vendor Credits"}
        ] do
      html = mount_smoke(SurfaceLive, mount, %{"org" => @org, "surface" => surface})

      assert html =~ ~s(id="erp-surface")
      assert html =~ label
      assert html =~ ~s(href="/erp/#{surface}?org=#{@org}" class="on")
    end
  end

  # -- write side (the bounded create affordance) ------------------------------

  defp open(params) do
    mount = build_mount(:erp)
    session = mount_session(mount)
    {:ok, socket} = SurfaceLive.mount(params, session, %Phoenix.LiveView.Socket{})
    {:noreply, socket} = SurfaceLive.handle_params(params, "http://localhost/erp/coa", socket)
    socket
  end

  defp event(socket, name, params) do
    {:noreply, socket} = SurfaceLive.handle_event(name, params, socket)
    socket
  end

  defp render(socket), do: render_html(SurfaceLive, socket.assigns)

  defp seed_account(code) do
    Samen.WebTest.Erp.Account
    |> Ash.Changeset.for_create(
      :create,
      %{
        org_id: @org,
        code: code,
        name: "Cash",
        kind: :asset,
        normal_side: :debit,
        currency: "USD"
      },
      authorize?: false
    )
    |> Ash.create!()
  end

  defp account_count do
    Samen.WebTest.Erp.Account |> Ash.read!(authorize?: false) |> length()
  end

  test "a seeded row's first cell links to its record detail page" do
    account = seed_account("1000")
    socket = open(%{"org" => @org, "surface" => "coa"})
    html = render(socket)

    assert html =~ ~s(href="/erp/coa/#{account.id}?org=#{@org}")
    assert html =~ "erp-row-link"
    # The lane copy reflects the write posture (it used to claim read-only).
    assert html =~ "governed writes"
    # The bounded New affordance is offered on the tenant plane.
    assert html =~ ~s(id="new-record")
    assert html =~ "New Account"
  end

  test "create: blank required fields render inline errors and persist nothing" do
    before = account_count()
    socket = open(%{"org" => @org, "surface" => "coa"})

    socket = event(socket, "new_record", %{})
    assert render(socket) =~ ~s(id="new-record-modal")

    # Validate with the required `name` missing — the kit's inline-error path.
    socket =
      event(socket, "validate_new", %{
        "form" => %{
          "code" => "1100",
          "kind" => "asset",
          "normal_side" => "debit",
          "currency" => "USD"
        }
      })

    assert render(socket) =~ "field-invalid"

    # An invalid SUBMIT stays on the form and writes nothing.
    socket =
      event(socket, "save_new", %{
        "form" => %{
          "code" => "1100",
          "kind" => "asset",
          "normal_side" => "debit",
          "currency" => "USD"
        }
      })

    assert render(socket) =~ "field-invalid"
    assert account_count() == before
  end

  test "create: a valid submit persists and the fresh row links to its detail page" do
    socket = open(%{"org" => @org, "surface" => "coa"})
    socket = event(socket, "new_record", %{})

    socket =
      event(socket, "save_new", %{
        "form" => %{
          "code" => "1200",
          "name" => "Accounts Receivable",
          "kind" => "asset",
          "normal_side" => "debit",
          "currency" => "USD"
        }
      })

    html = render(socket)

    account =
      Samen.WebTest.Erp.Account
      |> Ash.Query.ensure_selected([:org_id])
      |> Ash.read!(authorize?: false)
      |> Enum.find(&(&1.code == "1200"))

    assert account
    assert account.org_id == @org
    refute html =~ ~s(id="new-record-modal")
    assert html =~ ~s(href="/erp/coa/#{account.id}?org=#{@org}")
    assert html =~ "Accounts Receivable"
  end

  test "the operator plane carries no write affordance" do
    mount = build_mount(:erp, plane: :operator, target_org_id: @org)
    session = mount_session(mount)
    params = %{"org" => @org, "surface" => "coa"}

    {:ok, socket} = SurfaceLive.mount(params, session, %Phoenix.LiveView.Socket{})
    {:noreply, socket} = SurfaceLive.handle_params(params, "http://localhost/erp/coa", socket)
    html = render_html(SurfaceLive, socket.assigns)

    refute html =~ ~s(id="new-record")
  end
end
