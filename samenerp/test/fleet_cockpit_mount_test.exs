defmodule Samenerp.FleetCockpitMountTest do
  @moduledoc """
  T166b / ADR-050 §4.3 + ADR-044 §6.2/§9.2 — the host side of the fleet cockpit: this app
  mounts `fleet_cockpit: true` (ADR-050 §6.1's reversal, 2026-10-11), so the operator
  action that flips a product's public-status opt-in is REACHABLE here instead of being a
  call to the verb from a console.

  Everything below is driven through `SamenerpWeb.Router`'s OWN compiled route table and
  the mount the router itself compiled into the operator `live_session` — never a
  hand-built `%Mount{}` (the discipline `Samenerp.Phase1..7SurfaceTest` and
  `nav_reachability_test.exs` hold). `operator_session/1` reads Phoenix's real route
  metadata, so if the mount loses `fleet_namespace` (or drifts to another namespace, or
  drops `fleet_cockpit`), THIS test follows the router and fails with it.

  Four legs:

    1. **mounted + gated by construction (RP-J-12)** — the four cockpit routes exist, ride
       the operator `live_session`, and EVERY one of them carries the
       `{Samen.Web.Operator.Authz, :require_operator}` `on_mount`. There is no cockpit
       route that could be reached without the operator gate.

    2. **the real mount is the real thing** — the router's compiled session carries
       `fleet_cockpit: true` + `fleet_namespace: Samenerp.Fleet`, and the host wires the
       three things a cockpit needs at runtime: `:fleet_authority` (the J3 role read),
       `:fleet_products` (the per-product scope the publish action checks), and
       `:fleet, mode: :manual` (without which `Samen.Fleet.read/2` would return the
       zero-config self-row and the registry would be invisible).

    3. **reachable (unarmed dogfood posture)** — all four routes render 200 through the
       real endpoint, including the tier-2 page of a registered app.

    4. **GREEN/RED on the ARMED production posture** — the seam's answer is only as good
       as what it does when the host is armed. With `auth_required?: true` a REAL
       operator-org `:owner` publishes through the mounted cockpit AND the public page
       reports the app; a real `:member` (readonly) is refused, a principal with no
       operator membership is refused outright (redirect — fail CLOSED), and the owner's
       IDENTICAL call is the positive control that makes those reds refute the GATE
       rather than a handler that never worked.
  """

  use Samenerp.DataCase, async: false

  import Phoenix.ConnTest

  alias Samen.Fleet.{AdminActor, PublicStatus, Registry}
  alias Samen.Web.Mount
  alias Samen.Web.Operator.{FleetDetailLive, FleetDirectivesLive, FleetLive, FleetRegisterLive}
  alias Samenerp.Operator, as: Op

  @endpoint SamenerpWeb.Endpoint

  # ADR-010's well-known operator org — `Samenerp.OperatorAuthz` resolves membership in it.
  @operator_org_id "0f000000-0000-4000-8000-0000000000aa"

  # `config :samenerp, :fleet_products, [:samenerp]` — the product scope this host grants,
  # and therefore the slug the tier-2 publish action is reachable for (the framework
  # atomizes a row's slug for the roles-map lookup, so an unprovisioned product's publish
  # card is withheld — `:fleet_products` is a grant, not a formality).
  @slug "samenerp"

  @admin AdminActor.new("seed-admin")

  setup do
    start_supervised!(SamenerpWeb.Endpoint)
    :ok
  end

  # ── the router's OWN mount (never hand-built) ───────────────────────────────

  # Phoenix stores each live route's `live_session` session/on_mount in the route
  # metadata (`:phoenix_live_view` → `{module, action, opts, %{extra: ..., name: ...}}`).
  # Reading it is how this test gets the mount the router ACTUALLY compiled.
  defp operator_meta(plug) do
    metadata =
      SamenerpWeb.Router.__routes__()
      |> Enum.find(fn route -> route.plug == Phoenix.LiveView.Plug and route.plug_opts == plug end)
      |> Map.fetch!(:metadata)

    metadata
    |> Map.fetch!(:phoenix_live_view)
    |> elem(3)
  end

  defp operator_session(plug), do: operator_meta(plug).extra.session

  defp real_mount(plug), do: Mount.from_session(operator_session(plug)["samen_mount"])

  defp socket(), do: %Phoenix.LiveView.Socket{}

  # The socket Phoenix itself would hand `mount/3`: the router's session, plus the
  # authenticated principal the framework's login records (Samen.Web.Auth).
  defp open(plug, principal, params \\ %{}) do
    session = Map.put(operator_session(plug), "samen_current_user", principal)

    case plug.mount(params, session, socket()) do
      {:ok, socket} -> socket
    end
  end

  # ── fixtures ───────────────────────────────────────────────────────────────

  defp operator_org! do
    case Ash.get(Op.Org, @operator_org_id, authorize?: false) do
      {:ok, org} ->
        org

      _ ->
        Op.Org
        |> Ash.Changeset.for_create(:create, %{name: "Samenerp Ops"}, authorize?: false)
        |> Ash.Changeset.force_change_attribute(:id, @operator_org_id)
        |> Ash.create!(authorize?: false)
    end
  end

  # A REAL operator-org member: the identity spine's own rows, not a stubbed seam — the
  # credential→User→Membership indirection `Samenerp.OperatorAuthz` documents. Returns the
  # spine CREDENTIAL id (the principal a session actually carries, ADR-035 §5 A4).
  defp operator!(role) do
    _org = operator_org!()
    credential_id = Ecto.UUID.generate()

    user =
      Op.User
      |> Ash.Changeset.for_create(
        :create,
        %{org_id: @operator_org_id, handle: "op-#{role}"},
        authorize?: false
      )
      # `credential_id` is not on the create accept list (the spine writes it through its
      # own path) — force it, which is exactly the indirection `Samenerp.OperatorAuthz`
      # resolves: credential → User → Membership.
      |> Ash.Changeset.force_change_attribute(:credential_id, credential_id)
      |> Ash.create!(authorize?: false)

    Op.Membership
    |> Ash.Changeset.for_create(
      :create,
      %{org_id: @operator_org_id, user_id: user.id, role: role},
      authorize?: false
    )
    |> Ash.create!(authorize?: false)

    credential_id
  end

  defp register!(slug \\ @slug) do
    {:ok, %{app: app}} =
      Registry.register_app(Samenerp.Fleet, %{slug: slug, display_name: "Samen ERP"}, @admin)

    app
  end

  defp published?(app_id) do
    {:ok, row} = Registry.get_app(Samenerp.Fleet, app_id, @admin)
    row.publish_status
  end

  defp page_entries() do
    {:ok, %{entries: entries}} = PublicStatus.read(Samenerp.Fleet)
    entries
  end

  # The ARMED production posture: `config :samenerp, auth_required?: true` — what a real
  # deploy runs (`SamenerpWeb.Router`'s mounts carry `authn: {:app_env, :samenerp, ...}`
  # and `Samen.Web.TenantGate.assert_prod_armed!/1` refuses to boot disarmed in prod).
  defp armed! do
    Application.put_env(:samenerp, :auth_required?, true)
    on_exit(fn -> Application.put_env(:samenerp, :auth_required?, false) end)
    :ok
  end

  # ── leg 1 — mounted, and gated by construction ──────────────────────────────

  test "RP-J-12 — the router mounts all four cockpit routes on the operator live_session, each carrying the operator gate" do
    fleet_routes =
      SamenerpWeb.Router.__routes__()
      |> Enum.filter(&String.starts_with?(to_string(&1.path), "/operator/fleet"))

    assert Enum.map(fleet_routes, & &1.path) == [
             "/operator/fleet",
             "/operator/fleet/directives",
             "/operator/fleet/register",
             "/operator/fleet/:app_id"
           ]

    assert Enum.map(fleet_routes, & &1.plug_opts) == [
             FleetLive,
             FleetDirectivesLive,
             FleetRegisterLive,
             FleetDetailLive
           ]

    for route <- fleet_routes do
      assert route.plug == Phoenix.LiveView.Plug
      meta = operator_meta(route.plug_opts)

      assert meta.name == :samen_operator,
             "#{route.path} must ride the OPERATOR live_session, not a session of its own"

      # The T146 hook is attached by the macro to the session, so every route declared in
      # it — cockpit or not — inherits it. There is no separate fleet auth branch.
      assert Enum.any?(
               meta.extra.on_mount,
               &(&1.id == {Samen.Web.Operator.Authz, :require_operator})
             ),
             "#{route.path} has no require_operator on_mount — an un-gated cockpit route"

      # Non-vacuity: the plain operator console route carries it too, from the SAME
      # session — this is one gate, not a cockpit-specific patch.
      assert operator_meta(Samen.Web.Operator.AccountsLive).extra.on_mount ==
               meta.extra.on_mount
    end
  end

  # ── leg 2 — the mount the router compiled ───────────────────────────────────

  test "the router's compiled mount carries the cockpit labels, and the host wires the three runtime seams a cockpit needs" do
    mount = real_mount(FleetDetailLive)

    assert mount.scope_kind == :operator
    assert mount.namespace == Samenerp.Operator
    assert mount.repo == Samenerp.Repo

    assert Mount.label(mount, :fleet_cockpit, false) == true,
           "the mount at /operator/fleet is not a cockpit mount"

    assert Mount.label(mount, :fleet_namespace, nil) == Samenerp.Fleet,
           "the cockpit must read THIS host's registry (Samenerp.Fleet)"

    assert Mount.label(mount, :operator_authority, nil) ==
             {Samenerp.OperatorAuthz, :resolve_role, [:samenerp]}

    # The three runtime seams, without any one of which the cockpit renders as mounted
    # and reads nothing (or nobody):
    #   * the J3 role read — `Samen.Fleet.Authz.roles_for/2` refuses `%{}` with no MFA;
    assert {Samenerp.FleetAuthz, :fleet_roles, []} = Application.get_env(:samenerp, :fleet_authority)

    #   * the per-product scope the publish action checks;
    assert Samenerp.FleetAuthz.product_scopes() == [:samenerp]

    #   * and the mode: `:embedded` (the zero-config default) returns a single self-row and
    #     IGNORES the namespace, so the cockpit would show one tile and no registry rows.
    assert Samen.Fleet.mode(:samenerp) == :manual
    assert {:ok, _} = Samen.Fleet.read(:samenerp, namespace: Samenerp.Fleet)
  end

  # ── leg 3 — reachable through the real endpoint ─────────────────────────────

  test "every cockpit route renders 200 through the real router (dogfood posture)" do
    app = register!()

    for {path, anchor} <- [
          {"/operator/fleet", "fleet-cockpit"},
          {"/operator/fleet/directives", "fleet-directives"},
          {"/operator/fleet/register", "fleet-register"}
        ] do
      conn = get(build_conn(), path)

      assert conn.status == 200, "#{path} did not render (status=#{conn.status})"
      assert conn.resp_body =~ ~s(id="#{anchor}"), "#{path} rendered without its anchor"
    end

    # The tier-2 page of a REGISTERED app — the public-status opt-in's own surface.
    detail = get(build_conn(), "/operator/fleet/#{app.id}")

    assert detail.status == 200
    assert detail.resp_body =~ ~s(id="publish-status-card")
    assert detail.resp_body =~ ~s(id="publish-toggle")
    assert detail.resp_body =~ "Samen ERP"
  end

  test "a cockpit mount that is not the router's fails closed — the seam refuses a mount with no namespace" do
    # The runtime belt behind the macro's compile-time refusal: a cockpit flag with no
    # `:fleet_namespace` (a directly-built %Mount{} — the shape a hand-rolled router would
    # produce) must never read a registry. Proven here against the SAME LiveView the router
    # mounts, so the failure mode is the mounted one.
    app = register!()

    orphan = %{real_mount(FleetDetailLive) | labels: %{fleet_cockpit: true}}

    session = %{"samen_mount" => Mount.to_session(orphan), "samen_current_user" => nil}
    {:ok, socket} = FleetDetailLive.mount(%{"app_id" => app.id}, session, socket())

    assert socket.assigns.not_configured == {:missing_namespace, :manual}
    assert socket.assigns.publish_status == nil

    {:noreply, socket} = FleetDetailLive.handle_event("publish_status", %{"publish" => "true"}, socket)

    assert socket.assigns.publish_error =~ "No fleet_namespace is configured on this mount"
    refute published?(app.id)
    assert page_entries() == []
  end

  # ── leg 4 — the ARMED production posture: green + red + positive control ────

  describe "ARMED (production) — the seam answers from the real operator roster" do
    test "GREEN — an operator-org OWNER publishes through the mounted cockpit, and the public page reports it" do
      armed!()
      owner = operator!(:owner)
      app = register!()

      # The seam, resolved the way the cockpit resolves it (credential → User → Membership).
      assert Samenerp.FleetAuthz.fleet_roles(owner) ==
               %{fleet: :operator_admin, samenerp: :operator_admin}

      socket = open(FleetDetailLive, owner, %{"app_id" => app.id})

      assert socket.assigns.fleet_ctx.principal_id == owner
      assert socket.assigns.fleet_ctx.namespace == Samenerp.Fleet
      assert socket.assigns.in_product_scope?
      assert socket.assigns.fleet_ctx.admin?
      refute socket.assigns.publish_status
      refute published?(app.id)

      {:noreply, socket} =
        FleetDetailLive.handle_event("publish_status", %{"publish" => "true"}, socket)

      assert socket.assigns.publish_error == nil
      assert socket.assigns.publish_status
      assert socket.assigns.publish_note =~ "Published"

      assert published?(app.id), "the mounted cockpit did not flip the registry row"

      # The PUBLIC plane now serves the app — the page does not promise anything the
      # registry disagrees with.
      assert [%PublicStatus.Entry{slug: @slug}] = page_entries()
    end

    test "RED — a real :member is read-only, and a principal with no operator membership is refused outright" do
      armed!()
      owner = operator!(:owner)
      member = operator!(:member)
      stranger = Ecto.UUID.generate()
      app = register!()

      # (1) :member → :operator_readonly: the ROW is still readable (counts are gated by
      # the product scope, which a member holds), the WRITE is not.
      assert Samenerp.FleetAuthz.fleet_roles(member) ==
               %{fleet: :operator_readonly, samenerp: :operator_readonly}

      member_socket = open(FleetDetailLive, member, %{"app_id" => app.id})

      assert member_socket.assigns.in_product_scope?
      refute member_socket.assigns.fleet_ctx.admin?

      {:noreply, member_socket} =
        FleetDetailLive.handle_event("publish_status", %{"publish" => "true"}, member_socket)

      assert member_socket.assigns.publish_error =~ "Only roles[:fleet] == :operator_admin"
      refute published?(app.id)
      assert page_entries() == []

      # (2) No operator membership at all → the seam answers NOTHING (mask by omission),
      # and the cockpit's own gate denies — a redirect, never a rendered cockpit.
      assert Samenerp.FleetAuthz.fleet_roles(stranger) == %{}

      stranger_socket = open(FleetLive, stranger)

      assert {:redirect, %{to: "/login", status: 302}} = stranger_socket.redirected

      # …and the T146 conn/on_mount gate agrees, on the SAME armed host: the owner is
      # admitted (`:cont`), the principal with no operator membership is halted with a
      # redirect — so the cockpit is unreachable, not merely un-rendered.
      owner_session =
        Map.put(operator_session(FleetDetailLive), "samen_current_user", owner)

      stranger_session =
        Map.put(operator_session(FleetDetailLive), "samen_current_user", stranger)

      assert {:cont, _socket} =
               Samen.Web.Operator.Authz.on_mount(
                 :require_operator,
                 %{},
                 owner_session,
                 socket()
               )

      assert {:halt, halted} =
               Samen.Web.Operator.Authz.on_mount(
                 :require_operator,
                 %{},
                 stranger_session,
                 socket()
               )

      assert {:redirect, %{to: "/login"}} = halted.redirected

      # (3) POSITIVE CONTROL — the IDENTICAL call from the owner flips the row, so the
      # refusals above are the GATE, not a handler that never worked.
      owner_socket = open(FleetDetailLive, owner, %{"app_id" => app.id})

      {:noreply, owner_socket} =
        FleetDetailLive.handle_event("publish_status", %{"publish" => "true"}, owner_socket)

      assert owner_socket.assigns.publish_error == nil
      assert published?(app.id)
      assert [%PublicStatus.Entry{slug: @slug}] = page_entries()
    end

    test "RED — the gate composes: a fleet admin whose product scope is NOT this host's cannot publish its row" do
      armed!()
      owner = operator!(:owner)

      # A registered product this host does NOT provision a scope for. Its tier-1 tile is
      # visible (the registry is the whole fleet's), its tier-2 write surface is not.
      other = register!("pawchart")

      socket = open(FleetDetailLive, owner, %{"app_id" => other.id})

      # The OWNER holds roles[:fleet] == :operator_admin, and the row's counts are still
      # withheld: the product scope is the row's OWN gate.
      assert socket.assigns.fleet_ctx.admin?

      refute socket.assigns.in_product_scope?,
             "a row outside the configured product scope is the row's own gate"

      {:noreply, socket} =
        FleetDetailLive.handle_event("publish_status", %{"publish" => "true"}, socket)

      assert socket.assigns.publish_error =~ "no role in this product"
      refute published?(other.id)
    end
  end

  test "the ARMED posture is what closes the seam: unarmed, the same principal is the dev operator" do
    # Documented, not accidental: `Samenerp.FleetAuthz` delegates to the operator plane's
    # own resolver, which carries the dev convenience `Samen.Web.Operator.Authz` documents
    # for a disarmed host. Arming (which a prod boot ENFORCES — TenantGate.assert_prod_armed!/1)
    # is what turns this into the roster check above.
    refute Samen.Web.TenantGate.armed?(:samenerp)

    assert Samenerp.FleetAuthz.fleet_roles(Ecto.UUID.generate()) ==
             %{fleet: :operator_admin, samenerp: :operator_admin}

    armed!()

    assert Samenerp.FleetAuthz.fleet_roles(Ecto.UUID.generate()) == %{}

    # Anti-tautology: the DEV principal that just resolved above is the SAME one the
    # cockpit would admit — so the assert above is not an empty-map coincidence.
    owner = operator!(:owner)
    assert Samenerp.FleetAuthz.fleet_roles(owner) == %{fleet: :operator_admin, samenerp: :operator_admin}
  end
end
