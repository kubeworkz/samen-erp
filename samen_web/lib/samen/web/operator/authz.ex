defmodule Samen.Web.Operator.Authz do
  @moduledoc """
  The OPERATOR-plane ROLE authorization gate (T146 / ADR-010 §7.2 hardening).

  ## The hole this closes (dogfood W3-E1, CONFIRMED LIVE)

  Before T146 the operator control plane AUTHENTICATED only — it never checked that the
  authenticated principal actually held OPERATOR authority. `samen_operator_routes/2` emitted a
  bare `live_session` with no `on_mount` hook; `Samen.Web.AuthGate` checked only
  `Samen.Web.Auth.authenticated_user_id/1`; and `Samen.Web.Operator.scope/1` fabricates the actor
  from the MOUNT (the well-known operator org id), NEVER from the session principal. Operator and
  tenant share ONE authn realm, so a plain authenticated TENANT user hitting `/operator/accounts`
  in a correctly-configured prod host got a `200` rendering every OTHER tenant's admin email + org
  + MRR in the clear. The framework carried an `operator_role` primitive
  (`Samen.OperatorPlane.Actor`, used by `Samen.BreakGlass` / `Samen.Automation.Health`) but it was
  never wired to the operator routes — the mount's `:operator_role` was only a display label.

  This module is the missing authorization layer. It derives operator authority from the
  AUTHENTICATED PRINCIPAL (never from the mount) and FAILS CLOSED for anyone who is not an
  operator. It is an `on_mount` hook every operator route carries (attached by
  `samen_operator_routes/2`), so a tenant-user session cannot reach ANY `/operator/*` surface.

  ## The host seam — how a host declares operator authority (fail-CLOSED by default)

  Auth is HOST-OWNED (ADR-029): the framework cannot know which principal is an operator. A host
  declares it through the mount's `:operator_authority` label — an `{mod, fun, args}` MFA
  (the SAME shape `Samen.Web.CurrentOrg` uses for `:authorized_orgs`), called with the
  authenticated principal id APPENDED, returning one of `Samen.OperatorPlane.Actor.roles/0`
  (`:operator_admin | :operator_support | :operator_readonly | :operator_break_glass`) or `nil`.

    * a valid operator role → the principal is an operator → `:cont` (the operator plane renders);
    * `nil`, an unknown/invalid return, an ERRORING resolver, or NO `:operator_authority` seam at
      all → the principal is NOT an operator → `:halt` + redirect to `/login`.

  A host that wires NOTHING gets NO operator access (deny-by-default), never open access. The
  authority is ALWAYS derived from the authenticated principal — this module NEVER fabricates the
  operator identity from the mount.

  ## Dev posture — operator-ROLE authz is NOT bypassed by `auth_required?: false`

  Unlike `Samen.Web.CurrentOrg`/`Samen.Web.AuthGate` (whose AUTHENTICATION relaxes in dev), this
  ROLE gate ALWAYS applies: `resolve_role/2` denies unless the host seam returns an operator role,
  in EVERY environment. Dev CONVENIENCE is opt-in and unmistakably dev-only via `dev_operator_role/2`
  — a NAMED resolver a host/generated router may wire as its `:operator_authority` seam. It grants
  `:operator_admin` ONLY while `auth_required?` is false for the app (dev/test), and `nil`
  (fail-closed) the instant the app is armed for prod. So the exploit is never trivially open in a
  way that could ship: a prod-armed app with a dev seam still refuses every non-operator.
  """
  use Phoenix.Component

  alias Samen.OperatorPlane.Actor
  alias Samen.Web.{Auth, Mount}

  @roles Actor.roles()
  @default_login_path "/login"

  @doc """
  The `on_mount {Samen.Web.Operator.Authz, :require_operator}` hook `samen_operator_routes/2`
  attaches to the operator `live_session`. Resolves operator authority from the authenticated
  session principal (via the host `:operator_authority` seam) and:

    * `{:cont, socket}` with `:samen_operator_role` assigned — the principal is an operator;
    * `{:halt, redirect}` to the login path — anyone who is NOT an operator (fail CLOSED,
      renders NOTHING).
  """
  @spec on_mount(atom(), map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:cont, Phoenix.LiveView.Socket.t()} | {:halt, Phoenix.LiveView.Socket.t()}
  def on_mount(:require_operator, _params, session, socket) when is_map(session) do
    mount = Mount.from_session(session["samen_mount"] || %{})

    case resolve_role(mount, session) do
      role when role in @roles ->
        {:cont, assign(socket, :samen_operator_role, role)}

      _ ->
        {:halt, Phoenix.LiveView.redirect(socket, to: login_path(mount))}
    end
  end

  def on_mount(:require_operator, _params, _session, socket) do
    {:halt, Phoenix.LiveView.redirect(socket, to: @default_login_path)}
  end

  @doc """
  The operator role the AUTHENTICATED principal holds on this `mount`, or `nil` (NOT an operator).

  Derives the principal id from the SIGNED session (`Samen.Web.Auth.authenticated_user_id/1` —
  never a query param), then calls the host `:operator_authority` MFA with it appended. Validates
  the return is a real operator role. Fail-CLOSED: no seam, an error, or a non-role return → `nil`.
  The mount is consulted ONLY for the host seam — the operator IDENTITY is the session principal.
  """
  @spec resolve_role(Mount.t() | nil, map()) :: Actor.operator_role() | nil
  def resolve_role(%Mount{} = mount, session) when is_map(session) do
    principal_id = principal_id(mount, session)

    case authority_mfa(mount) do
      {mod, fun, args} when is_atom(mod) and is_atom(fun) and is_list(args) ->
        validate_role(apply(mod, fun, args ++ [principal_id]))

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  def resolve_role(_mount, _session), do: nil

  @doc """
  The operator role this SESSION's principal holds — the TENANT chrome's copy of the question
  `resolve_role/2` answers for the operator gate.

  ## Why the tenant chrome needs it (and the gate's answer is not enough)

  `resolve_role/2` reads the host seam off the MOUNT (`:operator_authority`). That label is set
  by `samen_operator_routes/2`, so it exists on an OPERATOR mount and nowhere else — every
  tenant module mount (`:crm`, `:billing`, `:settings`, …) carries the host's shared tenant
  labels instead. A tenant sidebar that wants to know "is the person reading this page also an
  operator?" therefore cannot ask gate 2's resolver: it would answer `nil` for EVERYONE on a
  tenant page, operator or not (the silent-invisibility bug this exists to close).

  So this helper reads the SAME seam with ONE extra fallback: after the mount label it consults
  the host's application env (`config :<otp_app>, :operator_authority`), which is where a host
  that mounts its operator plane declares the authority once for the whole app (samenerp:
  `{Samenerp.OperatorAuthz, :resolve_role, [:samenerp]}`). The `otp_app` comes from the mount
  itself (`Samen.Web.Mount.otp_app/1` — the `:otp_app` label, else `repo.config()[:otp_app]`).

  ## Fail-CLOSED, and display/affordance only

  No seam, an erroring resolver, a `nil` or a non-role return ⇒ `nil` (not an operator). The
  answer decides whether a TENANT surface OFFERS the operator-console link; it grants nothing —
  every `/operator/*` request still passes gate 1 (`Samen.Web.AuthGate`) and gate 2
  (`{Samen.Web.Operator.Authz, :require_operator}`), which re-derive from the session principal
  and refuse independently. Showing the link to a non-operator would be a dead end, not an
  escalation; hiding it from a real operator is the discoverability defect, and it is the one
  this function exists to prevent.
  """
  @spec seat_role(Mount.t() | nil, map()) :: Actor.operator_role() | nil
  def seat_role(%Mount{} = mount, session) when is_map(session) do
    case authority_mfa(mount) || app_env_authority(mount) do
      {mod, fun, args} when is_atom(mod) and is_atom(fun) and is_list(args) ->
        validate_role(apply(mod, fun, args ++ [principal_id(mount, session)]))

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  def seat_role(_mount, _session), do: nil

  @doc """
  WHICH KIND OF ANSWER `seat_role/2` gives on this mount — `:roster` or `:dev_only`.

  The seat is asked two different questions, and they do not deserve the same trust:

    * the tenant CHROME offers the console link from it — display only, so a dev-only seat is fine
      (arguably the point: a developer browsing their own tenant workspace wants the door), and
    * the login LANDING is decided from it — a real placement decision, where a dev-only seat is
      actively wrong, because on a DISARMED host the usual resolver grants an operator role to
      EVERYONE (`Samenerp.OperatorAuthz`'s documented fallback; the shape `dev_operator_role/2`
      names). Sending every dev sign-in to the operator console is not "operators land on the
      console", it is "nobody has a tenant dashboard".

  So the provenance is the host's ARMING posture, resolved through the ONE seam every gate shares
  (`Samen.Web.TenantGate.armed?/1` — an explicit `auth_required?`, else prod-armed /
  dev-test-disarmed):

    * `:roster` — ARMED: the seam's answer is a real roster decision (the same one `/operator/*`
      re-derives per request), so it may PLACE a sign-in.
    * `:dev_only` — DISARMED, or a mount with no host at all: the answer names no operator, so it
      may OFFER the console but never PLACE anyone. A disarmed host keeps the tenant landing.

  Nothing here weakens the gate: `:dev_only` only ever withholds a placement decision, and
  `resolve_role/2` — the actual authorization — is untouched in both postures.
  """
  @type seat_provenance :: :roster | :dev_only

  @spec seat_provenance(Mount.t() | nil) :: seat_provenance()
  def seat_provenance(%Mount{} = mount) do
    if Samen.Web.TenantGate.armed?(Mount.otp_app(mount)), do: :roster, else: :dev_only
  end

  def seat_provenance(_mount), do: :dev_only

  # The host-declared authority seam from APPLICATION ENV — the same `{mod, fun, args}` shape as
  # the mount label, for a host that declares it once instead of threading it into every mount.
  # `nil` for a mount with no resolvable `otp_app` (a bare test mount) or a host that declares
  # none, which keeps `seat_role/2` fail-closed.
  defp app_env_authority(%Mount{} = mount) do
    case Mount.otp_app(mount) do
      nil -> nil
      otp_app -> Application.get_env(otp_app, :operator_authority)
    end
  rescue
    _ -> nil
  end

  # ADR-035 §5 A4 — spine-aware principal. The session may carry ONLY
  # `samen_session_token` (the framework spine), not `samen_current_user`.
  # Prefer the legacy user_id when present (BYO-auth hosts), else resolve
  # the live credential_id from the token. The credential_id is org-less
  # (the Identity spine's per-org User indirection is the operator resolver's
  # job, e.g. `Samenerp.OperatorAuthz` credential→User→Membership); resolving
  # it here would couple this generic gate to one app's schema.
  defp principal_id(%Mount{} = mount, session) do
    case Auth.authenticated_user_id(session) do
      id when is_binary(id) ->
        id

      _ ->
        case Auth.resolve_principal(session, %{session: Mount.resource(mount, Session)}) do
          {:ok, %{credential_id: id}} -> id
          {:ok, %{user_id: id}} -> id
          _ -> nil
        end
    end
  rescue
    _ -> nil
  end



  @doc """
  A NAMED, opt-in DEV operator-authority resolver a host/generated router may wire as its
  `:operator_authority` seam (`{Samen.Web.Operator.Authz, :dev_operator_role, [otp_app]}`).

  Grants `:operator_admin` ONLY while `auth_required?` is false for `otp_app` (dev/test) so the
  dogfood operator console works without a login; returns `nil` (fail CLOSED) the instant the app
  is armed for prod (`config otp_app, auth_required?: true`). Unmistakably dev-only by name — a
  real deploy replaces it with a resolver that consults the operator roster / membership.
  """
  @spec dev_operator_role(atom(), String.t() | nil) :: :operator_admin | nil
  def dev_operator_role(otp_app, _principal_id \\ nil) when is_atom(otp_app) do
    if Samen.Web.TenantGate.armed?(otp_app), do: nil, else: :operator_admin
  end

  # -- internals --------------------------------------------------------------

  defp authority_mfa(%Mount{} = mount), do: Mount.label(mount, :operator_authority, nil)

  defp validate_role(role) when role in @roles, do: role
  defp validate_role(_), do: nil

  defp login_path(%Mount{} = mount), do: Mount.label(mount, :login_path, @default_login_path)
end
