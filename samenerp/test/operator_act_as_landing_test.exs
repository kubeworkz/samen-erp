defmodule Samenerp.OperatorActAsLandingTest do
  @moduledoc """
  A SamenERP operator's act-as crossings land on a route THIS router serves.

  `POST /session/org/<org_id>` writes the session current org and then redirects to
  `Samen.Web.Operator.act_as_landing/1` — the operator mount's `:tenant_landing` label. This host
  inherited the framework's hardcoded `"/broker"` (driftwood's freight console, unrouted here), so
  acting as a tenant 404'd AFTER the org had already switched: the operator's session held the
  tenant org while the page said "Not Found" — a worse failure than a dead link, because half the
  crossing succeeded.

  The mount now names its own landing, and this test holds it against the REAL compiled route
  table instead of a literal: whatever the label says must be a path the router serves. The
  account row's "Open account →" posts that same seam value (proven RENDERED in
  `samen_web/test/samen/web/operator_accounts_render_test.exs`); what is proven here is that the
  value it posts is SERVABLE on this host.
  """
  use Samenerp.DataCase, async: false

  alias Samen.Web.{Mount, Operator}
  alias Samen.Web.Operator.AggregateLive

  @operator_org_id "0f000000-0000-4000-8000-0000000000aa"

  defp live_meta(plug) do
    SamenerpWeb.Router.__routes__()
    |> Enum.find(fn route -> route.plug == Phoenix.LiveView.Plug and route.plug_opts == plug end)
    |> case do
      nil -> nil
      route -> route.metadata |> Map.fetch!(:phoenix_live_view) |> elem(3)
    end
  end

  # The mount the operator console actually runs on: AggregateLive rides the operator live_session,
  # so its threaded mount IS this host's operator mount (labels, repo and plane included).
  defp operator_mount, do: Mount.from_session(live_meta(AggregateLive).extra.session["samen_mount"])

  defp route_paths do
    SamenerpWeb.Router |> Phoenix.Router.routes() |> Enum.map(& &1.path)
  end

  # An ACCOUNT: a tenant org parented to the operator org (`Reads.accounts/3`'s scope), which is
  # what the operator console lists — and therefore what the act-as switcher enumerates.
  defp account!(plan) do
    Samenerp.Operator.Org
    |> Ash.Changeset.for_create(
      :create,
      %{
        org_id: @operator_org_id,
        name: "Acct #{plan}",
        slug: "acct-#{plan}-#{System.unique_integer([:positive])}",
        plan: plan
      },
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end

  defp act_as_landings(html) do
    ~r/action="(\/session\/org\/[^"]+)"/
    |> Regex.scan(html)
    |> Enum.map(fn [_, action] ->
      action |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query() |> Map.fetch!("return_to")
    end)
  end

  test "the act-as landing is the host's own tenant landing, and a route this router serves" do
    landing = Operator.act_as_landing(operator_mount())
    paths = route_paths()

    assert landing == "/crm/dashboard"
    assert landing in paths, "#{landing} is not routed here — the act-as crossing would 404"

    # The regression, stated against the route table rather than the literal: the path the
    # framework used to hardcode is unservable HERE, so "lands on a served route" could not have
    # held before this host named its own.
    refute "/broker" in paths
    refute landing == "/broker"
  end

  test "the operator sidebar's act-as entries all post to that served landing" do
    account!("starter")

    html =
      Phoenix.LiveViewTest.__render_component__(
        nil,
        &Samen.Web.Operator.Live.operator_sidebar/1,
        %{mount: operator_mount(), active: nil, operator_role: nil, __changed__: %{}},
        []
      )

    found = act_as_landings(html)

    assert found != [], "the act-as switcher offered no entries — the check below would be vacuous"
    assert Enum.uniq(found) == ["/crm/dashboard"]
    assert Enum.all?(found, &(&1 in route_paths()))
  end
end
