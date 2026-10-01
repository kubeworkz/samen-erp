defmodule Samen.Web.Auth.ResendVerifyLive do
  @moduledoc """
  A2 — resend-verification request (ADR-035 §5 A2). Mounted at
  `GET /verify/resend` by `Samen.Web.Router.samen_auth_routes/1` — a STATIC
  path emitted BEFORE `/verify/:token`, so it never parses as a token that
  `ConfirmLive` would try to consume. **Pre-actor public** (ADR-035 §6): no org
  data rendered.

  Submitting the form calls `Samen.Identity.Confirm.resend/2`, which mints a
  fresh `:email_verify` token for an unverified credential and dispatches it
  through the Delivery chokepoint. The response is the SAME generic copy
  whether the address exists, is already verified, or does not exist at all
  (ADR-035 §5 A2 — no account-existence oracle, mirroring A1/A3).

  This surface exists because signup dispatches exactly ONCE: a pre-fix signup
  whose email failed to deliver (the 2026-10-01 JSON-blob `to` incident) left
  the account permanently unverified with no way to re-request the mail, and a
  re-registration of the same address takes the `:duplicate` branch without
  dispatching. `Confirm.resend/2` existed in core but had NO mounted surface
  until this page.

  ## No-JS HTTP fallback (T110)

  The form carries a REAL `action="/verify/resend"` + `method="post"` so a
  no-JS browser POSTs to `Samen.Web.Auth.AccountController.resend_verify/2`
  (the authoritative `:token_request_account` rate limit + `Confirm.resend/2`
  site). On the JS path, `phx-submit` arms `phx-trigger-action` to fire that
  SAME POST. The controller always redirects to `?sent=1` (the uniform,
  no-oracle outcome) or `?throttled=1`, read in `handle_params/3` — the email
  is never echoed into the URL.
  """
  use Phoenix.LiveView

  import Samen.UI

  alias Samen.Web.Mount

  @impl true
  def mount(_params, session, socket) do
    socket = Samen.Web.Live.assign_mount(socket, session)
    {:ok, load(socket)}
  end

  @doc false
  def load(socket) do
    assign(socket, form: blank_form(), flash_ok: nil, sent?: false, trigger_submit: false)
  end

  @impl true
  def handle_params(%{"sent" => "1"}, _uri, socket) do
    {:noreply,
     assign(socket,
       sent?: true,
       flash_ok: "If that address is awaiting verification, a new link is on its way — check your inbox."
     )}
  end

  def handle_params(%{"throttled" => "1"}, _uri, socket) do
    {:noreply,
     assign(socket,
       sent?: true,
       flash_ok: "Too many resend requests. Please wait a few minutes before trying again."
     )}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def handle_event("resend_verify", %{"resend_verify" => %{"email" => _email}} = params, socket) do
    # JS-connected path: arm the real POST. The authoritative rate-limit +
    # `Confirm.resend/2` (uniform no-oracle outcome) run in
    # `Samen.Web.Auth.AccountController.resend_verify/2`, which a no-JS submit
    # hits directly — this handler never mutates.
    {:noreply,
     assign(socket, form: to_form(params["resend_verify"] || %{}, as: :resend_verify), trigger_submit: true)}
  end

  defp resend_action(%Mount{} = mount), do: Mount.label(mount, :resend_path, "/verify/resend")

  defp blank_form, do: to_form(%{}, as: :resend_verify)

  # -- render ------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div id="auth-resend-verify" class="wrap" style="max-width:420px;margin:60px auto">
      <div class="card" style="padding:28px 24px">
        <h2 style="margin:0 0 4px">Resend verification email</h2>
        <p style="margin:0 0 18px;color:var(--muted)">
          Enter your account email — we'll send a fresh verification link.
        </p>

        <p :if={@flash_ok} id="resend-verify-ok" style="color:#15803D;margin:8px 0">{@flash_ok}</p>

        <.simple_form
          :if={not @sent?}
          for={@form}
          id="resend-verify-form"
          action={resend_action(@samen_mount)}
          method="post"
          phx-submit="resend_verify"
          phx-trigger-action={@trigger_submit}
        >
          <input type="hidden" name="_csrf_token" value={Phoenix.Controller.get_csrf_token()} />

          <.form_field field={@form[:email]} label="Email" type="email" required />

          <:actions>
            <.button type="submit" variant="primary" id="resend-verify-submit">Send verification email</.button>
          </:actions>
        </.simple_form>
      </div>
    </div>
    """
  end
end
