defmodule Samen.Web.OperatorSidebarLinkInvariantTest do
  @moduledoc """
  T116 attempt 2 — the STRUCTURAL BAR that closes the reachable silent operator→tenant
  crossing (P9-F2/AMB-1) the verifier reproduced live.

  The defect: the operator sidebar's "Notifications" nav item linked to BARE tenant-plane
  `/notifications` (no `?org=`, no `/session/org/`), so an operator clicking it landed on a
  tenant inbox with `data-plane=tenant` + NO `#acting-as-bar` — byte-identical to a real
  tenant, an unmarked crossing.

  The invariant proven here: EVERY operator-chrome nav link stays on the operator plane
  (`/operator/*`); the ONLY operator→tenant affordance is the GOVERNED "Act as a tenant →"
  switcher, which routes through `/session/org/<id>` (the `SessionController` write that sets
  the acting-as context → trips the `plane_badge` crossing marker). NO operator nav link may
  target a bare tenant-plane surface.

  Sabotage-refutable: re-add ANY bare tenant-plane `href` to `operator_sidebar/1` (e.g. the old
  `<.nav_item label="Notifications" href="/notifications">`) and this test FAILS.

  The second invariant here is PLACE KEEPING: the per-tenant DRILL-INS (Deliverability /
  Automation health / Agent health / Activity / Replay) have no top-level index — the only way
  in is Accounts → a specific tenant — so each must light ACCOUNTS. A sidebar with nothing
  highlighted reads as "you are nowhere"; the operator has lost their place just as surely as
  a mislink would have taken them somewhere wrong.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Samen.Web.Mount

  # A directory MFA so the footer "Act as a tenant" switcher renders its governed
  # `/session/org/<id>` links (which we assert ARE allowed — they set the crossing context).
  def dir_fixture do
    [{"11111111-0000-4000-8000-000000000001", "Blue Ridge Logistics"}]
  end

  # The BARE tenant-plane surfaces an operator must NEVER be able to reach unmarked — a raw
  # link to any of these (without `/session/org/`) is the silent-crossing bug.
  @tenant_prefixes ~w(/notifications /crm /billing /support /marketing /files /csv /search /chat /settings)

  defp operator_mount do
    Mount.new(:operator, Samen.WebTest.Crm, Samen.WebTest.Repo,
      plane: Samen.Web.Plane.tenant(),
      labels: %{operator_workspace: "Driftwood Ops", org_directory: {__MODULE__, :dir_fixture, []}}
    )
  end

  defp hrefs(html) do
    Regex.scan(~r/href="([^"]*)"/, html) |> Enum.map(fn [_, h] -> h end)
  end

  # S7: the governed act-as crossing is now a POST <form action=…> (the org switch is a
  # session write, CSRF-protected), so crossing targets live in `action` attributes too.
  defp form_actions(html) do
    Regex.scan(~r/action="([^"]*)"/, html) |> Enum.map(fn [_, a] -> a end)
  end

  defp bare_tenant?(href) do
    Enum.any?(@tenant_prefixes, fn p ->
      href == p or String.starts_with?(href, p <> "/") or String.starts_with?(href, p <> "?")
    end)
  end

  test "operator_sidebar renders NO link to a bare tenant-plane surface" do
    html = render_component(&Samen.Web.Operator.Live.operator_sidebar/1, mount: operator_mount())

    # Sanity: the sidebar actually rendered (operator nav present).
    assert html =~ "Operator plane"
    assert html =~ "Accounts"

    offenders = Enum.filter(hrefs(html), &bare_tenant?/1)

    assert offenders == [],
           "operator chrome must not link to a bare tenant-plane surface (silent crossing); " <>
             "offending hrefs: #{inspect(offenders)}"

    # The Notifications mislink specifically is gone.
    refute "/notifications" in hrefs(html)
  end

  test "the operator→tenant affordance that DOES exist goes through the governed /session/org path" do
    html = render_component(&Samen.Web.Operator.Live.operator_sidebar/1, mount: operator_mount())

    # The "Act as a tenant →" footer switcher — the ONE governed crossing — uses the
    # SessionController write (which sets acting-as context, marking the crossing on arrival).
    # Since S7 that write is a CSRF-protected POST form, so the target is a form ACTION:
    # a bare GET href to /session/org/ would be the forgeable shape again.
    assert html =~ "Act as a tenant"
    assert Enum.any?(form_actions(html), &String.starts_with?(&1, "/session/org/"))
    assert html =~ ~s(method="post")
    refute Enum.any?(hrefs(html), &String.starts_with?(&1, "/session/org/"))
  end

  test "every operator nav href is an operator-plane, governed-crossing, or inert target" do
    html = render_component(&Samen.Web.Operator.Live.operator_sidebar/1, mount: operator_mount())

    for href <- hrefs(html) do
      ok =
        String.starts_with?(href, "/operator/") or
          String.starts_with?(href, "/session/org/") or
          href in ["#", "/"]

      assert ok, "unexpected operator-chrome href (possible plane leak): #{href}"
    end
  end

  # ===========================================================================
  # Place keeping — a per-tenant drill-in lights ACCOUNTS
  # ===========================================================================

  # The five surfaces keyed on an `:org_id` param with NO top-level index route. Each page
  # passes its own atom (`active: :replay`, …); the sidebar resolves it to Accounts.
  @drill_ins [:deliverability, :automation, :agents, :activity, :replay]

  # `nav_item/1` renders `<a href="…" class="on">` when active and OMITS `class` otherwise, so
  # an exact `class="on"` match addresses ONLY the highlighted nav item (the footer switcher's
  # selected entry is `class="ws-switcher-item on"`, a different value).
  defp highlighted(html) do
    Regex.scan(~r/href="([^"]*)"\s+class="on"/, html) |> Enum.map(fn [_, href] -> href end)
  end

  defp sidebar(active) do
    render_component(&Samen.Web.Operator.Live.operator_sidebar/1,
      mount: operator_mount(),
      active: active
    )
  end

  test "every per-tenant drill-in lights the ACCOUNTS nav item, and only it" do
    for active <- @drill_ins do
      assert highlighted(sidebar(active)) == ["/operator/accounts"],
             "#{inspect(active)} is keyed on an org_id with no top-level index, so it must show " <>
               "Accounts highlighted; got #{inspect(highlighted(sidebar(active)))} — the operator " <>
               "has lost their place in the plane"
    end
  end

  test "a TOP-LEVEL surface still lights its own item — the drill-in rule is not a blanket" do
    # Anti-tautology: if the mapping swallowed EVERY atom (or the assertion just looked for
    # "some item is on"), the test above would still pass while the nav became useless.
    assert highlighted(sidebar(:desk)) == ["/operator/desk"]
    assert highlighted(sidebar(:accounts)) == ["/operator/accounts"]
    assert highlighted(sidebar(nil)) == []
  end
end
