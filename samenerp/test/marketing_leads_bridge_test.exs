defmodule Samenerp.MarketingLeadsBridgeTest do
  @moduledoc """
  The Marketing↔CRM NAMESPACE-BRIDGE host guard (`:crm_namespace` on the router-built
  Marketing mount) — the seam `Samen.Web.Marketing.Live.crm_mount/1` reads to derive a
  CRM-kind mount for:

    * the **Leads lens** (`/marketing/leads`) — the `Person` rows whose
      `custom["lifecycle_stage"]` is in the early funnel;
    * the **read-only Lead detail page** (`/marketing/leads/:id`).

  Why this lives in the HOST test suite and not `samen_web`'s: the label is expanded at
  COMPILE TIME from `SamenerpWeb.Router`'s `@current_org_labels` seam into the
  `live_session` session. Every `samen_web` test builds its mount through
  `build_mount(:marketing, ...)`, which sets the label itself — so the framework suite
  stays green while a host that forgets the wiring silently ships an always-empty leads
  list and an always-"Lead not found." detail page. That is the honest-ABSENT posture
  (never a crash, so nothing ever reaches the logs), and it is exactly the trap
  `Samenerp.DirectoryTest` documents for `org_directory`: "a hand-built mount would not
  catch a missing router label."

  The proof is a real DEAD RENDER through the router — no mount constructed here.
  """

  use Samenerp.DataCase, async: false

  import Phoenix.ConnTest

  alias Samen.Info
  alias Samenerp.Crm
  alias Samenerp.Operator, as: Op

  @endpoint SamenerpWeb.Endpoint

  setup do
    # ExUnit-owned endpoint lifecycle (the same owner `Samenerp.DirectoryTest` uses):
    # the app supervisor starts NO web children under test, so this is the only stable
    # owner for a dispatched request.
    start_supervised!(SamenerpWeb.Endpoint)
    :ok
  end

  defp create_org!(name) do
    Op.Org
    |> Ash.Changeset.for_create(:create, %{name: name}, authorize?: false)
    |> Ash.create!(authorize?: false)
  end

  # The Tier-1 custom field must be REGISTERED before a `custom` bag value writes (the
  # tnt_field rule) — the same ordering `samen_web`'s leads-list test uses. The physical
  # table comes from the resource's own abbrev, so this never hardcodes a host prefix.
  defp seed_lead(org_id, display_name) do
    table = Info.abbrev(Crm.Person) <> "_person"

    {:ok, _} =
      Samen.CustomFields.define_field(
        %{org_id: org_id, table_name: table, field_name: "lifecycle_stage", type: :string},
        Samenerp.Repo
      )

    Crm.Person
    |> Ash.Changeset.for_create(
      :create,
      %{org_id: org_id, display_name: display_name, custom: %{"lifecycle_stage" => "lead"}},
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end

  test "the router-mounted Marketing surfaces bridge to this host's CRM namespace" do
    tenant = create_org!("Gridworkz QA")
    lead = seed_lead(tenant.id, "Zoe Leadward")

    list = get(build_conn(), "/marketing/leads?org=#{tenant.id}")
    assert list.status == 200

    assert list.resp_body =~ "Zoe Leadward",
           "the leads lens rendered no rows — is :crm_namespace still wired on the " <>
             "router's Marketing mount? Absent it, Samen.Web.Marketing.Live.crm_mount/1 " <>
             "returns nil and the lens is inert by design (never a crash)."

    refute list.resp_body =~ "No leads in the early funnel yet."

    detail = get(build_conn(), "/marketing/leads/#{lead.id}?org=#{tenant.id}")
    assert detail.status == 200

    assert detail.resp_body =~ "Zoe Leadward",
           "the lead detail page fell back to its honest not-found posture — the " <>
             ":crm_namespace bridge is missing on the router's Marketing mount."

    refute detail.resp_body =~ "Lead not found."

    # Read-only by design: the detail page wires no write affordance.
    refute detail.resp_body =~ ~s(phx-click="delete)

    # The "Open in CRM" bridge points at this host's CRM route prefix.
    assert detail.resp_body =~ "/crm/contacts/#{lead.id}?org=#{tenant.id}"
  end
end
