defmodule PawChartWeb.SessionOrgMembershipGateTest do
  @moduledoc """
  End-to-end regression for pawchart's SESSION-write membership gate
  (`POST /session/org/:org_id` — the workspace switcher / operator "Open account").

  Drives the real armed browser pipeline: real `/login`, the CSRF-protected switch, and the
  tenant CRM read (`/crm/companies`). Proves:

    * a principal switching to a tenant they do NOT belong to is refused with 403, the session
      is never written, and that tenant's CRM data never renders; and
    * a tenant the principal DOES belong to (a real `PawChart.Operator` User + Membership)
      switches successfully (302 + session write) and reads its CRM data.

  The orgs are advertised to the switcher through operator-side Bridge-B `PawChart.Operator.Org`
  account rows whose `slug` is the tenant-org id (`PawChart.Directory`), exactly as the operator
  console lists accounts. Pawchart's legacy `:authorized_orgs` seam
  (`PawChart.Auth.authorized_org_ids/1`) resolves the session user's own Membership set — the
  same set its read path uses — so the positive control is the clinic org that principal holds.
  """
  use PawChart.DataCase, async: false

  import Phoenix.ConnTest
  import Plug.Conn, only: [get_session: 2]

  alias PawChart.Operator, as: Op
  alias Samen.Web.CurrentOrg

  @endpoint PawChartWeb.Endpoint
  @password "OperatorActAs!2026x9"

  setup do
    start_supervised!(PawChartWeb.Endpoint)

    # The prod posture: without arming, `CurrentOrg` trusts the ?org=/session convenience and
    # the switch endpoint could not tell an authorized tenant from a forged one.
    prev_armed = Application.get_env(:pawchart, :auth_required?)
    Application.put_env(:pawchart, :auth_required?, true)

    on_exit(fn ->
      case prev_armed do
        nil -> Application.delete_env(:pawchart, :auth_required?)
        value -> Application.put_env(:pawchart, :auth_required?, value)
      end
    end)

    operator_org_id = Application.fetch_env!(:pawchart, :operator_org_id)
    ensure_operator_org!(operator_org_id)

    unique = System.unique_integer([:positive])
    email = "session-gate-#{unique}@example.test"
    credential = credential!(email)

    clinic_org = org!("Happy Paws #{unique}")
    user_with_membership!(clinic_org.id, credential, :owner)
    account_row!(operator_org_id, clinic_org, "Happy Paws #{unique}")
    clinic_company = company!(clinic_org.id, "CLN#{unique} Clinic patient")

    foreign_org = org!("Foreign Clinic #{unique}")
    account_row!(operator_org_id, foreign_org, "Foreign #{unique}")
    foreign_company = company!(foreign_org.id, "FRN#{unique} Foreign patient")

    {:ok,
     email: email,
     credential: credential,
     clinic_org: clinic_org,
     clinic_company: clinic_company,
     foreign_org: foreign_org,
     foreign_company: foreign_company}
  end

  test "a non-member principal cannot switch into a tenant or read its CRM data", %{
    email: email,
    clinic_company: clinic_company,
    foreign_org: foreign_org,
    foreign_company: foreign_company
  } do
    conn = sign_in(email)
    assert conn.status == 302

    page = conn |> recycle() |> get("/crm/companies")
    assert page.status == 200
    # The switcher really offers the foreign tenant, so the refusal below is not vacuous.
    assert page.resp_body =~ "/session/org/#{foreign_org.id}"
    # Control: the principal's own tenant data IS readable on this page.
    assert page.resp_body =~ clinic_company.name

    switched =
      page
      |> recycle()
      |> post("/session/org/#{foreign_org.id}", %{
        "_csrf_token" => csrf_token(page),
        "return_to" => "/crm/companies"
      })

    assert switched.status == 403
    assert switched.resp_body =~ "not a member of that workspace"
    refute get_session(switched, CurrentOrg.session_key()) == foreign_org.id

    after_page = switched |> recycle() |> get("/crm/companies")
    assert after_page.status == 200
    refute after_page.resp_body =~ foreign_company.name
  end

  test "a member principal can switch into the tenant and read its CRM data", %{
    email: email,
    clinic_org: clinic_org,
    clinic_company: clinic_company
  } do
    conn = sign_in(email)
    assert conn.status == 302

    page = conn |> recycle() |> get("/crm/companies")
    assert page.status == 200
    assert page.resp_body =~ "/session/org/#{clinic_org.id}"

    switched =
      page
      |> recycle()
      |> post("/session/org/#{clinic_org.id}", %{
        "_csrf_token" => csrf_token(page),
        "return_to" => "/crm/companies"
      })

    assert redirected_to(switched) == "/crm/companies"
    assert get_session(switched, CurrentOrg.session_key()) == clinic_org.id

    clinic_page = switched |> recycle() |> get("/crm/companies")
    assert clinic_page.status == 200
    assert clinic_page.resp_body =~ clinic_company.name
  end

  defp sign_in(email) do
    login = build_conn() |> get("/login")
    assert login.status == 200

    login
    |> recycle()
    |> post("/login", %{
      "login" => %{"email" => email, "password" => @password},
      "_csrf_token" => csrf_token(login)
    })
  end

  defp csrf_token(page) do
    case Regex.run(~r/name="_csrf_token" value="([^"]+)"/, page.resp_body) do
      [_, token] -> token
      _ -> flunk("expected the page to render a CSRF-protected form")
    end
  end

  defp credential!(email) do
    {hash, scheme} = Samen.Auth.Hasher.hash(@password)
    {:ok, bidx} = Samen.Auth.BlindIndex.compute(email)

    Op.Credential
    |> Ash.Changeset.for_create(:create, %{}, authorize?: false)
    |> Ash.Changeset.force_change_attribute(:email_bidx, bidx)
    |> Ash.Changeset.force_change_attribute(:password_hash, hash)
    |> Ash.Changeset.force_change_attribute(:hash_scheme, scheme)
    |> Ash.Changeset.force_change_attribute(:verified_at, DateTime.utc_now())
    |> Ash.create!(authorize?: false)
  end

  defp ensure_operator_org!(operator_org_id) do
    case Ash.get(Op.Org, operator_org_id, authorize?: false) do
      {:ok, org} ->
        org

      _ ->
        Op.Org
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "PawChart Ops",
            plan: "operator",
            org_id: operator_org_id,
            slug: "pawchart-ops-test"
          },
          authorize?: false
        )
        |> Ash.Changeset.force_change_attribute(:id, operator_org_id)
        |> Ash.create!(authorize?: false)
    end
  end

  defp org!(name) do
    Op.Org
    |> Ash.Changeset.for_create(
      :create,
      %{name: name, plan: "free", slug: "org-#{System.unique_integer([:positive])}"},
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end

  # ADR-010 Bridge-B: an operator-side ACCOUNT row whose `slug` is the real tenant-org id —
  # the row `PawChart.Directory.orgs/0` projects into the workspace switcher.
  defp account_row!(operator_org_id, tenant_org, name) do
    Op.Org
    |> Ash.Changeset.for_create(
      :create,
      %{org_id: operator_org_id, name: name, plan: "free", slug: tenant_org.id},
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end

  defp user_with_membership!(org_id, credential, role) do
    user =
      Op.User
      |> Ash.Changeset.for_create(
        :create,
        %{org_id: org_id, handle: "member-#{System.unique_integer([:positive])}"},
        authorize?: false
      )
      # The spine force-writes `credential_id`; it is not on the create accept list.
      |> Ash.Changeset.force_change_attribute(:credential_id, credential.id)
      |> Ash.create!(authorize?: false)

    Op.Membership
    |> Ash.Changeset.for_create(
      :create,
      %{org_id: org_id, user_id: user.id, role: role},
      authorize?: false
    )
    |> Ash.create!(authorize?: false)

    user
  end

  defp company!(org_id, name) do
    PawChart.Crm.Company
    |> Ash.Changeset.for_create(:create, %{org_id: org_id, name: name}, authorize?: false)
    |> Ash.create!(authorize?: false)
  end
end
