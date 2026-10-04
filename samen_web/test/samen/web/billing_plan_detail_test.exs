defmodule Samen.Web.BillingPlanDetailTest do
  @moduledoc """
  The plan DETAIL twin (`Samen.Web.Billing.PlanLive`) — the record page behind
  the plans list:

    * **Render** — bounded facts `<dl>` + the REAL granted feature chips (never a
      fabricated default) + the plan's price rows + breadcrumb/back link (org-
      threaded) + the sidebar's Plans nav item marked active.
    * **Edit (AC-G1-1/2)** — the `AshPhoenix.Form.for_update` modal: an INVALID
      save (blank required name) renders the kit's inline errors and persists
      NOTHING; a valid save persists + re-renders.
    * **Enable/disable** — the sanctioned `Reads.toggle_plan/3` flips `enabled`
      through the admin write scope.
    * **Archive** — the `delete_confirm/1` interlock: the E6 archivable destroy
      SOFT-ARCHIVES the plan and navigates back to the list (restorable from the
      plans list's archived view).
    * **Operator posture (belt)** — no write affordance in the operator DOM.
    * **Not found** — a bogus id is the honest not-found state, never a raise.
  """
  use Samen.WebTest.DataCase, async: false

  require Ash.Query

  alias Samen.Web.Billing.PlanLive

  setup do
    seeded = Seeds.seed_all()
    %{org_id: seeded.org_id, plan: seeded.billing.plan}
  end

  # -- harness -----------------------------------------------------------------

  defp mount_socket(org_id, plan_id, plane_opts \\ []) do
    %Phoenix.LiveView.Socket{}
    |> Phoenix.Component.assign(:samen_mount, build_mount(:billing, plane_opts))
    |> Phoenix.Component.assign(:samen_acting_as, false)
    |> Phoenix.Component.assign(:return_to, nil)
    |> PlanLive.load(org_id, plan_id)
  end

  defp html(socket), do: render_html(PlanLive, socket.assigns)

  defp event(socket, name, params) do
    {:noreply, socket} = PlanLive.handle_event(name, params, socket)
    socket
  end

  defp raw_plan(id) do
    Samen.WebTest.Billing.Plan
    |> Ash.Query.ensure_selected([:org_id, :name, :enabled])
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.limit(1)
    |> Ash.read!(authorize?: false)
    |> List.first()
  end

  defp archived_plan(id) do
    Samen.WebTest.Billing.Plan
    |> Ash.Query.for_read(:archived)
    |> Ash.read!(authorize?: false)
    |> Enum.find(&(&1.id == id))
  end

  defp fresh_plan(org_id, attrs) do
    Samen.WebTest.Billing.Plan
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(%{org_id: org_id, name: "scratch", interval: :monthly, enabled: true}, attrs),
      authorize?: false
    )
    |> Ash.create!()
  end

  # ---------------------------------------------------------------------------

  test "detail renders the facts, price rows, breadcrumb/back link, and the active nav",
       %{org_id: org_id, plan: plan} do
    socket = mount_socket(org_id, plan.id)
    rendered = html(socket)

    assert rendered =~ ~s(id="plan-facts")
    assert rendered =~ "Growth"
    assert rendered =~ "growth"

    # The seeded price (29900 cents) renders on the detail page.
    assert rendered =~ ~s(id="plan-prices")
    assert rendered =~ "$299.00"

    # Breadcrumb leaf + the Plans crumb / Back link, org-threaded.
    assert rendered =~ ~s(href="/billing/plans?org=#{org_id}")
    assert rendered =~ "Back to plans"

    # The sidebar nav item is the active one (`href=… class="on"`).
    assert rendered =~ ~s(href="/billing/plans?org=#{org_id}" class="on")

    # Write affordances (tenant plane): edit + archive interlock + the toggle.
    assert rendered =~ ~s(id="edit-plan")
    assert rendered =~ ~s(id="archive-plan")
    assert rendered =~ "data-confirm"
    assert rendered =~ ~s(id="toggle-enabled")
    assert rendered =~ "Disable plan"
  end

  test "the feature chips render REAL granted keys only (no fabricated default)",
       %{org_id: org_id, plan: plan} do
    # The seeded plan carries an empty feature map — the honest empty state.
    seeded_socket = mount_socket(org_id, plan.id)
    assert html(seeded_socket) =~ "No features granted on this plan."

    featured = fresh_plan(org_id, %{name: "chipper", features: %{"api_access" => true, "sso" => true}})
    socket = mount_socket(org_id, featured.id)
    rendered = html(socket)

    assert rendered =~ ~s(id="plan-features")
    assert rendered =~ "api access"
    assert rendered =~ "sso"
    refute rendered =~ "No features granted on this plan."
  end

  test "a bogus id renders the honest not-found state", %{org_id: org_id} do
    socket = mount_socket(org_id, Ash.UUID.generate())
    assert html(socket) =~ "Plan not found."
  end

  # ---------------------------------------------------------------------------
  # Edit — invalid persists NOTHING, valid lands
  # ---------------------------------------------------------------------------

  test "EDIT: an invalid save renders inline errors and persists NOTHING; a valid save lands",
       %{org_id: org_id, plan: plan} do
    socket = mount_socket(org_id, plan.id)
    socket = event(socket, "edit_plan", %{})
    assert html(socket) =~ ~s(id="edit-plan-modal")

    socket = event(socket, "validate_edit", %{"form" => %{"name" => ""}})
    socket = event(socket, "save_edit", %{"form" => %{"name" => ""}})

    rendered = html(socket)
    assert rendered =~ ~s(id="edit-plan-modal")
    assert rendered =~ "field-invalid"
    assert rendered =~ "field-error"
    assert raw_plan(plan.id).name == "growth"

    socket = event(socket, "save_edit", %{"form" => %{"name" => "growth-plus", "label" => "Growth+"}})

    refute html(socket) =~ ~s(id="edit-plan-modal")
    raw = raw_plan(plan.id)
    assert raw.name == "growth-plus"
    assert html(socket) =~ "Growth+"
  end

  # ---------------------------------------------------------------------------
  # Enable/disable — the sanctioned toggle
  # ---------------------------------------------------------------------------

  test "TOGGLE: the status-actions button flips enabled through the sanctioned update",
       %{org_id: org_id, plan: plan} do
    assert raw_plan(plan.id).enabled

    socket = mount_socket(org_id, plan.id)
    assert html(socket) =~ "Disable plan"

    socket = event(socket, "toggle_enabled", %{})
    refute raw_plan(plan.id).enabled
    assert html(socket) =~ "Enable plan"

    _socket = event(socket, "toggle_enabled", %{})
    assert raw_plan(plan.id).enabled
  end

  # ---------------------------------------------------------------------------
  # Archive — E6 soft-delete + navigate back to the list
  # ---------------------------------------------------------------------------

  test "ARCHIVE: the confirm event soft-archives the plan and navigates back to the list",
       %{org_id: org_id, plan: plan} do
    socket = mount_socket(org_id, plan.id)
    assert html(socket) =~ "data-confirm"

    socket = event(socket, "delete", %{"id" => plan.id})
    assert {:live, :redirect, %{to: to}} = socket.redirected
    assert to =~ "/billing/plans"

    # E6 archivable destroy: the row is GONE from the default read and present in
    # the archived (trash) view — restorable from the plans list.
    assert raw_plan(plan.id) == nil
    assert archived_plan(plan.id) != nil
  end

  # ---------------------------------------------------------------------------
  # Operator posture (belt) — no write affordance in the DOM
  # ---------------------------------------------------------------------------

  test "OPERATOR plane: no edit/archive/toggle affordance; the facts still render",
       %{org_id: org_id, plan: plan} do
    socket = mount_socket(org_id, plan.id, plane: :operator, target_org_id: org_id)
    rendered = html(socket)

    assert rendered =~ ~s(id="plan-facts")
    refute rendered =~ ~s(id="edit-plan")
    refute rendered =~ ~s(id="archive-plan")
    refute rendered =~ ~s(id="toggle-enabled")
    refute rendered =~ "data-confirm"
    refute rendered =~ ~s(phx-click="delete")
  end
end
