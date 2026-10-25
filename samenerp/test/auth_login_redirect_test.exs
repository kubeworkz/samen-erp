defmodule Samenerp.AuthLoginRedirectTest do
  @moduledoc """
  PP-7 / P18 host proof — WHERE A SIGN-IN LANDS on this host.

  PP-7 established that a tenant sign-in with NO `return_to` lands on the tenant workspace
  DASHBOARD (`labels: %{tenant_landing: "/crm/dashboard"}` wired on `samen_auth_routes` in this
  app's router), not the framework-neutral `/`, which on THIS host is the marketing homepage.

  P18 SPLITS that landing by who signed in, through the same `:operator_authority` seam the tenant
  chrome already offers the console link from (`Samenerp.OperatorAuthz` credential→User→
  operator-org Membership):

    * an OPERATOR (the seeded owner) whose session resolves an operator seat lands on the
      operator console — the surface their job starts on, every tenant account with its plan and
      MRR; and
    * a NON-operator (a credential with no operator-org membership) keeps the PP-7 landing
      exactly as it was, on `/crm/dashboard`.

  ## Why these tests ARM the host

  `Samenerp.OperatorAuthz` grants `:operator_admin` to everyone while the tenant gate is
  DISARMED (the documented dev/test fallback), so a disarmed run cannot tell an operator from a
  tenant — every login would "prove" the operator landing. Each test therefore sets
  `config :samenerp, auth_required?: true` for its own duration (restored on exit), which is the
  prod posture and the only posture in which the seat is a real roster decision.

  The redirect is driven through the REAL router + `:browser` pipeline (CSRF included): a real
  credential, a GET `/login` to obtain the form's CSRF token, then the native POST fallback
  `SessionController.create/2` runs with the router-built mount — the same mount the LiveView
  login form posts to in prod.

  The NAV-REACHABILITY companions assert both landing targets are mounted LIVE routes: a
  redirect to a 404 would be a dead landing page.
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

    # The prod posture — see the moduledoc. Without it `Samenerp.OperatorAuthz` answers
    # `:operator_admin` for every principal (its disarmed dev fallback) and no test here could
    # tell an operator from a tenant.
    prev_armed = Application.get_env(:samenerp, :auth_required?)
    Application.put_env(:samenerp, :auth_required?, true)

    on_exit(fn ->
      case prev_armed do
        nil -> Application.delete_env(:samenerp, :auth_required?)
        value -> Application.put_env(:samenerp, :auth_required?, value)
      end
    end)

    :ok
  end

  defp unique_email(tag), do: "#{tag}-#{System.unique_integer([:positive])}@example.test"

  # A real credential belonging to NO operator-org membership — i.e. a tenant account signing
  # in. Built the way `Samenerp.Seeds` builds one (the blind index is private on the resource,
  # so the attributes are forced), but with no membership, which is the only fact
  # `Samenerp.OperatorAuthz` reads.
  defp tenant_credential!(email) do
    {hash, scheme} = Samen.Auth.Hasher.hash(@password)
    {:ok, bidx} = Samen.Auth.BlindIndex.compute(email)

    Samenerp.Operator.Credential
    |> Ash.Changeset.for_create(:create, %{}, authorize?: false)
    |> Ash.Changeset.force_change_attribute(:email_bidx, bidx)
    |> Ash.Changeset.force_change_attribute(:password_hash, hash)
    |> Ash.Changeset.force_change_attribute(:hash_scheme, scheme)
    |> Ash.Changeset.force_change_attribute(:verified_at, DateTime.utc_now())
    |> Ash.create!()
  end

  # GET /login for the form's CSRF token, then POST the same credential through the router.
  defp sign_in(email, params \\ %{}) do
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
    |> post(
      "/login",
      Map.merge(
        %{"login" => %{"email" => email, "password" => @password}, "_csrf_token" => csrf},
        params
      )
    )
  end

  defp route_paths do
    SamenerpWeb.Router
    |> Phoenix.Router.routes()
    |> Enum.map(& &1.path)
  end

  # ==========================================================================
  # P18 — the operator lands on the console
  # ==========================================================================

  test "POST /login as an operator with no return_to lands on the operator console" do
    email = unique_email("operator-landing")
    Samenerp.Seeds.ensure_admin!(email: email, password: @password)

    conn = sign_in(email)

    assert redirected_to(conn) == "/operator/accounts"
  end

  test "an explicit return_to still wins for an operator (a deep link is the user's instruction)" do
    email = unique_email("operator-deep-link")
    Samenerp.Seeds.ensure_admin!(email: email, password: @password)

    conn = sign_in(email, %{"return_to" => "/notes"})

    assert redirected_to(conn) == "/notes"
  end

  # ==========================================================================
  # Dev posture — a disarmed host keeps the TENANT landing, operator or not
  # ==========================================================================

  test "POST /login on a DISARMED host lands on /crm/dashboard even for the operator" do
    # `auth_required?` off is exactly when `Samenerp.OperatorAuthz` answers `:operator_admin` for
    # EVERY principal (its dev fallback, so the dogfood console needs no roster). That seat is
    # `:dev_only` — it may OFFER the console in the chrome, it may never PLACE a sign-in — so a
    # developer's tenant account still gets its tenant dashboard instead of the console.
    Application.put_env(:samenerp, :auth_required?, false)

    email = unique_email("disarmed-operator")
    Samenerp.Seeds.ensure_admin!(email: email, password: @password)

    assert redirected_to(sign_in(email)) == "/crm/dashboard"
  end

  # ==========================================================================
  # PP-7 retained — a TENANT sign-in is exactly where it was
  # ==========================================================================

  test "POST /login as a non-operator with no return_to still lands on /crm/dashboard" do
    email = unique_email("tenant-landing")
    tenant_credential!(email)

    conn = sign_in(email)

    assert redirected_to(conn) == "/crm/dashboard"
  end

  # ==========================================================================
  # NAV REACHABILITY — neither landing target may be a 404
  # ==========================================================================

  test "both landing targets are mounted live routes (not 404s)" do
    paths = route_paths()

    assert "/crm/dashboard" in paths
    assert "/operator/accounts" in paths
  end
end
