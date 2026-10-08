defmodule Samenerp.Calendar do
  @moduledoc """
  The Samenerp host's **Calendar** domain — mounted from the `samen_core`
  Calendar scope blueprint (F2, T44; ADR-004), exactly as
  `Samenerp.Work`/`Samenerp.Cms` mount their scopes.

  One `use Samen.Scopes.Calendar` expands into ONE host-owned resource,
  `Samenerp.Calendar.Event`, a normal `use Samen.Resource` in THIS app's
  `otp_app`/`repo`, so:

    * its columns are catalogued in this app's `tam_table`/`fld_field` (the
      `MountCalendarScope` migration's `catalog_sync/1`);
    * this app's unchanged verifiers scan it (`catalog_parity`, `pii_reads`,
      `no_pii_columns`, `tnt_boundary`, …);
    * org-scope + RBAC policies are inherited, not re-authored;
    * `attendees` is 🔒 vault-routed (`vault: :pii_attendees`) — masked per
      plane through the SAME `Samen.Api.PiiResolution` seam every other
      vaulted field uses (INV-1).

  ## The web half — Phase 6

  The `.ics` (RFC-5545) export is the one web surface this scope carries, and
  it is adopted in the router with a single `samen_ics_routes(:ics,
  Samenerp.Calendar, repo: Samenerp.Repo)` call (the pawchart/driftwood
  precedent) — zero authored controllers or LiveViews. `Samen.Web.Ics` reads
  `Event` through the bounded `Samen.Web.Reads` keyset path and resolves every
  page on the acting plane, so the downloaded feed and the pixel agree.

  ## Abbrev

  `evt` — reserved through `mix samen.abbrev.reserve` (ADR-023), host
  `samenerp`. The registry is append-only and never hand-edited; there is no
  scope-default Calendar abbrev (unlike Work's `wpj`/`wtk`), so `abbrevs:` is
  required at every mount.
  """
  use Ash.Domain, validate_config_inclusion?: false

  use Samen.Scopes.Calendar,
    otp_app: :samenerp,
    repo: Samenerp.Repo,
    namespace: Samenerp.Calendar,
    abbrevs: %{event: "evt"}
end
