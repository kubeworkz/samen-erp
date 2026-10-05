defmodule Samenerp.CrmContactDetailTest do
  @moduledoc """
  The CRM DETAIL surfaces on THIS host — dead renders through the real router, no
  mount constructed here.

  Why this belongs in the host suite: `Samen.Web.CRM.ContactLive.load/3` (and the
  company sibling) builds the log-activity composer from `CRM.Reads.work_task_resource/1`,
  which derives the host's Work `Task` module from the mount's namespace root. This host
  mounts NO `Samen.Scopes.Work` domain (and its schema has no task table), so that
  derivation is `nil` — the framework-documented outcome every OTHER caller treats as an
  honest absence (`activities_for_person/3` rescues to `[]`, the leaderboard falls back
  to its empty shape). The composer builder did NOT: `AshPhoenix.Form.for_create(nil, …)`
  RAISED during mount, so `/crm/contacts/:id` 500ed for every contact in prod — the page
  the marketing lead detail's "Open in CRM" link targets.

  The framework suite structurally cannot catch this: its test host DOES mount Work
  (`samen_web/test/support/work.ex`), so `work_task_resource/1` always resolves there and
  the `nil` branch is unreachable — exactly the blind spot this guard documents (the same
  trap `Samenerp.MarketingLeadsBridgeTest` documents for `:crm_namespace`).

  Guarded here:
    * `/crm/contacts/:id` — 200 + the contact's facts, and NO `log-activity-form`
      (honest absence: no Work scope ⇒ no composer, never a crash).
    * `/crm/contacts/:id?tab=activity` — the timeline renders its empty state, composer
      still absent.
    * `/crm/companies/:id` — the sibling detail page, same composer code path.
  """

  use Samenerp.DataCase, async: false

  import Phoenix.ConnTest

  alias Samenerp.Crm
  alias Samenerp.Operator, as: Op

  @endpoint SamenerpWeb.Endpoint

  setup do
    # ExUnit-owned endpoint lifecycle (same owner as DirectoryTest / the leads bridge
    # test): the app supervisor starts NO web children under test, so this is the only
    # stable owner for a dispatched request.
    start_supervised!(SamenerpWeb.Endpoint)
    :ok
  end

  defp create_org!(name) do
    Op.Org
    |> Ash.Changeset.for_create(:create, %{name: name}, authorize?: false)
    |> Ash.create!(authorize?: false)
  end

  defp seed_person(org_id) do
    Crm.Person
    |> Ash.Changeset.for_create(
      :create,
      %{org_id: org_id, display_name: "Remy Route", job_title: "Depot Coordinator"},
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end

  defp seed_company(org_id) do
    Crm.Company
    |> Ash.Changeset.for_create(
      :create,
      %{org_id: org_id, name: "Walkthrough Haulage"},
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end

  test "the CRM contact detail page renders on a host with no Work scope" do
    tenant = create_org!("CRM Detail QA")
    person = seed_person(tenant.id)

    detail = get(build_conn(), "/crm/contacts/#{person.id}?org=#{tenant.id}")

    assert detail.status == 200,
           "the contact detail page did not render — did activity_form/2 start " <>
             "building the composer from a nil work_task_resource/1 again? On a host " <>
             "with NO Samen.Scopes.Work mount that nil is the documented outcome, and " <>
             "`AshPhoenix.Form.for_create(nil, …)` raises during mount (the prod 500 " <>
             "behind the lead page's \"Open in CRM\" link)."

    body = detail.resp_body
    assert body =~ "Remy Route", "the seeded contact did not render"
    assert body =~ "Depot Coordinator", "the contact's job title did not render"
    refute body =~ "Contact not found."

    # Honest absence: no Work scope on this host ⇒ no composer, never a broken form.
    refute body =~ "log-activity-form",
           "the activity composer rendered — but this host mounts no Work scope, so it " <>
             "would have no Task resource to write to."

    # The Activity tab renders the timeline empty state with the plainer copy (no
    # composer is promised when none will render).
    acts = get(build_conn(), "/crm/contacts/#{person.id}?org=#{tenant.id}&tab=activity")
    assert acts.status == 200
    assert acts.resp_body =~ "No activity yet."
    refute acts.resp_body =~ "log-activity-form"
  end

  test "the CRM company detail page renders on a host with no Work scope" do
    tenant = create_org!("CRM Company QA")
    company = seed_company(tenant.id)

    detail = get(build_conn(), "/crm/companies/#{company.id}?org=#{tenant.id}")

    assert detail.status == 200,
           "the company detail page did not render — it shares the activity_form/2 " <>
             "nil-crash with the contact page (see the contact test above)."

    body = detail.resp_body
    assert body =~ "Walkthrough Haulage", "the seeded company did not render"
    refute body =~ "Company not found."
    refute body =~ "log-activity-form"
  end
end
