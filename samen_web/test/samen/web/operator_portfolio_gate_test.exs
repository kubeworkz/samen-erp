defmodule Samen.Web.OperatorPortfolioGateTest do
  @moduledoc """
  The operator sidebar's **Portfolio** item is gated on the mount that declares the route
  (green / red / twin), because an ungated item is a dead link: `samen_operator_routes/2`
  leaves `include_aggregate` false BY DEFAULT, so a host that never mounted
  `/operator/aggregate` still advertised it and Phoenix answered `NoRouteError` ("Not Found")
  on the operator's first click — the reported bug.

  * GREEN — a mount carrying `aggregate_page: true` (what `include_aggregate: true` threads)
    renders the item, pointing at `/operator/aggregate`.
  * RED — a mount without that label (the default, and every host with no aggregate route)
    renders NO such item and NO such href.
  * TWIN — the label itself comes from the macro option: `__aggregate_page_label__/2` is
    proven to add it for `true` and to leave the map alone for `false`, so the green case
    above cannot pass by a label that is set some other way.
  """
  use ExUnit.Case, async: true

  alias Samen.Web.Mount

  defp sidebar_html(labels) do
    mount = Mount.new(:operator, nil, nil, labels: labels)

    Phoenix.LiveViewTest.__render_component__(
      nil,
      &Samen.Web.Operator.Live.operator_sidebar/1,
      %{mount: mount, active: nil, operator_role: nil, __changed__: %{}},
      []
    )
  end

  # The item's markup wraps its label in whitespace, so the label assertion is a regex — a bare
  # `"Portfolio"` substring would also match unrelated copy elsewhere in the chrome.
  defp portfolio_item?(html), do: Regex.match?(~r/>\s*Portfolio\s*</, html)

  test "GREEN: an aggregate_page mount offers Portfolio -> /operator/aggregate" do
    html = sidebar_html(%{aggregate_page: true})

    assert portfolio_item?(html)
    assert html =~ ~s(href="/operator/aggregate")
  end

  test "RED: a mount without the label offers NO Portfolio item (the dead-link bug)" do
    html = sidebar_html(%{})

    refute portfolio_item?(html)
    refute html =~ ~s(href="/operator/aggregate")
    # Positive control: the gate hides ONLY that item — the plane's other surfaces still render,
    # so the refutation above cannot pass because the sidebar rendered nothing at all.
    assert html =~ ~s(href="/operator/accounts")
    assert html =~ ~s(href="/operator/billing")
  end

  test "TWIN: the label is what include_aggregate threads, and only for true" do
    assert Samen.Web.Router.__aggregate_page_label__(%{}, true) == %{aggregate_page: true}
    assert Samen.Web.Router.__aggregate_page_label__(%{operator_title: "P"}, false) ==
             %{operator_title: "P"}
  end

  test "the Fleet item keeps its own independent gate (no label bleed between the two)" do
    fleet_only = sidebar_html(%{fleet_cockpit: true})

    assert fleet_only =~ ~s(href="/operator/fleet")
    refute fleet_only =~ ~s(href="/operator/aggregate")
  end
end
