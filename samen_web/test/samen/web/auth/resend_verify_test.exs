defmodule Samen.Web.Auth.ResendVerifyTest do
  @moduledoc """
  A2 — the resend-verification SURFACE (the page + its entry links), against
  the samen_web test host's Operator Identity mount. The core `Confirm.resend/2`
  no-oracle contract + the `AccountController.resend_verify/2` controller floor
  are proven in `confirm_test.exs` / `account_controller_test.exs`; this file
  owns the LiveView itself:

    1. `Samen.Web.Auth.ResendVerifyLive` renders a REAL `method="post"` +
       `action="/verify/resend"` form (T110 — the binding no-JS floor), and a
       submit ARMS that POST (it never mutates itself).
    2. `?sent=1` / `?throttled=1` status flags render the uniform no-oracle
       copy / the throttle copy, and hide the form (ResetRequestLive posture).
    3. The entry points a STUCK user actually reaches: `ConfirmLive`'s error
       state and `RegistrationLive`'s `?registered=1` state both link to the
       resend surface (the 2026-10-01 incident left accounts unverified with
       NO mounted way to re-request the mail — this is the regression guard
       for that dead end).
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.Web.Auth.ConfirmLive
  alias Samen.Web.Auth.RegistrationLive
  alias Samen.Web.Auth.ResendVerifyLive

  # ===========================================================================
  # 1. ResendVerifyLive — form shape + armed POST (T110)
  # ===========================================================================

  describe "Samen.Web.Auth.ResendVerifyLive" do
    test "renders the request form with a REAL method=post action, and arms that POST on submit" do
      mount = build_mount(:auth)
      session = mount_session(mount)
      {:ok, socket} = ResendVerifyLive.mount(%{}, session, %Phoenix.LiveView.Socket{})

      html = render_html(ResendVerifyLive, socket.assigns)
      assert html =~ "resend-verify-form"
      assert html =~ ~s(method="post")
      assert html =~ ~s(action="/verify/resend")

      # JS path: submit arms the browser POST; the controller does the work.
      {:noreply, armed} =
        ResendVerifyLive.handle_event(
          "resend_verify",
          %{"resend_verify" => %{"email" => "resend-form@example.test"}},
          socket
        )

      assert armed.assigns.trigger_submit
    end

    test "?sent=1 shows the uniform no-oracle copy; ?throttled=1 the throttle copy; the form hides" do
      mount = build_mount(:auth)
      session = mount_session(mount)
      {:ok, socket} = ResendVerifyLive.mount(%{}, session, %Phoenix.LiveView.Socket{})

      {:noreply, sent} =
        ResendVerifyLive.handle_params(%{"sent" => "1"}, "http://localhost/verify/resend", socket)

      assert sent.assigns.sent?
      assert sent.assigns.flash_ok =~ "check your inbox"

      # The SAME surface renders the throttle copy from its own flag.
      {:noreply, throttled} =
        ResendVerifyLive.handle_params(%{"throttled" => "1"}, "http://localhost/verify/resend", socket)

      assert throttled.assigns.sent?
      assert throttled.assigns.flash_ok =~ "Too many resend requests"

      # Once sent (or throttled) the form is hidden — ResetRequestLive posture.
      html = render_html(ResendVerifyLive, sent.assigns)
      refute html =~ "resend-verify-form"
    end
  end

  # ===========================================================================
  # 2. Entry points — how a stuck user finds the surface
  # ===========================================================================

  describe "entry points to the resend surface" do
    test "ConfirmLive's error state links to /verify/resend" do
      mount = build_mount(:auth)
      session = mount_session(mount)
      {:ok, socket} = ConfirmLive.mount(%{"error" => "invalid_token"}, session, %Phoenix.LiveView.Socket{})

      html = render_html(ConfirmLive, socket.assigns)
      assert html =~ ~s(href="/verify/resend")
      assert html =~ "Resend verification email"
    end

    test "ConfirmLive's VERIFIED state does NOT render the resend link" do
      mount = build_mount(:auth)
      session = mount_session(mount)
      {:ok, socket} = ConfirmLive.mount(%{"verified" => "1"}, session, %Phoenix.LiveView.Socket{})

      html = render_html(ConfirmLive, socket.assigns)
      refute html =~ ~s(href="/verify/resend")
    end

    test "RegistrationLive's ?registered=1 state links to /verify/resend" do
      mount = build_mount(:auth)
      session = mount_session(mount)
      {:ok, socket} = RegistrationLive.mount(%{}, session, %Phoenix.LiveView.Socket{})

      {:noreply, done} =
        RegistrationLive.handle_params(%{"registered" => "1"}, "http://localhost/signup", socket)

      html = render_html(RegistrationLive, done.assigns)
      assert html =~ ~s(href="/verify/resend")
      assert html =~ "Resend verification email"
    end

    test "the FRESH signup form (pre-registration) does NOT render the resend link" do
      mount = build_mount(:auth)
      session = mount_session(mount)
      {:ok, socket} = RegistrationLive.mount(%{}, session, %Phoenix.LiveView.Socket{})

      html = render_html(RegistrationLive, socket.assigns)
      refute html =~ ~s(href="/verify/resend")
    end
  end
end
