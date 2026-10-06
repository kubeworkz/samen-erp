defmodule Samenerp.CrmContactDetailTest do
  @moduledoc """
  The CRM DETAIL surfaces on THIS host — dead renders through the real router, no
  mount constructed here.

  Why this belongs in the host suite: `Samen.Web.CRM.ContactLive.load/3` (and the
  company sibling) builds the log-activity composer from `CRM.Reads.work_task_resource/1`,
  which derives the host's Work `Task` module from the mount's namespace root. UNTIL
  E15 this host mounted NO `Samen.Scopes.Work` domain (and its schema had no task
  table), so that derivation was `nil` — the framework-documented outcome every OTHER caller treats as an
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
      on the overview tab (the composer is an activity-tab slot).
    * `/crm/contacts/:id?tab=activity` — the timeline renders its empty state.
    * `/crm/companies/:id` — the sibling detail page, same composer code path.
    * `work_task_resource/1` → `nil` for a namespace root with no Work mount (the
      honest-absence derivation the crash-guard `case … nil -> nil` rests on).

  E15 UPDATE: this host NOW mounts Work (`Samenerp.Work` via `samen_module_routes(:work, …)`),
  so `work_task_resource/1` resolves `Samenerp.Work.Task` and the composer legitimately
  renders on the activity tab — the empty state uses the composer-aware copy ("No activity
  yet — log the first call or note below."), not the bare "No activity yet." no-composer
  variant. The nil branch is therefore unreachable through THIS host's router and is pinned
  at the derivation level below instead (the framework suite still cannot reach it: its test
  host mounts Work too).
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

  test "the CRM contact detail page renders (this host mounts Work since E15)" do
    tenant = create_org!("CRM Detail QA")
    person = seed_person(tenant.id)

    detail = get(build_conn(), "/crm/contacts/#{person.id}?org=#{tenant.id}")

    assert detail.status == 200,
           "the contact detail page did not render — did activity_form/2 stop " <>
             "guarding a nil work_task_resource/1? That nil is the documented " <>
             "outcome on a host with NO Samen.Scopes.Work mount, and " <>
             "`AshPhoenix.Form.for_create(nil, …)` raises during mount (the prod 500 " <>
             "behind the lead page's \"Open in CRM\" link)."

    body = detail.resp_body
    assert body =~ "Remy Route", "the seeded contact did not render"
    assert body =~ "Depot Coordinator", "the contact's job title did not render"
    refute body =~ "Contact not found."

    # The overview tab never carries the composer (it is an activity-tab slot),
    # Work scope mounted or not.
    refute body =~ "log-activity-form",
           "the activity composer rendered on the OVERVIEW tab — it belongs to the " <>
             "activity tab only."

    # E15: Work is mounted ⇒ the composer renders and the empty state carries the
    # composer-aware copy. The bare "No activity yet." sentence is the no-composer
    # variant this host produced BEFORE E15.
    acts = get(build_conn(), "/crm/contacts/#{person.id}?org=#{tenant.id}&tab=activity")
    assert acts.status == 200
    assert acts.resp_body =~ "log-activity-form",
           "the activity composer did not render — this host mounts Samenerp.Work, " <>
             "so work_task_resource/1 must resolve Samenerp.Work.Task."
    assert acts.resp_body =~ "No activity yet"
  end

  test "work_task_resource/1 is nil for a namespace root with no Work mount" do
    # The honest-absence pin the composer crash-guard (`case … nil -> nil`) rests
    # on: no `<Root>.Work` / `<Root>.WorkScope` resource under the mount's host
    # root ⇒ nil, never a half-built form. THIS host's router can no longer reach
    # that branch (E15 mounted Work), so the derivation is pinned directly.
    mount = Samen.Web.Mount.new(:crm, Samenerp.CrmContactDetailTest.NoWork.Crm, Samenerp.Repo)
    assert Samen.Web.CRM.Reads.work_task_resource(mount) == nil
  end

  test "the CRM company detail page renders (overview tab carries no composer)" do
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
