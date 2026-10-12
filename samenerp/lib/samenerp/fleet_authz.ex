defmodule Samenerp.FleetAuthz do
  @moduledoc """
  J3 / ADR-044 §6.2/§6.3a #1 — Samen ERP's FLEET-WIDE role read, wired as the
  `:fleet_authority` seam now that this host mounts the fleet cockpit
  (`samen_operator_routes(..., fleet_cockpit: true)`, ADR-050 §6.1).

  The seam is an `{mod, fun, args}` MFA under `config :samenerp, :fleet_authority`;
  `Samen.Fleet.Authz.roles_for/2` calls it with the authenticated principal id
  APPENDED and validates the returned `%{scope => role}` map — a non-atom scope or a
  role outside `Samen.OperatorPlane.Actor.roles/0` is DROPPED, and a missing seam, an
  erroring resolver or a non-map return collapses to `%{}` (mask-by-omission, ADR-028:
  a resolver bug fails toward LESS access, never more).

  ## One identity, N authorizations (ADR-044 §6.1) — and NO second roster

  This host already owns exactly one answer to "is this principal an operator here?":
  `Samenerp.OperatorAuthz.resolve_role/2`, the resolver the operator plane's own
  `:operator_authority` seam uses (credential → User → operator-org Membership, with
  `:owner` → `:operator_admin`, `:admin` → `:operator_support`, `:member` →
  `:operator_readonly`, and a DEV-only grant while `:auth_required?` is false).

  The fleet read DELEGATES to that resolver rather than provisioning a second roster.
  A second roster would be a second policy that can drift from the operator plane's —
  an operator could hold the console and not the cockpit, or the reverse, with neither
  decision auditable against the other. One identity, one authorization decision, and
  arming the host for production (`auth_required?: true`) closes both surfaces at once.

  ## The two scopes

    * the reserved **`:fleet`** scope — "may open the cockpit at all" (§5.4 tier 1);
    * a **per-product** scope for each atom in `config :samenerp, :fleet_products` —
      "may see THIS product's tier-2 rows and flip its public-status opt-in" (§5.4
      tier 2, and the gate `Samen.Web.Operator.FleetDetailLive`'s publish action
      checks).

  `:fleet_products` defaults to `[:samenerp]` — the product this host IS (it mounts
  `samen_fleet_routes(otp_app: :samenerp)`, so it already reports as a fleet app) and
  the one slug whose atom this app can name without inventing a portfolio. Add each
  additional product's slug atom as the fleet grows.

  Why a compiled atom list and not free text: the framework atomizes a slug for the
  scope lookup (`Samen.Web.Operator.Fleet.app_scope/1` → `String.to_existing_atom/1`),
  so a product's scope is a PROVISIONED grant — the same posture as the operator/fleet
  rosters a co-resident host configures. Widening a grant is a config change a reviewer
  can see, never something a registered row can confer on itself.
  """

  alias Samen.OperatorPlane.Actor

  @roles Actor.roles()

  @doc """
  `%{scope => role}` for `principal_id`: the reserved `:fleet` scope plus one scope per
  configured product, all at the role this host's operator resolver reports.

  Fail CLOSED to `%{}` for anyone `Samenerp.OperatorAuthz` does not call an operator —
  including a `nil` principal on an ARMED host.
  """
  @spec fleet_roles(String.t() | nil) :: %{atom() => atom()}
  def fleet_roles(principal_id) do
    case Samenerp.OperatorAuthz.resolve_role(:samenerp, principal_id) do
      role when role in @roles ->
        Enum.reduce(product_scopes(), %{fleet: role}, fn slug, acc -> Map.put(acc, slug, role) end)

      _ ->
        %{}
    end
  end

  @doc """
  The product scopes this host grants, as slug atoms (`config :samenerp,
  :fleet_products`). Non-atom entries are dropped rather than atomized.
  """
  @spec product_scopes() :: [atom()]
  def product_scopes do
    case Application.get_env(:samenerp, :fleet_products, []) do
      slugs when is_list(slugs) -> Enum.filter(slugs, &is_atom/1)
      _other -> []
    end
  end
end
