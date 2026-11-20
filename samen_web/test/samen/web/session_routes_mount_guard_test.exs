defmodule Samen.Web.SessionRoutesMountGuardTest do
  @moduledoc """
  The compile-time `:mount` requirement of `samen_session_routes/1`.

  The session current-org write is the ONE persisted org selection — the workspace switcher AND
  the operator "Open account →" clear act-as. Without a mount the controller cannot derive the
  authenticated principal's authorized orgs, so an ARMED host would trust a client-supplied org
  id on exactly the path that makes it stick. That is the hole this guard closes.

  Proven through the REAL macro on throwaway routers: a bare call warns (deprecated) and does
  not compile; `mount: nil` and a non-mount value do not compile; a DISARMED mount compiles and
  declares both session routes — the dev/test posture byte-for-byte.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Samen.Web.CurrentOrg
  alias Samen.Web.Mount

  # A DISARMED mount. The explicit fictional `:otp_app` label makes armed-ness independent of
  # `:samen_web`'s own test env (another suite flips that), so the gate is OFF by construction.
  @mount_src "Samen.Web.Mount.new(:auth, Samen.WebTest.Operator, Samen.WebTest.Repo, " <>
               "labels: %{otp_app: :samen_web_session_probe_host})"

  defp compile_router(session_call) do
    module = "SessionMountProbe#{System.unique_integer([:positive])}"

    Code.compile_string("""
    defmodule #{module} do
      use Phoenix.Router
      import Samen.Web.Router

      scope "/" do
        #{session_call}
      end
    end
    """)

    Module.concat([module])
  end

  # A refusal raised during macro expansion surfaces as the raised ArgumentError (the compiler
  # re-raises it at the call site); a CompileError wrapper is accepted too. Assert on the
  # formatted error so the diagnostic is what is pinned, not the exception struct.
  defp refusal(session_call) do
    try do
      compile_router(session_call)
      flunk("expected `#{session_call}` to be refused at compile time")
    rescue
      e in [ArgumentError, CompileError] ->
        Exception.format(:error, e, __STACKTRACE__)
    end
  end

  test "RED — a bare samen_session_routes() warns (deprecated) and does not compile" do
    warning =
      capture_io(:stderr, fn ->
        send(self(), {:refusal, refusal("samen_session_routes()")})
      end)

    assert_received {:refusal, formatted}
    assert formatted =~ "samen_session_routes/1 requires `mount:`"
    assert formatted =~ "no `:mount` was given"
    assert formatted =~ "docs/adr/ADR-013-demo-coherence.md"
    # The deprecation signal, so an adopter upgrading the framework learns the fix by name.
    assert warning =~ "deprecated"
  end

  test "RED — `mount: nil` is refused (and is not treated as the deprecated legacy shape)" do
    formatted = refusal("samen_session_routes(mount: nil)")

    assert formatted =~ "samen_session_routes/1 requires `mount:`"
    assert formatted =~ "`:mount` was given as nil"
  end

  test "RED — a non-Mount value is refused" do
    formatted = refusal("samen_session_routes(mount: :identity)")

    assert formatted =~ "samen_session_routes/1 requires `mount:`"
    assert formatted =~ "`:mount` was given as :identity"
    assert formatted =~ "%Samen.Web.Mount{}"
  end

  test "GREEN — a disarmed mount compiles and declares both session routes" do
    router = compile_router("samen_session_routes(mount: #{@mount_src})")

    assert %{plug: Samen.Web.SessionController, plug_opts: :put_current_org} =
             Phoenix.Router.route_info(router, "POST", "/session/org/abc", "localhost")

    assert %{plug: Samen.Web.SessionController, plug_opts: :stale_get} =
             Phoenix.Router.route_info(router, "GET", "/session/org/abc", "localhost")

    # The posture under test is the documented dev/test one: the mount is DISARMED, so the write
    # is the `?org=` convenience the session controller has always had.
    mount =
      Mount.new(:auth, Samen.WebTest.Operator, Samen.WebTest.Repo,
        labels: %{otp_app: :samen_web_session_probe_host}
      )

    refute CurrentOrg.tenant_gate_armed?(mount)
  end
end
