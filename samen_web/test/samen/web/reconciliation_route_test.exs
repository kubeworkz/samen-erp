defmodule Samen.Web.ReconciliationRouteTest do
  @moduledoc """
  `/erp/reconciliation` is a LITERAL route declared before `samen_erp_routes/3`'s
  generic `:surface` segment.

  The router resolves the literal path to the reconciliation workbench — not to
  `Samen.Web.Erp.SurfaceLive` with `%{"surface" => "reconciliation"}` — and the
  ERP nav link points at that same literal path.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias Samen.Web.Finance.Reconciliation.Live
  alias Samen.WebTest.NavLinksHost.Router

  @org_id "0f000000-0000-4000-8000-000000000001"
  @path "/erp/reconciliation"

  test "the literal path resolves to the reconciliation workbench, not the generic :surface route" do
    assert %{
             plug: Phoenix.LiveView.Plug,
             plug_opts: Live,
             route: @path,
             path_params: %{}
           } = Phoenix.Router.route_info(Router, "GET", @path, "localhost")

    # Positive control: an ordinary ERP surface still reaches the generic route,
    # so the assertion above is a real difference, not a router that cannot
    # resolve `:surface` at all.
    assert %{
             plug: Phoenix.LiveView.Plug,
             plug_opts: Samen.Web.Erp.SurfaceLive,
             route: "/erp/:surface",
             path_params: %{"surface" => "coa"}
           } = Phoenix.Router.route_info(Router, "GET", "/erp/coa", "localhost")
  end

  test "the ERP nav link points at the literal reconciliation route" do
    html =
      render_component(&Samen.UI.module_nav/1, %{
        org_id: @org_id,
        active: :erp_reconciliation,
        erp_path: "/erp",
        extra: []
      })

    assert html =~
             ~s(href="/erp/reconciliation?org=#{@org_id}" class="on")

    assert Phoenix.Router.route_info(
             Router,
             "GET",
             "/erp/reconciliation",
             "localhost"
           ).plug_opts == Live
  end
end
