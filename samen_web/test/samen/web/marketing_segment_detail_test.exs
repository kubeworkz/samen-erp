defmodule Samen.Web.MarketingSegmentDetailTest do
  @moduledoc """
  The segment DETAIL twin (`Samen.Web.Marketing.SegmentLive`) — the record page
  behind the segments list:

    * **Render** — bounded facts `<dl>` (name / description / filter criteria /
      subscriber count / inserted at) + the PII-resolved audience preview + the
      breadcrumb/back link (org-threaded) + the sidebar's Segments nav active.
    * **Edit (AC-G1-1/2)** — the `AshPhoenix.Form.for_update` modal: an INVALID
      save (blank required name) renders the kit's inline errors and persists
      NOTHING; a valid save persists + re-renders.
    * **Archive** — the `delete_confirm/1` interlock: the E6 archivable destroy
      SOFT-ARCHIVES the segment and navigates back to the list (restorable from
      the segments list's archived view).
    * **Operator posture (belt)** — no write affordance in the operator DOM; the
      audience preview masks •••• through the same PiiResolution chokepoint.
    * **Not found** — a bogus id is the honest not-found state, never a raise.
  """
  use Samen.WebTest.DataCase, async: false

  require Ash.Query

  alias Samen.Web.Marketing.SegmentLive

  setup do
    seeded = Seeds.seed_all()
    %{org_id: seeded.org_id, segment: seeded.marketing.segment}
  end

  # -- harness -----------------------------------------------------------------

  defp mount_socket(org_id, segment_id, plane_opts \\ []) do
    %Phoenix.LiveView.Socket{}
    |> Phoenix.Component.assign(:samen_mount, build_mount(:marketing, plane_opts))
    |> Phoenix.Component.assign(:samen_acting_as, false)
    |> Phoenix.Component.assign(:return_to, nil)
    |> SegmentLive.load(org_id, segment_id)
  end

  defp html(socket), do: render_html(SegmentLive, socket.assigns)

  defp event(socket, name, params) do
    {:noreply, socket} = SegmentLive.handle_event(name, params, socket)
    socket
  end

  defp raw_segment(id) do
    Samen.WebTest.Marketing.Segment
    |> Ash.Query.ensure_selected([:org_id, :name, :description])
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.limit(1)
    |> Ash.read!(authorize?: false)
    |> List.first()
  end

  defp archived_segment(id) do
    Samen.WebTest.Marketing.Segment
    |> Ash.Query.for_read(:archived)
    |> Ash.read!(authorize?: false)
    |> Enum.find(&(&1.id == id))
  end

  # ---------------------------------------------------------------------------

  test "detail renders the facts, the audience preview, breadcrumb/back link, and the active nav",
       %{org_id: org_id, segment: segment} do
    socket = mount_socket(org_id, segment.id)
    rendered = html(socket)

    # The bounded facts <dl> (seeded segment: name + status filter + 1 subscriber).
    assert rendered =~ ~s(id="segment-facts")
    assert rendered =~ Seeds.segment_name()
    assert rendered =~ "status"
    assert rendered =~ "Inserted at"

    # The audience preview carries the seeded ACTIVE subscriber, clear on tenant.
    assert rendered =~ ~s(id="segment-audience")
    assert rendered =~ Seeds.active_subscriber_email()

    # Breadcrumb leaf + the Segments crumb / Back link, org-threaded.
    assert rendered =~ ~s(href="/marketing/segments?org=#{org_id}")
    assert rendered =~ "Back to segments"

    # The sidebar nav item is the active one (`href=… class="on"`).
    assert rendered =~ ~s(href="/marketing/segments?org=#{org_id}" class="on")

    # Write affordances (tenant plane): edit + archive interlock.
    assert rendered =~ ~s(id="edit-segment")
    assert rendered =~ ~s(id="archive-segment")
    assert rendered =~ "data-confirm"
  end

  test "a bogus id renders the honest not-found state", %{org_id: org_id} do
    socket = mount_socket(org_id, Ash.UUID.generate())
    assert html(socket) =~ "Segment not found."
  end

  # ---------------------------------------------------------------------------
  # Edit — invalid persists NOTHING, valid lands
  # ---------------------------------------------------------------------------

  test "EDIT: an invalid save renders inline errors and persists NOTHING; a valid save lands",
       %{org_id: org_id, segment: segment} do
    socket = mount_socket(org_id, segment.id)
    socket = event(socket, "edit_segment", %{})
    assert html(socket) =~ ~s(id="edit-segment-modal")

    socket = event(socket, "validate_edit", %{"form" => %{"name" => ""}})
    socket = event(socket, "save_edit", %{"form" => %{"name" => ""}})

    rendered = html(socket)
    assert rendered =~ ~s(id="edit-segment-modal")
    assert rendered =~ "field-invalid"
    assert rendered =~ "field-error"
    assert raw_segment(segment.id).name == Seeds.segment_name()

    socket = event(socket, "save_edit", %{"form" => %{"name" => "SENTINEL-rename"}})

    refute html(socket) =~ ~s(id="edit-segment-modal")
    assert raw_segment(segment.id).name == "SENTINEL-rename"
    assert html(socket) =~ "SENTINEL-rename"
  end

  # ---------------------------------------------------------------------------
  # Archive — E6 soft-delete + navigate back to the list
  # ---------------------------------------------------------------------------

  test "ARCHIVE: the confirm event soft-archives the segment and navigates back to the list",
       %{org_id: org_id, segment: segment} do
    socket = mount_socket(org_id, segment.id)
    assert html(socket) =~ "data-confirm"

    socket = event(socket, "delete", %{"id" => segment.id})
    assert {:live, :redirect, %{to: to}} = socket.redirected
    assert to =~ "/marketing/segments"

    # E6 archivable destroy: the row is GONE from the default read and present in
    # the archived (trash) view — restorable from the segments list.
    assert raw_segment(segment.id) == nil
    assert archived_segment(segment.id) != nil
  end

  # ---------------------------------------------------------------------------
  # Operator posture (belt) — no write affordance in the DOM; audience masks
  # ---------------------------------------------------------------------------

  test "OPERATOR plane: no edit/archive affordance; the facts render and the audience masks",
       %{org_id: org_id, segment: segment} do
    socket = mount_socket(org_id, segment.id, plane: :operator, target_org_id: org_id)
    rendered = html(socket)

    assert rendered =~ ~s(id="segment-facts")
    assert rendered =~ Seeds.segment_name()
    refute rendered =~ ~s(id="edit-segment")
    refute rendered =~ ~s(id="archive-segment")
    refute rendered =~ "data-confirm"
    refute rendered =~ ~s(phx-click="delete")

    # The audience preview rides the same PiiResolution chokepoint: ••••, no
    # plaintext, no vault token.
    assert rendered =~ "••••"
    refute rendered =~ Seeds.active_subscriber_email()
    refute rendered =~ "vt_"
  end
end
