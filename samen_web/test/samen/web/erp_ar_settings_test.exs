defmodule Samen.Web.ErpArSettingsTest do
  @moduledoc """
  The AR collections cadence settings page (`/erp/ar-settings`) over the REAL
  `Samen.WebTest.Erp.CollectionCadence` resource:

    * the page renders the effective defaults and a create form when the org has
      no row;
    * an admin can create a custom cadence, including disabling a stage;
    * an admin can update an existing row;
    * an interval outside 1..365 is refused inline and persists nothing;
    * an armed member sees the page read-only and a crafted save writes nothing;
    * the operator plane carries no form.
  """

  use Samen.WebTest.DataCase, async: false

  alias Samen.Web.Erp.ArSettingsLive
  alias Samen.WebTest.Erp.CollectionCadence

  @org "55555555-6666-7777-8888-999999999999"

  # -- harness ----------------------------------------------------------------

  defp open(params \\ %{"org" => @org}) do
    mount = build_mount(:erp)
    session = mount_session(mount)
    {:ok, socket} = ArSettingsLive.mount(params, session, %Phoenix.LiveView.Socket{})

    {:noreply, socket} =
      ArSettingsLive.handle_params(params, "http://localhost/erp/ar-settings", socket)

    socket
  end

  defp event(socket, name, params) do
    {:noreply, socket} = ArSettingsLive.handle_event(name, params, socket)
    socket
  end

  defp render(socket), do: render_html(ArSettingsLive, socket.assigns)

  # -- seeds ------------------------------------------------------------------

  defp seed_cadence(attrs \\ %{}) do
    CollectionCadence
    |> Ash.Changeset.for_create(:create, Map.merge(%{org_id: @org}, attrs), authorize?: false)
    |> Ash.create!()
  end

  defp cadences do
    CollectionCadence
    |> Ash.Query.ensure_selected([
      :org_id,
      :notice_enabled,
      :final_notice_enabled,
      :collections_enabled,
      :notice_days,
      :final_notice_days,
      :collections_days
    ])
    |> Ash.read!(authorize?: false)
  end

  defp only_cadence, do: cadences() |> List.first()

  # -- read -------------------------------------------------------------------

  test "renders the effective defaults and a create form inside the ERP shell" do
    html = render(open())

    assert html =~ ~s(id="erp-ar-settings")
    assert html =~ ~s(class="app")
    assert html =~ ~s(href="/erp/ar-settings?org=#{@org}" class="on")
    assert html =~ "AR settings"
    assert html =~ "Defaults in effect"
    assert html =~ "<b>14</b>"
    assert html =~ "<b>21</b>"
    assert html =~ "<b>30</b>"
    assert html =~ ~s(id="ar-settings-form")
    assert html =~ ~s(id="save-ar-settings")
    refute html =~ "Custom cadence saved"
  end

  # -- create -----------------------------------------------------------------

  test "an admin can create a custom cadence, including disabling a stage" do
    socket =
      event(open(), "save", %{
        "form" => %{
          "notice_enabled" => "false",
          "notice_days" => "7",
          "final_notice_enabled" => "true",
          "final_notice_days" => "10",
          "collections_enabled" => "true",
          "collections_days" => "20"
        }
      })

    assert socket.assigns.save_error == nil
    assert socket.assigns.saved

    assert [cadence] = cadences()
    assert cadence.org_id == @org
    refute cadence.notice_enabled
    assert cadence.notice_days == 7
    assert cadence.final_notice_enabled
    assert cadence.final_notice_days == 10
    assert cadence.collections_enabled
    assert cadence.collections_days == 20

    html = render(socket)
    assert html =~ ~s(id="ar-settings-saved")
    assert html =~ "Custom cadence saved"
    assert html =~ "Disabled"
    assert html =~ "<b>7</b>"
    assert html =~ "<b>10</b>"
    assert html =~ "<b>20</b>"
  end

  # -- update -----------------------------------------------------------------

  test "an admin can update an existing cadence" do
    seed_cadence(%{notice_days: 14, final_notice_days: 21, collections_days: 30})

    socket =
      event(open(), "save", %{
        "form" => %{
          "notice_enabled" => "true",
          "notice_days" => "5",
          "final_notice_enabled" => "false",
          "final_notice_days" => "9",
          "collections_enabled" => "true",
          "collections_days" => "12"
        }
      })

    assert socket.assigns.save_error == nil
    assert socket.assigns.saved

    cadence = only_cadence()
    assert cadence.notice_days == 5
    refute cadence.final_notice_enabled
    assert cadence.final_notice_days == 9
    assert cadence.collections_days == 12

    html = render(socket)
    assert html =~ "Custom cadence saved"
    assert html =~ ~s(id="ar-settings-saved")
  end

  # -- kernel validation ------------------------------------------------------

  test "an interval below one day is refused inline and persists nothing" do
    seed_cadence(%{notice_days: 14})

    socket =
      event(open(), "save", %{
        "form" => %{
          "notice_enabled" => "true",
          "notice_days" => "0",
          "final_notice_enabled" => "true",
          "final_notice_days" => "21",
          "collections_enabled" => "true",
          "collections_days" => "30"
        }
      })

    assert render(socket) =~ "field-invalid"

    cadence = only_cadence()
    assert cadence.notice_days == 14
    assert cadence.final_notice_days == 21
    assert cadence.collections_days == 30
  end

  # -- authorization ----------------------------------------------------------

  test "an armed member sees the page read-only and a crafted save writes nothing" do
    seed_cadence(%{notice_days: 14})

    # `:required` is the armed tenant gate; with no resolvable membership the
    # admin scope correctly fails closed to `:member`.
    mount = %{build_mount(:erp) | labels: %{authn: :required}}

    socket =
      %Phoenix.LiveView.Socket{}
      |> Phoenix.Component.assign(:samen_mount, mount)
      |> Phoenix.Component.assign(:org_id, @org)
      |> Phoenix.Component.assign(:samen_acting_as, false)
      |> Phoenix.Component.assign(:return_to, nil)
      |> ArSettingsLive.load()

    html = render(socket)
    refute html =~ ~s(id="ar-settings-form")
    assert html =~ "Only an organization admin can change the collection cadence."

    socket =
      event(socket, "save", %{
        "form" => %{
          "notice_enabled" => "false",
          "notice_days" => "1",
          "final_notice_enabled" => "false",
          "final_notice_days" => "1",
          "collections_enabled" => "false",
          "collections_days" => "1"
        }
      })

    cadence = only_cadence()
    assert cadence.notice_enabled
    assert cadence.notice_days == 14
    assert render(socket) =~ "Only an organization admin can change the collection cadence."
  end

  test "the operator plane carries no write affordance" do
    seed_cadence()

    mount = build_mount(:erp, plane: :operator, target_org_id: @org)
    session = mount_session(mount)
    params = %{"org" => @org}

    {:ok, socket} = ArSettingsLive.mount(params, session, %Phoenix.LiveView.Socket{})

    {:noreply, socket} =
      ArSettingsLive.handle_params(params, "http://localhost/erp/ar-settings", socket)

    html = render(socket)
    refute html =~ ~s(id="ar-settings-form")
    assert html =~ "Read-only on this plane."
  end
end
