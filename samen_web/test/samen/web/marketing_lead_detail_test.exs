defmodule Samen.Web.MarketingLeadDetailTest do
  @moduledoc """
  The lead DETAIL twin (`Samen.Web.Marketing.LeadLive`) — the READ-ONLY record
  page behind the leads lens:

    * **Render** — the CRM person's facts (name / email / phone / title / company /
      lifecycle stage), plane-resolved through `Samen.Web.CRM.Reads.get_contact/3`
      + the breadcrumb/back link (org-threaded) + the sidebar's Leads nav active +
      the "Open in CRM" jump (the CRUD lives on the CRM surface).
    * **Read-only by design** — NO edit modal, NO delete interlock, NO create form:
      the lens's doctrine ("leads ARE CRM people") holds on the detail twin too.
    * **Not found** — a bogus id is the honest not-found state, never a raise.
    * **Per-plane masking (the PII surface)** — tenant reads name/email/phone
      CLEAR; the operator plane renders the SAME facts •••• with plaintext and
      the vault token absent.
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.Web.Marketing.LeadLive

  setup do
    seeded = Seeds.seed_all()
    %{org_id: seeded.org_id, lead: seeded.crm.person}
  end

  # -- harness -----------------------------------------------------------------

  defp mount_socket(org_id, lead_id, plane_opts \\ []) do
    %Phoenix.LiveView.Socket{}
    |> Phoenix.Component.assign(:samen_mount, build_mount(:marketing, plane_opts))
    |> Phoenix.Component.assign(:samen_acting_as, false)
    |> Phoenix.Component.assign(:return_to, nil)
    |> LeadLive.load(org_id, lead_id)
  end

  defp html(socket), do: render_html(LeadLive, socket.assigns)

  # ---------------------------------------------------------------------------

  test "detail renders the lead's facts (clear), breadcrumb/back link, active nav, and Open in CRM",
       %{org_id: org_id, lead: lead} do
    rendered = html(mount_socket(org_id, lead.id))

    # The bounded facts <dl> — seeded CRM person (lifecycle "lead").
    assert rendered =~ ~s(id="lead-facts")
    assert rendered =~ Seeds.contact_full_name()
    assert rendered =~ Seeds.contact_email()
    assert rendered =~ Seeds.contact_phone()
    assert rendered =~ "Head of Logistics"
    assert rendered =~ "Northwind Freight Co"
    # The lifecycle pill (stage "lead" → the info variant).
    assert rendered =~ ~s(class="pill info")

    # Breadcrumb leaf + the Leads crumb / Back link, org-threaded.
    assert rendered =~ ~s(href="/marketing/leads?org=#{org_id}")
    assert rendered =~ "Back to leads"

    # The sidebar nav item is the active one (`href=… class="on"`).
    assert rendered =~ ~s(href="/marketing/leads?org=#{org_id}" class="on")

    # The Open-in-CRM jump to the CRUD surface for this person.
    assert rendered =~ ~s(id="open-in-crm")
    assert rendered =~ ~s(href="/crm/contacts/#{lead.id}?org=#{org_id}")
  end

  test "read-only by design: the detail page offers no write affordance",
       %{org_id: org_id, lead: lead} do
    rendered = html(mount_socket(org_id, lead.id))

    # Non-vacuous: the facts DO render…
    assert rendered =~ ~s(id="lead-facts")
    assert rendered =~ Seeds.contact_full_name()

    # …but no write affordance: no delete interlock, no create/edit modal or form,
    # no "New/Edit/Archive …" trigger. (Navigation links are not writes.)
    refute rendered =~ "data-confirm"
    refute rendered =~ ~s(role="dialog")
    refute rendered =~ ~s(phx-click="new_)
    refute rendered =~ ~s(phx-submit="save)
    refute rendered =~ ~s(phx-click="delete")
    refute rendered =~ "id=\"edit-"
    refute rendered =~ "Edit lead"
    refute rendered =~ "Archive"
  end

  test "a bogus id renders the honest not-found state", %{org_id: org_id} do
    socket = mount_socket(org_id, Ash.UUID.generate())
    assert html(socket) =~ "Lead not found."
  end

  # ---------------------------------------------------------------------------
  # PER-PLANE MASKING — the PII detail surface
  # ---------------------------------------------------------------------------

  test "OPERATOR plane: the SAME facts mask •••• — plaintext and vault token absent",
       %{org_id: org_id, lead: lead} do
    rendered = html(mount_socket(org_id, lead.id, plane: :operator, target_org_id: org_id))

    # Non-vacuous: the record page still renders (facts card + non-PII fields).
    assert rendered =~ ~s(id="lead-facts")
    assert rendered =~ "Head of Logistics"
    assert rendered =~ "Northwind Freight Co"

    # …masked.
    assert rendered =~ "••••"
    refute rendered =~ Seeds.contact_full_name()
    refute rendered =~ Seeds.contact_email()
    refute rendered =~ Seeds.contact_phone()
    refute rendered =~ "vt_"
  end
end
