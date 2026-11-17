defmodule DriftwoodWeb.SessionOrgMembershipGateTest do
  @moduledoc """
  End-to-end regression for driftwood's SESSION-write membership gate
  (`POST /session/org/:org_id` — the workspace switcher / operator "Open account").

  Drives the real armed browser pipeline: real `/login`, the CSRF-protected switch, and the
  tenant CRM read (`/crm/companies`). Proves:

    * a principal switching to a tenant they do NOT belong to is refused with 403, the session
      is never written, and that tenant's CRM data never renders; and
    * a principal with a real `Driftwood.Operator` User + Membership in a target tenant CAN
      switch there (302 + session write) and read its CRM data.

  The target and foreign orgs are advertised to the switcher through operator-side Bridge-B
  `Driftwood.Operator.Org` account rows whose `slug` is the tenant-org id
  (`Driftwood.Directory`), exactly as the operator console lists accounts.
  """
  use Driftwood.DataCase, async: false

  import Phoenix.ConnTest
  import Plug.Conn, only: [get_session: 2]

  alias Driftwood.Operator, as: Op
  alias Samen.Web.CurrentOrg

  @endpoint DriftwoodWeb.Endpoint
  @password "OperatorActAs!2026x9"

  setup do
    start_supervised!(DriftwoodWeb.Endpoint)

    # The prod posture: without arming, `CurrentOrg` trusts the ?org=/session convenience and
    # the switch endpoint could not tell an authorized tenant from a forged one.
    prev_armed = Application.get_env(:driftwood, :auth_required?)
    Application.put_env(:driftwood, :auth_required?, true)

    on_exit(fn ->
      case prev_armed do
        nil -> Application.delete_env(:driftwood, :auth_required?)
        value -> Application.put_env(:driftwood, :auth_required?, value)
      end
    end)

    operator_org_id = Application.fetch_env!(:driftwood, :operator_org_id)
    ensure_operator_org!(operator_org_id)

    unique = System.unique_integer([:positive])
    email = "session-gate-#{unique}@example.test"
    credential = credential!(email)

    home_org = org!("Home Brokerage #{unique}")
    user_with_membership!(home_org.id, credential, :owner)
    company!(home_org.id, "HOME#{unique} Home carrier")

    tenant_org = org!("Kubeworkz #{unique}")
    account_row!(operator_org_id, tenant_org, "Kubeworkz #{unique}")
    tenant_company = company!(tenant_org.id, "KBX#{unique} Confidential carrier")

    foreign_org = org!("Foreign Brokerage #{unique}")
    account_row!(operator_org_id, foreign_org, "Foreign #{unique}")
    foreign_company = company!(foreign_org.id, "FRN#{unique} Foreign carrier")

    {:ok,
     email: email,
     credential: credential,
     home_org: home_org,
     tenant_org: tenant_org,
     tenant_company: tenant_company,
     foreign_org: foreign_org,
     foreign_company: foreign_company}
  end

  test "a non-member principal cannot switch into a tenant or read its CRM data", %{
    email: email,
    foreign_org: foreign_org,
    foreign_company: foreign_company
  } do
    conn = sign_in(email)
    assert conn.status == 302

    page = conn |> recycle() |> get("/crm/companies")
    assert page.status == 200
    # The switcher really offers the foreign tenant, so the refusal below is not vacuous.
    assert page.resp_body =~ "/session/org/#{foreign_org.id}"

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
    credential: credential,
    tenant_org: tenant_org,
    tenant_company: tenant_company
  } do
    # A real second-org membership: a same-credential User row IN the tenant (the rows
    # `CurrentOrg.authorized_orgs/2` enumerates) plus its Membership (the read-path role).
    user_with_membership!(tenant_org.id, credential, :admin)

    conn = sign_in(email)
    assert conn.status == 302

    page = conn |> recycle() |> get("/crm/companies")
    assert page.status == 200
    assert page.resp_body =~ "/session/org/#{tenant_org.id}"

    switched =
      page
      |> recycle()
      |> post("/session/org/#{tenant_org.id}", %{
        "_csrf_token" => csrf_token(page),
        "return_to" => "/crm/companies"
      })

    assert redirected_to(switched) == "/crm/companies"
    assert get_session(switched, CurrentOrg.session_key()) == tenant_org.id

    tenant_page = switched |> recycle() |> get("/crm/companies")
    assert tenant_page.status == 200
    assert tenant_page.resp_body =~ tenant_company.name
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
            name: "Driftwood Ops",
            plan: "operator",
            org_id: operator_org_id,
            slug: "driftwood-ops-test"
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
  # the row `Driftwood.Directory.orgs/0` projects into the workspace switcher.
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
    Driftwood.Crm.Company
    |> Ash.Changeset.for_create(:create, %{org_id: org_id, name: name}, authorize?: false)
    |> Ash.create!(authorize?: false)
  end
end
