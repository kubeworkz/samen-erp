defmodule Samenerp.OperatorActAsErpAccountsTest do
  @moduledoc """
  Regression: an operator's "Open account" act-as must not cross into a tenant
  they do not belong to.

  The operator console advertises Kubeworkz as an account row, but the tenant's
  ERP ledger is tenant-org data. This drives the real browser pipeline (armed
  host, real `/login`, CSRF-protected `POST /session/org/:org_id`) and proves:

    * the session write to a non-member tenant org is refused;
    * a subsequent `/erp/coa` read never renders that tenant's account;
    * a membership-authorized switch to the operator's own org still works; and
    * an operator who really holds Kubeworkz membership (a spine `User` row in
      that org plus its `Membership`) CAN switch in and read its CoA — proving
      the gate allows an authorized target rather than only the operator org.
  """

  use Samenerp.DataCase, async: false

  import Phoenix.ConnTest
  import Plug.Conn, only: [get_session: 2]

  alias Samen.Web.CurrentOrg
  alias Samenerp.Erp.Account
  alias Samenerp.Operator, as: Op

  @endpoint SamenerpWeb.Endpoint
  @password "OperatorActAs!2026x9"

  setup do
    # ExUnit-owned endpoint lifecycle (same pattern as the host's other real-router tests).
    start_supervised!(SamenerpWeb.Endpoint)

    # The prod posture: without arming, OperatorAuthz's disarmed fallback grants every
    # principal an operator seat and this test could not tell an operator from a tenant.
    prev_armed = Application.get_env(:samenerp, :auth_required?)
    Application.put_env(:samenerp, :auth_required?, true)

    on_exit(fn ->
      case prev_armed do
        nil -> Application.delete_env(:samenerp, :auth_required?)
        value -> Application.put_env(:samenerp, :auth_required?, value)
      end
    end)

    unique = System.unique_integer([:positive])
    email = "operator-act-as-#{unique}@example.test"

    {:ok, %{org: operator_org, credential: credential}} =
      Samenerp.Seeds.ensure_admin!(email: email, password: @password)

    tenant_org =
      Op.Org
      |> Ash.Changeset.for_create(
        :create,
        %{name: "Kubeworkz #{unique}", plan: "free", slug: "kubeworkz-#{unique}"},
        authorize?: false
      )
      |> Ash.create!(authorize?: false)

    # ADR-010 Bridge-B: the operator console lists an operator-side ACCOUNT row whose
    # `slug` is the real tenant-org id. That row is what renders "Open account".
    Op.Org
    |> Ash.Changeset.for_create(
      :create,
      %{
        org_id: operator_org.id,
        name: "Kubeworkz #{unique}",
        plan: "free",
        slug: tenant_org.id
      },
      authorize?: false
    )
    |> Ash.create!(authorize?: false)

    operator_code = "OPX#{unique}"
    tenant_code = "KBX#{unique}"

    operator_account = account!(operator_org.id, operator_code, "Operator workspace account")
    tenant_account = account!(tenant_org.id, tenant_code, "Kubeworkz confidential account")

    {:ok,
     email: email,
     credential: credential,
     operator_org: operator_org,
     operator_account: operator_account,
     tenant_org: tenant_org,
     tenant_account: tenant_account}
  end

  test "an operator WITH Kubeworkz membership can switch into it and read its CoA", %{
    email: email,
    credential: credential,
    tenant_org: tenant_org,
    tenant_account: tenant_account
  } do
    grant_tenant_membership!(credential, tenant_org.id)

    conn = sign_in(email)
    assert redirected_to(conn) == "/operator/accounts"

    operator_page = operator_page(conn)
    assert operator_page.resp_body =~ "/session/org/#{tenant_org.id}"

    switched =
      operator_page
      |> recycle()
      |> post("/session/org/#{tenant_org.id}", %{
        "_csrf_token" => csrf_token(operator_page),
        "return_to" => "/erp/coa"
      })

    assert redirected_to(switched) == "/erp/coa"
    assert get_session(switched, CurrentOrg.session_key()) == tenant_org.id

    page = switched |> recycle() |> get("/erp/coa")
    assert page.status == 200
    assert page.resp_body =~ tenant_account.code
    assert page.resp_body =~ tenant_account.name
  end

  test "a non-member operator cannot switch into Kubeworkz or read its ERP accounts", %{
    email: email,
    tenant_org: tenant_org,
    tenant_account: tenant_account
  } do
    conn = sign_in(email)
    assert redirected_to(conn) == "/operator/accounts"

    # The operator console offers the "Open account" POST action for Kubeworkz; its
    # CSRF token is the one the browser form would submit.
    operator_page = operator_page(conn)
    assert operator_page.resp_body =~ "/session/org/#{tenant_org.id}"

    switched =
      operator_page
      |> recycle()
      |> post("/session/org/#{tenant_org.id}", %{
        "_csrf_token" => csrf_token(operator_page),
        "return_to" => "/erp/coa"
      })

    assert switched.status == 403
    assert switched.resp_body =~ "not a member of that workspace"
    refute get_session(switched, CurrentOrg.session_key()) == tenant_org.id

    page = switched |> recycle() |> get("/erp/coa")
    assert page.status == 200
    refute page.resp_body =~ tenant_account.code
    refute page.resp_body =~ tenant_account.name
  end

  test "a membership-authorized switch to the operator's own org still reads its accounts", %{
    email: email,
    operator_org: operator_org,
    operator_account: operator_account
  } do
    conn = sign_in(email)
    assert redirected_to(conn) == "/operator/accounts"

    own_switch =
      conn
      |> recycle()
      |> post("/session/org/#{operator_org.id}", %{
        "_csrf_token" => conn |> operator_page() |> csrf_token(),
        "return_to" => "/erp/coa"
      })

    assert redirected_to(own_switch) == "/erp/coa"
    assert get_session(own_switch, CurrentOrg.session_key()) == operator_org.id

    own_page = own_switch |> recycle() |> get("/erp/coa")
    assert own_page.status == 200
    assert own_page.resp_body =~ operator_account.code
  end

  # The operator really belongs to the tenant: a spine `User` row IN the tenant org (the
  # rows `CurrentOrg.authorized_orgs/2` enumerates for the credential) plus the tenant
  # `Membership` the armed read path resolves its role from (ADR-035 §5 A4 / ADR-045 §4.4).
  defp grant_tenant_membership!(credential, tenant_org_id) do
    # The spine keeps one `User` row PER ORG for the same credential (the Membership's
    # user_id must be a same-org row), and `OrgActor.authorized_org_ids/2` enumerates
    # exactly these rows to build the authorized set.
    tenant_user =
      Op.User
      |> Ash.Changeset.for_create(
        :create,
        %{org_id: tenant_org_id, handle: "Kubeworkz Operator"},
        authorize?: false
      )
      # `credential_id` is force-written by the spine's own path, exactly as seeds do.
      |> Ash.Changeset.force_change_attribute(:credential_id, credential.id)
      |> Ash.create!(authorize?: false)

    Op.Membership
    |> Ash.Changeset.for_create(
      :create,
      %{org_id: tenant_org_id, user_id: tenant_user.id, role: :admin},
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end

  defp sign_in(email) do
    login = build_conn() |> get("/login")
    assert login.status == 200

    csrf =
      Regex.run(~r/name="_csrf_token" value="([^"]+)"/, login.resp_body)
      |> case do
        [_, token] -> token
        _ -> flunk("the /login form must render a _csrf_token input")
      end

    login
    |> recycle()
    |> post("/login", %{
      "login" => %{"email" => email, "password" => @password},
      "_csrf_token" => csrf
    })
  end

  defp operator_page(conn) do
    page = conn |> recycle() |> get("/operator/accounts")
    assert page.status == 200
    page
  end

  defp csrf_token(page) do
    Regex.run(~r/name="_csrf_token" value="([^"]+)"/, page.resp_body)
    |> case do
      [_, token] -> token
      _ -> flunk("the operator console must render a CSRF-protected act-as form")
    end
  end

  defp account!(org_id, code, name) do
    Account
    |> Ash.Changeset.for_create(
      :create,
      %{
        org_id: org_id,
        code: code,
        name: name,
        kind: :asset,
        normal_side: :debit
      },
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end
end
