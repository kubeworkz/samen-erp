defmodule Samenerp.Analytics do
  @moduledoc """
  Samenerp's Analytics domain — mounted from the `samen_core` Analytics scope
  blueprint (ADR-004; WS-B / G12; ADR-021), exactly as `demo` / `driftwood` /
  `pawchart` mount it. One `use Samen.Scopes.Analytics` expands into the host-owned
  resource `Samenerp.Analytics.ProductEvent` — the governed, token-blind
  product-event ledger (`sae`), in SAMENERP's `otp_app`/`repo`, so:

    * its columns catalogue into Samenerp's `tam_table`/`fld_field`
      (the `AddAnalyticsScope` migration's `catalog_sync/1`);
    * Samenerp's unchanged verifiers scan it;
    * it mirrors through the vault-excluded CDC projection for free (token-blind);
    * org-scope + RBAC policies are inherited, not re-authored.

  ## Why this host needed it (the producer, not just the reader)

  Samenerp mounted the tenant `/analytics` surface (P17) and the operator analytics
  plane over the raw rollup tables in Phase 3 (migration `20261006140000`), which
  created `paf_product_event_rollup` — but **nothing wrote it**, because the funnel
  rollup is rebuilt from the host's product-event LEDGER:
  `config :samen_core, :rollups`'s domain-sourced `:product_event_rollup` spec reads
  `<abbrev>_product_event`. Samenerp had no such ledger, so the rollup stayed empty
  and Insights → Activation rendered its empty state forever — the fail-honest
  posture that migration names ("Registering the specs is the host's follow-on once
  a ledger exists"). This module + the `:rollups` spec in `config/config.exs` ARE
  that follow-on: the ledger is the source, the rollup is the read model, and the
  surface finally reflects real activity.

  ## Abbrev allocation (fresh abbrev — the built-substrate reality)

  The scope-default abbrev `pae` is owned by the demo mount in the single GLOBAL
  registry (`samen_core/priv/abbrev_registry.json`), so Samenerp takes the FRESH
  abbrev `sae` via the blueprint's `abbrevs:` override, reserved with the sanctioned
  allocator (`mix samen.abbrev.reserve --host samenerp --abbrev sae
  --owner Samenerp.Analytics.ProductEvent`) — never edited by hand (ADR-023). The
  registry gained Samenerp's reserved row, append-only (ADR-006, one-owner-forever).

  ## Capture

  `sae` rows are written ONLY via `Samen.Analytics.track/1` (best-effort,
  PII-refusing-at-capture). The framework emitter is wired in config:

      config :samen_core, Samen.Analytics, product_event_resource: Samenerp.Analytics.ProductEvent
      config :samen_core, Samen.FeatureFlags, emit: {Samen.Analytics, :track}

  so the framework choke points this app already runs — the session controller's
  sign-in (`session.signed_in`), first-run onboarding (`first_run.completed` +
  `record.created`), the ⌘K search surface (`search.used`) and every flag-variant
  assignment — capture bounded, token-blind events with zero call-site changes.
  Before this config landed, `track/1` was INERT (`{:ok, :dropped}`) on this host:
  the emitters fired and every event was dropped, which is exactly why an empty
  funnel was guaranteed rather than merely possible.
  """

  use Ash.Domain, validate_config_inclusion?: false

  use Samen.Scopes.Analytics,
    otp_app: :samenerp,
    repo: Samenerp.Repo,
    namespace: Samenerp.Analytics,
    abbrevs: %{product_event: "sae"}
end
