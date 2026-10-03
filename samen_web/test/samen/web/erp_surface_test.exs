defmodule Samen.Web.ErpSurfaceTest do
  @moduledoc """
  WS-ERP E8 UI proof — the generic ERP surface renders inside the SAME app shell as every
  other module page (sidebar + topbar), with the six-item ERP nav group reachable FROM the
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

    # ...and all six ERP surfaces are one click away, org-threaded (the nav island closed).
    for surface <- Samen.Web.Erp.surfaces() do
      assert html =~ ~s(href="/erp/#{surface}?org=#{@org}")
    end

    # Registry-driven heading (topbar h1 + grid header) and breadcrumb trail.
    assert html =~ "Chart of Accounts"
    assert html =~ "ERP"
  end

  test "an unknown surface name renders the honest not-found state (no crash in the heading)" do
    html = mount_smoke(SurfaceLive, build_mount(:erp), %{"org" => @org, "surface" => "bogus"})

    assert html =~ "Not found"
    assert html =~ "not available on this workspace's mounted modules"
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
        "form" => %{"code" => "1100", "kind" => "asset", "normal_side" => "debit", "currency" => "USD"}
      })

    assert render(socket) =~ "field-invalid"

    # An invalid SUBMIT stays on the form and writes nothing.
    socket =
      event(socket, "save_new", %{
        "form" => %{"code" => "1100", "kind" => "asset", "normal_side" => "debit", "currency" => "USD"}
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
