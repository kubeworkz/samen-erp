defmodule Samenerp.AuthLoginRedirectTest do
  @moduledoc """
  PP-7 host proof — a login with NO `return_to` lands on the tenant workspace
  DASHBOARD (`labels: %{tenant_landing: "/crm/dashboard"}` wired on
  `samen_auth_routes` in this app's router), not the framework-neutral `/`,
  which on THIS host is the marketing homepage.

  The redirect is driven through the REAL router + `:browser` pipeline (CSRF
  included): a real credential minted by `Samenerp.Seeds.ensure_admin!/1`, a
  GET `/login` to obtain the form's CSRF token, then the native POST fallback
  `SessionController.create/2` runs with the router-built mount — the same
  mount the LiveView login form posts to in prod.

  The NAV-REACHABILITY companion below asserts the landing target is a mounted
  LIVE route (pawchart `:tenant_landing` posture): a redirect to a 404 would
  be a dead landing page.
  """
  use Samenerp.DataCase, async: false

  import Phoenix.ConnTest

  @endpoint SamenerpWeb.Endpoint
  @password "LoginLanding!2026x9"

  setup do
    # ExUnit-owned endpoint lifecycle (see DirectoryTest's setup): `start_supervised!`
    # runs the endpoint under THIS test's supervisor — alive for the whole test,
    # stopped after. A setup_all-owned `start_link` can die with the setup_all
    # process (order-dependent "ETS table missing" at dispatch in CI), and the app
    # supervisor starts no web children under test (`start_repo?: false`), so this
    # is the only stable owner.
    start_supervised!(SamenerpWeb.Endpoint)
    :ok
  end

  test "POST /login with no return_to redirects to /crm/dashboard" do
    email = "login-landing-#{System.unique_integer([:positive])}@example.test"
    Samenerp.Seeds.ensure_admin!(email: email, password: @password)

    login =
      build_conn()
      |> get("/login")

    assert login.status == 200

    csrf =
      Regex.run(~r/name="_csrf_token" value="([^"]+)"/, login.resp_body)
      |> case do
        [_, token] -> token
        _ -> flunk("the /login form must render a _csrf_token input")
      end

    conn =
      login
      |> recycle()
      |> post("/login", %{
        "login" => %{"email" => email, "password" => @password},
        "_csrf_token" => csrf
      })

    assert redirected_to(conn) == "/crm/dashboard"
  end

  test "the tenant_landing target /crm/dashboard is a mounted live route (not a 404)" do
    paths =
      SamenerpWeb.Router
      |> Phoenix.Router.routes()
      |> Enum.map(& &1.path)

    assert "/crm/dashboard" in paths
  end
end
