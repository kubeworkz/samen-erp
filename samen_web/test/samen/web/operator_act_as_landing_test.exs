defmodule Samen.Web.OperatorActAsLandingTest do
  @moduledoc """
  WHERE the operator console's act-as crossings LAND — the dead-link class that outranked the
  Portfolio one, because by then the damage was already done: `POST /session/org/<org_id>` (S7's
  CSRF-protected session write) switches the operator's current org and THEN redirects to
  `Samen.Web.Operator.act_as_landing/1`. Both affordances — the sidebar footer's
  "Act as a tenant →" switcher (`Samen.Web.Operator.Live`) and an account row's
  "Open account →" (`Samen.Web.Operator.AccountsLive`) — used to hardcode driftwood's `"/broker"`,
  so on every host that does not route `/broker` the crossing half-happened: the session held the
  tenant org while the page said "Not Found".

  * UNIT — the mount's `:tenant_landing` label decides; a mount naming NOTHING gets the
    framework-neutral `"/"` (the posture `Samen.Web.Onboarding.WizardLive.tenant_landing_href/2`
    already takes), and a host that names its own landing keeps it verbatim.
  * GREEN (rendered) — a mount naming `"/crm/dashboard"` offers act-as forms carrying exactly that
    `return_to`, and the operator chrome mentions no vertical path.
  * RED (rendered, refutable) — a mount naming NOTHING renders `"/"` and STILL no `"/broker"`.
    This is the leg the hardcoded default fails, which is what makes the green one proof rather
    than a restatement of the implementation.

  The RENDERED "Open account →" twin lives in `operator_accounts_render_test.exs` (it needs the
  account rows); both read the same seam.
  """
  use ExUnit.Case, async: true

  alias Samen.Web.{Mount, Operator}

  # The host directory seam (`labels: %{org_directory: {Mod, :fun, []}}`) — without it the switcher
  # has no entries, and therefore no act-as form to inspect.
  def orgs,
    do: [
      {"0f000000-0000-4000-8000-0000000000a1", "Acme Logistics"},
      {"0f000000-0000-4000-8000-0000000000a2", "Bramble Freight"}
    ]

  defp mount(labels) do
    Mount.new(:operator, nil, nil,
      labels: Map.put(labels, :org_directory, {__MODULE__, :orgs, []})
    )
  end

  defp chrome(labels) do
    Phoenix.LiveViewTest.__render_component__(
      nil,
      &Samen.Web.Operator.Live.operator_sidebar/1,
      %{mount: mount(labels), active: nil, operator_role: nil, __changed__: %{}},
      []
    )
  end

  # Every act-as POST the chrome offers, as the landing each one asks for.
  defp landings(html) do
    ~r/action="(\/session\/org\/[^"]+)"/
    |> Regex.scan(html)
    |> Enum.map(fn [_, action] ->
      action |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query() |> Map.fetch!("return_to")
    end)
  end

  test "UNIT: the mount's label decides, and the framework default is the neutral landing" do
    assert Operator.act_as_landing(mount(%{tenant_landing: "/crm/dashboard"})) == "/crm/dashboard"
    assert Operator.act_as_landing(mount(%{})) == "/"
    assert Operator.act_as_landing(nil) == "/"

    # A host that NAMES the old literal still gets it — the DEFAULT changed, not the label.
    assert Operator.act_as_landing(mount(%{tenant_landing: "/broker"})) == "/broker"
  end

  test "GREEN: a labeled mount's act-as forms carry THAT landing, with no vertical path leaking" do
    html = chrome(%{tenant_landing: "/crm/dashboard"})
    found = landings(html)

    assert found != [], "no act-as form rendered — the assertions below would be vacuous"
    assert Enum.uniq(found) == ["/crm/dashboard"]
    refute html =~ "broker"
  end

  test "RED: an unlabeled mount lands NEUTRALLY — never driftwood's hardcoded /broker" do
    html = chrome(%{})
    found = landings(html)

    assert found != []
    assert Enum.uniq(found) == ["/"]
    refute html =~ "broker"
  end
end
