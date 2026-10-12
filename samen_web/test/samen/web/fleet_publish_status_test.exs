defmodule Samen.Web.FleetPublishStatusTest do
  @moduledoc """
  T166 / ADR-050 §4.3 — the OPERATOR OPT-IN, driven through the cockpit's own action
  (`Samen.Web.Operator.FleetDetailLive`, `phx-click="publish_status"`) and asserted
  through to the PUBLIC plane:

    * **GREEN** — an admin holding a role in the product publishes it: the registry row
      flips, `Samen.Fleet.PublicStatus.read/2` renders the app, and the cockpit's own
      consequence line matches the status the page actually reports.
    * **RED** — a fleet role that is not `:operator_admin` is refused, and so is an
      admin with no role in THIS product: nothing flips and the page stays empty.
    * **positive control** — the IDENTICAL event from the admin does flip it, so the
      reds refute the GATE rather than a broken event handler.
    * **sabotage twin** — `scripts/sabotages/329-*`: dropping the admin conjunct from
      `handle_event/3` makes the non-admin red fail, byte-exact reverted.

  The mapping itself (`preview/1`) is proven one plane down, in
  `samen_core/test/fleet_public_status_test.exs`.
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.Fleet.{AdminActor, PublicStatus, Registry}
  alias Samen.Web.Mount
  alias Samen.Web.Operator.FleetDetailLive

  @ns Samen.WebTest.Fleet
  @otp_app :samen_web_fleet_publish_status_test_host
  @admin AdminActor.new("seed-admin")

  # A literal atom so `String.to_existing_atom/1` (`Samen.Web.Operator.Fleet.app_scope/1`)
  # resolves the product's J3 roles-map scope — the same convention
  # `fleet_detail_scope_mask_test.exs` uses.
  @slug :fps1

  setup do
    Application.put_env(@otp_app, :fleet, mode: :manual)

    on_exit(fn ->
      Application.delete_env(@otp_app, :fleet)
      Application.delete_env(@otp_app, :fleet_authority)
    end)

    {:ok, %{app: app}} =
      Registry.register_app(@ns, %{slug: Atom.to_string(@slug), display_name: "Public Product"}, @admin)

    %{app: app}
  end

  def roles_for(roles, _principal_id), do: roles

  defp socket_with_mount(roles) do
    Application.put_env(@otp_app, :fleet_authority, {__MODULE__, :roles_for, [roles]})

    mount =
      Mount.new(:operator, Samen.WebTest.Operator, Samen.WebTest.Repo,
        plane: Samen.Web.Plane.tenant(),
        labels: %{otp_app: @otp_app, fleet_namespace: @ns, fleet_cockpit: true}
      )

    %Phoenix.LiveView.Socket{} |> Phoenix.Component.assign(:samen_mount, mount)
  end

  defp session, do: %{"samen_current_user" => "op-1"}

  defp open(roles, app_id) do
    socket = socket_with_mount(roles)
    {:ok, socket} = FleetDetailLive.mount(%{"app_id" => app_id}, session(), socket)
    socket
  end

  defp toggle(socket, publish?) do
    FleetDetailLive.handle_event("publish_status", %{"publish" => to_string(publish?)}, socket)
  end

  defp html(socket), do: render_html(FleetDetailLive, socket.assigns)

  defp published?(app_id) do
    {:ok, app} = Registry.get_app(@ns, app_id, @admin)
    app.publish_status
  end

  defp page_entries do
    {:ok, %{entries: entries}} = PublicStatus.read(@ns)
    entries
  end

  defp minimal_payload do
    Samen.Fleet.Report.build(app_id: "11111111-1111-4111-8111-111111111111")
    |> Samen.Fleet.Report.to_wire()
  end

  # ---------------------------------------------------------------------------
  # GREEN — the admin opt-in, and it reaches the public page
  # ---------------------------------------------------------------------------

  describe "GREEN — an admin with a role in the product opts the app in" do
    test "publishing flips the row, renders the app on `GET /status`, and the cockpit's promise is what the page says",
         %{app: app} do
      socket = open(%{fleet: :operator_admin, fps1: :operator_admin}, app.id)

      # Before: unpublished, and the cockpit states the CONSEQUENCE in the page's own
      # words. A never-reported app is `:down`, so publishing it can never read as an
      # all-clear here.
      pre = html(socket)
      assert pre =~ "Not published — this product does not appear on the public status page."
      assert pre =~ "Publishing would list fps1 as Down."
      refute pre =~ "Operational"
      refute published?(app.id)
      assert page_entries() == []

      {:noreply, socket} = toggle(socket, true)

      assert published?(app.id)

      post = html(socket)
      assert post =~ "Published — this product appears on the public status page."
      assert post =~ "The page reports it as Down."

      # The PUBLIC plane now renders it — the same slug, and the status the cockpit
      # just promised (ADR-050 §1: one notion of "up", not two).
      assert [%PublicStatus.Entry{slug: "fps1", status: :down}] = page_entries()
    end

    test "the opt-in is reversible from the same control — unpublishing takes it back off the page", %{app: app} do
      socket = open(%{fleet: :operator_admin, fps1: :operator_admin}, app.id)
      {:noreply, socket} = toggle(socket, true)
      assert [%PublicStatus.Entry{slug: "fps1"}] = page_entries()

      {:noreply, socket} = toggle(socket, false)

      refute published?(app.id)
      assert page_entries() == []
      assert html(socket) =~ "Unpublished — this product no longer appears on the public status page."
    end

    test "a REPORTING app is promised `Operational` and the page renders exactly that", %{app: app} do
      {:ok, _} = Registry.record_report(@ns, app.id, minimal_payload(), :pull)

      socket = open(%{fleet: :operator_admin, fps1: :operator_admin}, app.id)
      assert html(socket) =~ "Publishing would list fps1 as Operational."

      {:noreply, _socket} = toggle(socket, true)
      assert [%PublicStatus.Entry{slug: "fps1", status: :operational}] = page_entries()
    end

    test "a deregistered app says so rather than promising a row the page would omit", %{app: app} do
      {:ok, _} = Registry.deregister_app(@ns, app.id, @admin)

      socket = open(%{fleet: :operator_admin, fps1: :operator_admin}, app.id)
      rendered = html(socket)

      assert rendered =~ "deregistered, so the public page omits it entirely"
      refute rendered =~ "Publishing would list"
    end
  end

  # ---------------------------------------------------------------------------
  # RED — the gate, with its positive control
  # ---------------------------------------------------------------------------

  describe "RED — the admin gate (with the admin call as positive control)" do
    test "a fleet role that is NOT :operator_admin is refused: no toggle, nothing flips, the page stays empty",
         %{app: app} do
      socket = open(%{fleet: :operator_readonly, fps1: :operator_readonly}, app.id)

      pre = html(socket)
      assert pre =~ ~s(id="publish-readonly")
      refute pre =~ ~s(id="publish-toggle")
      # The consequence line is INFORMATION (the row's own status is already on this
      # page) — it is the write affordance, not the fact, that the role gates.
      assert pre =~ "Publishing would list fps1 as Down."

      {:noreply, socket} = toggle(socket, true)

      refute published?(app.id)
      assert page_entries() == []

      assert html(socket) =~
               "Only roles[:fleet] == :operator_admin may publish a product on the public status page."

      # POSITIVE CONTROL — the SAME event, admin roles. It flips, so the refusal above
      # is the gate, not a handler that never worked.
      admin_socket = open(%{fleet: :operator_admin, fps1: :operator_admin}, app.id)
      {:noreply, _admin_socket} = toggle(admin_socket, true)

      assert published?(app.id)
      assert [%PublicStatus.Entry{slug: "fps1"}] = page_entries()
    end

    test "a fleet admin with NO role in this product cannot publish it", %{app: app} do
      socket = open(%{fleet: :operator_admin}, app.id)

      # Tier-2 scope: the row's own surface is withheld, so the publish card is too.
      refute html(socket) =~ ~s(id="publish-status-card")

      {:noreply, socket} = toggle(socket, true)

      refute published?(app.id)
      assert page_entries() == []
      assert socket.assigns.publish_error =~ "no role in this product"

      # POSITIVE CONTROL — add the product role and the identical event flips it.
      admin_socket = open(%{fleet: :operator_admin, fps1: :operator_admin}, app.id)
      {:noreply, _admin_socket} = toggle(admin_socket, true)
      assert published?(app.id)
    end

    test "a session with no authenticated principal is refused even if the roles seam is permissive", %{app: app} do
      # A host whose `:fleet_authority` seam answers `:operator_admin` for a nil
      # principal must not let an anonymous request publish: the write is attributed
      # to a principal, so no principal means no write.
      socket = socket_with_mount(%{fleet: :operator_admin, fps1: :operator_admin})

      {:ok, socket} = FleetDetailLive.mount(%{"app_id" => app.id}, %{}, socket)

      {:noreply, socket} = toggle(socket, true)

      refute published?(app.id)
      assert page_entries() == []
      assert socket.assigns.publish_error =~ "Only roles[:fleet] == :operator_admin"
    end
  end

  # ---------------------------------------------------------------------------
  # Fail-closed: a mount with no registry to publish INTO never claims a change
  # ---------------------------------------------------------------------------

  describe "fail-closed" do
    test "a mount with no fleet_namespace refuses the write and publishes nothing", %{app: app} do
      # The runtime belt behind the macro's compile-time refusal: a directly-built
      # `%Mount{}` with `fleet_cockpit: true` and no `:fleet_namespace` label. The read
      # fails closed (`{:missing_namespace, :manual}` — never a registry call with a
      # non-resource module), so the page renders "Fleet not configured", and the event
      # refuses rather than attempting a write against a nil namespace.
      Application.put_env(@otp_app, :fleet_authority, {__MODULE__, :roles_for, [%{fleet: :operator_admin, fps1: :operator_admin}]})

      mount =
        Mount.new(:operator, Samen.WebTest.Operator, Samen.WebTest.Repo,
          plane: Samen.Web.Plane.tenant(),
          labels: %{otp_app: @otp_app, fleet_cockpit: true}
        )

      socket = %Phoenix.LiveView.Socket{} |> Phoenix.Component.assign(:samen_mount, mount)
      {:ok, socket} = FleetDetailLive.mount(%{"app_id" => app.id}, session(), socket)

      refute html(socket) =~ ~s(id="publish-toggle")

      {:noreply, socket} = toggle(socket, true)

      refute published?(app.id)
      assert page_entries() == []
      assert socket.assigns.publish_error =~ "No fleet_namespace is configured on this mount"
    end
  end
end
