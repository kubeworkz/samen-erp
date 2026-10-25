defmodule Samen.Web.OperatorSeatTest do
  @moduledoc """
  P18 — the operator SEAT on the tenant plane: does this session's principal also hold operator
  authority, asked from a TENANT page rather than from the `/operator/*` gate?

  ## The defect class this closes

  `Samen.Web.Operator.Authz.resolve_role/2` reads the host seam off the MOUNT
  (`:operator_authority`), and only `samen_operator_routes/2` sets that label. So on every
  TENANT module mount (`:crm`, `:billing`, `:settings`, …) the gate's own resolver answers `nil`
  for everyone — including a real operator. The tenant chrome therefore had no way to tell an
  operator from a plain tenant: it either showed the console entry to EVERYONE (a dead end at
  gate 2, the mislink the nav verifier exists to prevent) or, because the switcher hides when the
  workspace directory is empty, showed it to no one at all. samenerp ships exactly the second
  state: it seeds only its own operator org, and `Samenerp.Directory` deliberately excludes that
  seat, so an operator signing in lands on the tenant dashboard with no path to the console.

  ## What is proven here (three proofs, the house shape)

    * **GREEN** — a session whose principal the host seam calls an operator carries the `:samen_operator_seat`
      assign out of `Samen.Web.TenantAuthz`'s on_mount, and `Samen.Web.Live.assign_mount/2` stashes
      it on the mount as the `:operator_seat` label the shared sidebar reads.
    * **RED** — the SAME mount with no seam (or a seam that denies) carries `nil`: a plain tenant
      session gets no seat, so the switcher offers no console link (`current_org_test.exs` proves
      the rendered consequence: no `/operator/accounts` href).
    * **SABOTAGE TWIN** — `scripts/sabotages/396-tenant-operator-seat-ungated.patch` makes
      `seat_role/2` grant a seat with no seam, which flips the RED assertions below.

  The seat is an AFFORDANCE fact, never authority: `/operator/*` still passes `Samen.Web.AuthGate`
  and `{Samen.Web.Operator.Authz, :require_operator}`, which re-derive from the session principal
  and refuse independently. Nothing here touches masking or the vault.
  """

  use ExUnit.Case, async: false

  import Phoenix.Component, only: [assign: 3]

  alias Samen.Web.Live
  alias Samen.Web.Mount
  alias Samen.Web.Operator.Authz
  alias Samen.Web.Plane
  alias Samen.Web.TenantAuthz

  @otp_app :samen_web_operator_seat_probe

  setup do
    prev = Application.get_env(@otp_app, :operator_authority)
    Application.delete_env(@otp_app, :operator_authority)

    on_exit(fn ->
      case prev do
        nil -> Application.delete_env(@otp_app, :operator_authority)
        value -> Application.put_env(@otp_app, :operator_authority, value)
      end
    end)

    :ok
  end

  # -- fixtures ---------------------------------------------------------------

  # A TENANT module mount — the mount shape a CRM/Billing/Settings page actually gets (no
  # `:operator_authority` label; that is the whole point of the seat resolver).
  defp tenant_mount(labels \\ %{}) do
    Mount.new(:crm, Samen.WebTest.Crm, Samen.WebTest.Repo,
      plane: Plane.tenant(),
      labels: Map.merge(%{title: "Seat probe"}, labels)
    )
  end

  defp session_for(mount), do: %{"samen_mount" => Mount.to_session(mount)}

  # The host seam, in both shapes a host may declare it: a mount label (the operator mount's
  # own wiring) and application env (a host that declares it once for the whole app — samenerp).
  def grant(role, _principal_id), do: role
  def unconfigured(_principal_id), do: nil
  def not_a_role(_principal_id), do: :definitely_not_an_operator_role
  def boom(_principal_id), do: raise("resolver boom")

  # ==========================================================================
  # GREEN — the seat resolves through either seam shape
  # ==========================================================================

  test "seat_role/2 resolves through the MOUNT label (the operator mount's own wiring)" do
    mount = tenant_mount(%{operator_authority: {__MODULE__, :grant, [:operator_admin]}})

    assert Authz.seat_role(mount, session_for(mount)) == :operator_admin
  end

  test "seat_role/2 falls back to the host's APPLICATION ENV seam (a tenant mount carries no label)" do
    Application.put_env(@otp_app, :operator_authority, {__MODULE__, :grant, [:operator_support]})

    # No `:operator_authority` label — exactly what `samen_module_routes/3` builds.
    mount = tenant_mount(%{otp_app: @otp_app})

    assert Authz.seat_role(mount, session_for(mount)) == :operator_support
  end

  test "seat_role/2 resolves the whole closed role set, never a lattice out of it" do
    for role <- Samen.OperatorPlane.Actor.roles() do
      mount = tenant_mount(%{operator_authority: {__MODULE__, :grant, [role]}})
      assert Authz.seat_role(mount, session_for(mount)) == role
    end
  end

  # ==========================================================================
  # RED — fail CLOSED: no seat unless the host seam says so
  # ==========================================================================

  test "RED: no seam anywhere means no seat (a host that wires nothing exposes nothing)" do
    mount = tenant_mount()
    assert Authz.seat_role(mount, session_for(mount)) == nil
  end

  test "RED: a seam that DENIES means no seat" do
    mount = tenant_mount(%{operator_authority: {__MODULE__, :unconfigured, []}})
    assert Authz.seat_role(mount, session_for(mount)) == nil
  end

  test "RED: a role-shaped LIE (an atom outside roles/0) means no seat" do
    mount = tenant_mount(%{operator_authority: {__MODULE__, :not_a_role, []}})
    assert Authz.seat_role(mount, session_for(mount)) == nil
  end

  test "RED: a RAISING seam means no seat, never a crash" do
    mount = tenant_mount(%{operator_authority: {__MODULE__, :boom, []}})
    assert Authz.seat_role(mount, session_for(mount)) == nil
  end

  # ==========================================================================
  # The wiring — TenantAuthz assigns the seat, assign_mount stashes it on the mount
  # ==========================================================================

  test "TenantAuthz assigns :samen_operator_seat from the host seam" do
    mount = tenant_mount(%{operator_authority: {__MODULE__, :grant, [:operator_readonly]}})

    {:cont, socket} = TenantAuthz.on_mount(:require_tenant, %{}, session_for(mount), socket())

    assert socket.assigns[:samen_operator_seat] == :operator_readonly
  end

  test "RED: a plain tenant session gets a NIL seat assigned (never a fabricated one)" do
    mount = tenant_mount()

    {:cont, socket} = TenantAuthz.on_mount(:require_tenant, %{}, session_for(mount), socket())

    assert socket.assigns[:samen_operator_seat] == nil
  end

  test "assign_mount/2 stashes the seat as the :operator_seat label the sidebar reads" do
    mount = tenant_mount()

    socket =
      socket()
      |> assign(:samen_operator_seat, :operator_admin)
      |> Live.assign_mount(session_for(mount))

    assert Mount.label(socket.assigns.samen_mount, :operator_seat, nil) == :operator_admin
  end

  test "RED: a NIL seat leaves the mount untouched (no label key, no change)" do
    mount = tenant_mount()

    socket = socket() |> Live.assign_mount(session_for(mount))

    assert Mount.label(socket.assigns.samen_mount, :operator_seat, nil) == nil
  end

  # ==========================================================================
  # The SETTINGS sidebar — settings carries no workspace switcher, so it renders the entry
  # directly on the same seat predicate (an operator editing their profile keeps the path back)
  # ==========================================================================

  test "the settings sidebar offers the console entry to an operator SEAT" do
    html = render_settings_sidebar(tenant_mount(%{operator_workspace: "Samenerp Ops", operator_seat: :operator_admin}))

    assert html =~ ~s(id="operator-console-entry")
    assert html =~ "/operator/accounts"
    assert html =~ "Samenerp Ops"
  end

  test "RED: a plain tenant's settings sidebar has NO console entry, and keeps its header chevron" do
    html = render_settings_sidebar(tenant_mount())

    refute html =~ "operator-console-entry"
    refute html =~ "/operator/accounts"
    # The positive control that this is not "the header vanished": the default chevron is intact.
    assert html =~ ~s(<div class="col">⌄</div>)
  end

  defp render_settings_sidebar(mount) do
    %{mount: mount, org_id: "11111111-0000-4000-8000-000000000001", user_id: nil, active: :profile, __changed__: %{}}
    |> Samen.Web.Settings.Live.settings_sidebar()
    |> Phoenix.HTML.Safe.to_iodata()
    |> IO.iodata_to_binary()
  end

  defp socket, do: %Phoenix.LiveView.Socket{}
end
