defmodule Samenerp.FleetStatusPageTest do
  @moduledoc """
  ADR-050 (G11) on the SAMENERP host — the public status page dispatched through
  this app's REAL router and endpoint, not a hand-built mount.

  The framework's own proofs live in samen_web (`Samen.Web.FleetPublicStatusTest`)
  against a fixture namespace. What only a host test can prove is the part this
  mount actually added: that `samen_fleet_status_route/1` sits in samenerp's PUBLIC
  scope, that `namespace: Samenerp.Fleet` resolves against the host's own
  materialized registry (`efa_*`, migration 20261011120000), and that an
  identity-free request is served rather than bounced to login — so `/status` is
  genuinely live, with NOTHING published until an operator opts an app in.

  A note on the two arms: an empty page is a `200` that says "No components are
  published", never the 503 fail-closed page (the namespace IS readable here) and
  never a claim of "Operational" for a registry it is publishing nothing about.
  """
  use Samenerp.DataCase, async: false

  import Phoenix.ConnTest

  alias Samen.Fleet.{AdminActor, Registry}

  @endpoint SamenerpWeb.Endpoint
  @admin AdminActor.new("status-admin")

  setup do
    # ExUnit-owned endpoint lifecycle (the `directory_test.exs` precedent: an
    # app-supervisor-owned endpoint dies with the setup_all process, and the app
    # supervisor starts no web children under test).
    start_supervised!(SamenerpWeb.Endpoint)
    :ok
  end

  test "GET /status is LIVE and public: 200, no auth bounce, nothing published yet" do
    conn = get(build_conn(), "/status")

    # 200 (not the login 302 a gated surface would give) proves the mount really is
    # in the public scope; the body proves the namespace resolves, because an
    # unreadable one would be the 503 fail-closed page instead.
    assert conn.status == 200
    assert conn.resp_body =~ "No components are published"

    # An empty page never claims an all-clear for a registry it publishes nothing about.
    refute conn.resp_body =~ "All published components are operational."
    refute conn.resp_body =~ "temporarily unavailable"
  end

  test "the public page sets no session cookie and leaks no registry internals" do
    conn = get(build_conn(), "/status")

    refute Enum.any?(conn.resp_headers, fn {k, _v} -> k == "set-cookie" end)
    assert conn.resp_cookies == %{}
    # No internal table/abbrev vocabulary, no scaffolding.
    refute conn.resp_body =~ "efa_"
    refute conn.resp_body =~ "Samenerp.Fleet"
  end

  test "an OPTED-IN app is published by slug; an unpublished one is invisible" do
    {:ok, %{app: published}} =
      Registry.register_app(
        Samenerp.Fleet,
        %{slug: "gridworkz-erp", display_name: "Gridworkz ERP"},
        @admin
      )

    {:ok, %{app: unpublished}} =
      Registry.register_app(
        Samenerp.Fleet,
        %{slug: "not-yet-published", display_name: "Not Yet Published"},
        @admin
      )

    # Opt-in defaults OFF: registering published nothing (ADR-050 §4.3).
    before = get(build_conn(), "/status").resp_body
    refute before =~ "gridworkz-erp"

    {:ok, _} = Registry.set_publish_status(Samenerp.Fleet, published.id, true, @admin)

    body = get(build_conn(), "/status").resp_body

    assert body =~ "gridworkz-erp"
    # The published app has never reported, so the dead-man semantics ADR-044 §4.6
    # ships (consumed, never re-derived) put it at `:down` on the public plane.
    assert body =~ "Down"

    # The app that never opted in is absent — and so are the registry's own
    # identifiers and the other app's operator-authored display name.
    refute body =~ "not-yet-published"
    refute body =~ "Not Yet Published"
    refute body =~ unpublished.id
    refute body =~ published.id
  end

  test "publishing is OPERATOR-only: the app's own heartbeat actor is refused" do
    {:ok, %{app: app}} =
      Registry.register_app(
        Samenerp.Fleet,
        %{slug: "self-promoting", display_name: "Self Promoting"},
        @admin
      )

    assert {:error, _} =
             Registry.set_publish_status(
               Samenerp.Fleet,
               app.id,
               true,
               Samen.Fleet.HeartbeatActor.new(app.id)
             )

    refute get(build_conn(), "/status").resp_body =~ "self-promoting"

    # Positive control: the same call as the fleet admin DOES publish it.
    assert {:ok, _} = Registry.set_publish_status(Samenerp.Fleet, app.id, true, @admin)
    assert get(build_conn(), "/status").resp_body =~ "self-promoting"
  end
end
