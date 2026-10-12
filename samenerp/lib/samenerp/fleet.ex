defmodule Samenerp.Fleet do
  @moduledoc """
  Samenerp's FLEET-COCKPIT domain — mounts the framework `Samen.Fleet.Scope`
  blueprint (ADR-044 §4.1, WS-J J1), the five `flt_*`-shaped resources behind the
  portfolio registry.

  ## Why this host mounts it (a RULING REVERSAL, recorded)

  As of 2026-10-08 this repo's ruling was that the cockpit side is deliberately
  unshipped: *"No product adopts the cockpit side, and that is a decision, not an
  oversight"* (`docs/samenerp-mount-ledger.md`), with ADR-044 §9.3 stating the same —
  *"no host mounts `fleet_cockpit: true`, and no host holds the `flt_*` scope"* — so
  that the ≥2-vertical proof never required a vertical to host a cockpit.

  ADR-050 (the public status page) is what changes that arithmetic. `GET /status`
  projects `Samen.Fleet.Registry.build_row/3`'s already-computed rows, so the page
  cannot be *live* without a fleet substrate to project: mounting the route against
  a namespace that does not exist fails closed to a permanent 503 (by design — §4.5
  refuses an empty 200). Samenerp is the operator-facing product here, so it becomes
  the PORTFOLIO HOST: it holds the registry rows from which the public page reads.

  **Since the same day (T166b), the host also mounts the COCKPIT UI** —
  `samen_operator_routes(Samenerp.Operator, …, fleet_cockpit: true, fleet_namespace:
  Samenerp.Fleet)` in `SamenerpWeb.Router`, with the `:fleet_authority` seam
  (`Samenerp.FleetAuthz`), `:fleet_products` and `:fleet, mode: :manual` wired in
  config. The reason is the paragraph above: this host HOLDS the registry, so the
  publish action ADR-050 §4.3 defines is worth a UI exactly here, and console-only
  made the feature's own opt-in an operator script step. What still does NOT exist
  on this host is the cockpit-side INGEST (`samen_fleet_ingest_routes`, unshipped
  fleet-wide) — a mode-A `:pull` cockpit needs none, which is what ADR-044
  §3.1/§9.2's one-directional rule exists to allow. Nothing is published until an
  operator opts an app in per-row (`Samen.Fleet.Registry.set_publish_status/4`, or
  the cockpit's own admin-gated control), so the landed state is an empty public
  page, never the fleet.

  ## The five resources (abbrevs reserved `efa`/`efc`/`efe`/`efr`/`efd`)

    * `Samenerp.Fleet.App`             — one registered product
    * `Samenerp.Fleet.Credential`      — one key version for one app
    * `Samenerp.Fleet.EnrollmentToken` — a single-use mode-B enrollment grant
    * `Samenerp.Fleet.Report`          — one received `FleetReport`
    * `Samenerp.Fleet.Directive`       — one published fleet directive

  Abbrevs were reserved through the sanctioned allocator
  (`mix samen.abbrev.reserve --host samenerp`), never by hand (ADR-023): the
  signatures in this namespace are `efa_*`/`efc_*`/`efe_*`/`efr_*`/`efd_*`.
  """
  use Ash.Domain, validate_config_inclusion?: false

  use Samen.Fleet.Scope,
    otp_app: :samenerp,
    repo: Samenerp.Repo,
    namespace: Samenerp.Fleet,
    abbrevs: %{
      app: "efa",
      credential: "efc",
      enrollment_token: "efe",
      report: "efr",
      directive: "efd"
    }
end
