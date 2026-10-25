defmodule Samen.Web.LoginLandingTest do
  @moduledoc """
  P18 — WHERE A SIGN-IN LANDS, and where it does NOT.

  The tenant chrome already OFFERS the operator console to an operator
  (`Samen.Web.CurrentOrg.operator_console_entry/1`, gated on `operator_seat/1`). That is a link
  an operator has to go find. A sign-in is the moment the SaaS already knows who just arrived
  and where they belong, so `SessionController.finish_login/5` sends them there directly:

    1. **GREEN — an operator with no `return_to` lands on the console.** Same seam the chrome
       gates the link on (`Samen.Web.Operator.Authz.seat_role/2`), same target
       (`CurrentOrg.operator_console_path/0`), so the landing and the link can never disagree.
    2. **CONTROL — a plain tenant is untouched.** The seam says "not an operator" and the
       sign-in lands on the mount's `:tenant_landing`, byte-for-byte the pre-P18 destination.
       A test that moved EVERYONE would prove nothing about operators.
    3. **The seat answers about the person who just signed in.** The resolver here is keyed on a
       per-test roster of PRINCIPAL IDs, so `GREEN` proves the credential this login minted was
       the thing resolved — not a param, not a stale cookie, not "some session exists".
    4. **An explicit `return_to` always wins** (an operator deep link is still the user's own
       instruction), and the **open-redirect refusal still runs FIRST** — a foreign/`//` path is
       dropped and the seat landing takes over, never the attacker's host.
    5. **A DEV-ONLY seat never PLACES anyone.** On a DISARMED host the usual resolver answers
       "operator" for every principal, so the seat is `Authz.seat_provenance/1`'s `:dev_only`:
       the chrome still OFFERS the console (display), the landing does NOT move — a developer's
       tenant account keeps its tenant dashboard, exactly as before P18.

  The suite therefore ARMS its host (`config :samen_web, auth_required?: true`, restored on exit)
  for every test that expects the operator landing, and DISARMS it in the twin that expects the
  tenant landing. Without arming, `:samen_web`'s test posture is the disarmed one and the green
  path below could not tell a roster decision from the blanket dev grant.

  Fixture: the real `Samen.Web.Auth.SessionController.create/2` over the test host's Operator
  Identity mount (the `session_test.exs` machinery), so the assertion is on a REAL login's
  redirect header, not on a unit helper.
  """
  use Samen.WebTest.DataCase, async: false

  import Plug.Conn
  import Plug.Test

  require Phoenix.LiveViewTest

  alias Samen.Identity.Register
  alias Samen.Web.Auth
  alias Samen.Web.Auth.SessionController
  alias Samen.Web.CurrentOrg
  alias Samen.Web.Mount
  alias Samen.WebTest.Operator.AuthToken
  alias Samen.WebTest.Operator.Credential
  alias Samen.WebTest.Operator.Membership
  alias Samen.WebTest.Operator.Org
  alias Samen.WebTest.Operator.User

  @tenant_landing "/dashboard"
  @secret_key_base String.duplicate("a", 64)

  # --- the host `:operator_authority` seams these tests wire ----------------------------------
  #
  # `fixed/2`: the seam answers the SAME thing for everyone (an operator host, or one where
  # nobody is an operator). `roster/2`: the seam answers per PRINCIPAL ID, from the roster this
  # test put in the process dictionary — which is how the green path proves the id it resolved
  # belongs to the person who just signed in and nobody else.
  #
  # The id a seat resolver sees is the session PRINCIPAL: `Samen.Web.Auth.authenticated_user_id/1`
  # — i.e. the identity User the login bridged for a credential that owns one (`finish_login/5`'s
  # legacy bridge), else the credential itself. These tests register a full account, so the
  # bridged User is the principal.

  def fixed(role, _principal_id), do: role

  def roster(:roster, principal_id) do
    if principal_id in (Process.get(:operator_roster) || []), do: :operator_admin, else: nil
  end

  setup do
    prev = Application.get_env(:samen_core, :delivery_env)
    Application.put_env(:samen_core, :delivery_env, :test)

    # The PROD posture for the seat: `Samen.WebTest.Repo`'s `otp_app` is `:samen_web`, so this is
    # the app whose arming posture `Authz.seat_provenance/1` reads for every mount built here.
    # A test that wants the DISARMED posture deletes the key for itself (the twin below).
    prev_armed = Application.get_env(:samen_web, :auth_required?)
    Application.put_env(:samen_web, :auth_required?, true)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:samen_core, :delivery_env, prev),
        else: Application.delete_env(:samen_core, :delivery_env)

      case prev_armed do
        nil -> Application.delete_env(:samen_web, :auth_required?)
        value -> Application.put_env(:samen_web, :auth_required?, value)
      end
    end)

    :ok
  end

  defp register_mods,
    do: %{org: Org, credential: Credential, user: User, membership: Membership, auth_token: AuthToken, repo: Repo}

  defp register! do
    attrs = %{
      org_name: "Landing Co #{System.unique_integer([:positive])}",
      first_name: "Ada",
      last_name: "Lovelace",
      email: "login-landing-#{System.unique_integer([:positive])}@example.test",
      password: "correct horse battery staple"
    }

    {:ok, result} = Register.register(attrs, register_mods())
    result |> Map.put(:email, attrs.email) |> Map.put(:password, attrs.password)
  end

  # A TENANT mount: the host label set a framework tenant module mount carries (no
  # `:operator_authority` — that is what `samen_operator_routes/2` adds), plus the seam under
  # test and the host's own tenant landing.
  defp mount(seam) do
    Mount.new(:crm, Samen.WebTest.Operator, Repo,
      labels: %{tenant_landing: @tenant_landing, operator_authority: seam}
    )
  end

  # A minimal conn with the session plug installed, as the host :browser pipeline provides —
  # the SAME harness `session_test.exs` / `session_controller_test.exs` use.
  defp session_conn(method, path) do
    opts = Plug.Session.init(store: :cookie, key: "_test", signing_salt: "salt", encryption_salt: "esalt")

    conn(method, path)
    |> Map.put(:secret_key_base, @secret_key_base)
    |> Plug.Session.call(opts)
    |> fetch_session()
  end

  defp auth_conn(mnt) do
    session_conn(:post, "/login")
    |> put_private(:samen_mount, mnt)
    |> put_private(:samen_login_path, "/login")
  end

  defp login!(mnt, result, params \\ %{}) do
    SessionController.create(
      auth_conn(mnt),
      Map.merge(%{"login" => %{"email" => result.email, "password" => result.password}}, params)
    )
  end

  defp location(conn), do: conn |> get_resp_header("location") |> List.first()

  # ==========================================================================
  # 1. GREEN — an operator with nothing to return to starts on the console
  # ==========================================================================

  test "GREEN: an operator login with no return_to lands on the operator console" do
    result = register!()
    mnt = mount({__MODULE__, :fixed, [:operator_admin]})

    conn = login!(mnt, result)

    assert conn.status in 300..399
    assert location(conn) == "/operator/accounts"
    assert location(conn) == CurrentOrg.operator_console_path()
    refute location(conn) == @tenant_landing

    # The login itself is still a real login (the landing change alters nothing about the session).
    assert is_binary(get_session(conn, Auth.session_token_key()))
  end

  test "GREEN: the seat is resolved from the principal THIS login minted" do
    result = register!()
    mnt = mount({__MODULE__, :roster, [:roster]})

    # The roster names the account that is about to sign in …
    Process.put(:operator_roster, [result.user.id])
    on_exit(fn -> Process.delete(:operator_roster) end)

    assert location(login!(mnt, result)) == "/operator/accounts"

    # … and the SAME resolver, with the roster naming somebody else, sends this signer to the
    # tenant landing. One variable changed: whose id the seam saw.
    other = register!()
    Process.put(:operator_roster, [other.user.id])

    assert location(login!(mnt, result)) == @tenant_landing
  end

  # ==========================================================================
  # 2. CONTROL — a plain tenant sign-in is exactly where it was before P18
  # ==========================================================================

  test "CONTROL: a non-operator login still lands on the mount's :tenant_landing" do
    result = register!()
    mnt = mount({__MODULE__, :fixed, [:tenant]})

    assert location(login!(mnt, result)) == @tenant_landing
  end

  test "CONTROL: a host with NO :operator_authority seam keeps the tenant landing" do
    result = register!()
    mnt = Mount.new(:crm, Samen.WebTest.Operator, Repo, labels: %{tenant_landing: @tenant_landing})

    assert location(login!(mnt, result)) == @tenant_landing
  end

  test "CONTROL: a seam that RAISES never fails the login — the tenant landing applies" do
    result = register!()
    mnt = mount({__MODULE__, :boom, []})

    conn = login!(mnt, result)

    assert conn.status in 300..399
    assert location(conn) == @tenant_landing
    assert is_binary(get_session(conn, Auth.session_token_key()))
  end

  def boom, do: raise("seam exploded")

  # ==========================================================================
  # 3. return_to wins, and the open-redirect refusal still runs first
  # ==========================================================================

  test "an explicit return_to wins over the operator landing" do
    result = register!()
    mnt = mount({__MODULE__, :fixed, [:operator_admin]})

    conn = login!(mnt, result, %{"return_to" => "/notes/page-1"})

    assert location(conn) == "/notes/page-1"
  end

  test "RED: a protocol-relative return_to is dropped, then the operator landing applies" do
    result = register!()
    mnt = mount({__MODULE__, :fixed, [:operator_admin]})

    conn = login!(mnt, result, %{"return_to" => "//evil.example/steal"})

    assert location(conn) == "/operator/accounts"
    refute location(conn) =~ "evil.example"
  end

  # ==========================================================================
  # 3b. DEV-ONLY seat — a disarmed host never PLACES a sign-in on the console
  # ==========================================================================

  test "RED: a DISARMED host keeps the tenant landing even for a seated principal" do
    result = register!()
    mnt = mount({__MODULE__, :fixed, [:operator_admin]})

    # The dev posture: `auth_required?` off, which is when a host's resolver is free to answer
    # "operator" for everybody (samenerp's does, by design). The seat is then `:dev_only`.
    Application.delete_env(:samen_web, :auth_required?)

    assert location(login!(mnt, result)) == @tenant_landing

    # ARMING the same host, same credential, same seam is the one variable that moves it — so
    # the assertion above is about the POSTURE, not about the login failing to resolve a seat.
    Application.put_env(:samen_web, :auth_required?, true)

    assert location(login!(mnt, result)) == "/operator/accounts"
  end

  test "RED: an absolute foreign return_to is dropped — a tenant keeps the tenant landing" do
    result = register!()
    mnt = mount({__MODULE__, :fixed, [:tenant]})

    conn = login!(mnt, result, %{"return_to" => "https://evil.example/x"})

    assert location(conn) == @tenant_landing
    refute location(conn) =~ "evil.example"
  end

  # ==========================================================================
  # 4. One path, two surfaces — the chrome's link and the landing cannot disagree
  # ==========================================================================

  test "the console ENTRY and the login landing name the same path" do
    mnt = mount({__MODULE__, :fixed, [:operator_admin]})

    html =
      Phoenix.LiveViewTest.render_component(&CurrentOrg.operator_console_entry/1, %{
        mount: mnt,
        operator_label: nil
      })

    assert html =~ ~s(href="/operator/accounts")
    assert CurrentOrg.operator_console_path() == "/operator/accounts"
  end
end
