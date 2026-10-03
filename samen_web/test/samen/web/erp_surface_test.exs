defmodule Samen.Web.ErpSurfaceTest do
  @moduledoc """
  WS-ERP E8 UI proof — the generic ERP surface renders inside the SAME app shell as every
  other module page (sidebar + topbar), with the six-item ERP nav group reachable FROM the
  page (it used to serve a bare table with no navigation at all) and the current surface
  highlighted; an unknown surface name renders the honest not-found state instead of
  raising in the heading.
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
end
