defmodule Samen.Web.Replay do
  @moduledoc """
  The TENANT-PLANE **session-replay recorder** — the ONE call site that writes a
  `nav.visited` step into the analytics ledger, attached to the tenant mount hook every
  framework tenant route already carries.

  ## Why the hook and not the page

  `Samen.Web.TenantAuthz.on_mount(:require_tenant, …)` is on EVERY tenant `live_session` the
  framework macros emit (and on the ones hosts write by hand), so recording there inherits the
  adoption the authz gate already has: a new tenant page is recorded the day it is routed,
  with **no per-page call, no per-page opt-in, and nothing to forget**. Inverting it — a
  `Samen.Replay.record/1` each page must call — is precisely the drift the tenant-shell
  wrapper (`Samen.Web.Tenant.Live`) exists to remove for chrome.

  ## Recorded ONCE per visit

  A LiveView mount happens twice: the HTTP **dead render** and the (optional)
  **connected** mount over the websocket. Recording in both would double every visit, so the
  recorder fires only on the connected mount (`Phoenix.LiveView.connected?/1`). A tenant with
  no JS client (ADR-042 Class B) therefore records nothing at all — honest: there is no
  client session to replay, and the dead render is the only mount that happened.

  ## What is captured

  Exactly what `Samen.Analytics.Replay` accepts — the LiveView module (normalized to a bounded
  surface token), the tenant org, and the authenticated principal (pseudonymized to
  `actor_ref` by the ledger). No URL, no params, no form values, no PII. See that module's
  moduledoc for the full refusal surface.

  ## Best-effort by construction

  `record_visit/2` returns the socket unchanged and swallows nothing: an unwired ledger
  (`{:ok, :dropped}`), a missing org, a declined pseudonym, or a failing write all leave the
  mount untouched. A page view never fails because its replay step could not be written —
  the same posture as `Samen.Notifications.Engine.emit/2`.
  """

  alias Samen.Analytics.Replay, as: Capture

  @doc """
  Record this mount as a replay step (when there is one to record) and return the socket
  unchanged. `org_id` may be passed explicitly when the caller has already resolved it (the
  disarmed dev leg), otherwise the pinned `:samen_tenant_org_id` assign is used.
  """
  @spec record_visit(Phoenix.LiveView.Socket.t(), String.t() | nil) :: Phoenix.LiveView.Socket.t()
  def record_visit(socket, org_id \\ nil)

  def record_visit(%Phoenix.LiveView.Socket{} = socket, org_id) do
    with true <- Phoenix.LiveView.connected?(socket),
         org_id when is_binary(org_id) <- org_id || socket.assigns[:samen_tenant_org_id],
         view when is_atom(view) and not is_nil(view) <- socket.view do
      _ =
        Capture.record_visit(
          org_id: org_id,
          subject_id: socket.assigns[:samen_tenant_principal],
          surface: view
        )
    end

    socket
  end

  def record_visit(socket, _org_id), do: socket
end
