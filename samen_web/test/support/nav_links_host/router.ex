defmodule Samen.WebTest.NavLinksHost.Router do
  @moduledoc """
  The framework's REFERENCE TENANT HOST for `mix samen.verify.nav_links` — the router
  `samen_web/ci.sh` certifies.

  `samen_web` is the framework library, not a product: it has no host router of its own, and its
  other test-support routers each mount a SUBSET for one property (authn, billing roles, the fleet
  cockpit). The nav-links verifier needs the opposite fixture — a host that mounts EVERY gated
  module group — because a certification over a subset is exactly the vacuous run the verifier's
  free-standing `empty_emit`/`unlabelled_mount` legs refuse. This router is that full mount, in one
  place, so the framework's own gate proves both legs end to end: every label in `@labels` really
  emits a link through the real `Samen.UI.Nav.module_nav/1`, and every one of those links really
  resolves against the compiled route table below.

  It is deliberately NOT a product surface: no pipelines, no endpoint, no resources behind the
  namespaces (`Samen.WebTest.*` scopes are the fixtures each mount macro already has). Nothing
  renders from it — the verifier reads `__routes__/0` and the source, not a page. A router that
  mounts a REAL subset is certified by that host's own gate (see `samenerp/ci.sh`,
  `driftwood/ci.sh`, `pawchart/ci.sh`).
  """

  use Phoenix.Router
  import Phoenix.LiveView.Router
  import Samen.Web.Router

  # The host's shared TENANT-plane label map — one path label per gated group, each the default
  # path of the mount macro it belongs to (a drift here is precisely what `mix
  # samen.verify.nav_links` fails on).
  @labels %{
    authn: {:app_env, :samen_web, false},
    erp_path: "/erp",
    banking_path: "/banking",
    work_path: "/work",
    files_path: "/files",
    chat_path: "/chat",
    search_path: "/search",
    analytics_path: "/analytics",
    ics_path: "/calendar.ics",
    ai_path: "/ai",
    flags_path: "/flags",
    automation_path: "/automation"
  }

  scope "/" do
    samen_module_routes(:crm, Samen.WebTest.Crm, repo: Samen.WebTest.Repo, labels: @labels)
    samen_module_routes(:billing, Samen.WebTest.Billing, repo: Samen.WebTest.Repo, labels: @labels)

    samen_module_routes(:support, Samen.WebTest.Support,
      repo: Samen.WebTest.Repo,
      labels: @labels
    )

    samen_module_routes(:marketing, Samen.WebTest.Marketing,
      repo: Samen.WebTest.Repo,
      labels: @labels
    )

    samen_module_routes(:work, Samen.WebTest.Work, repo: Samen.WebTest.Repo, labels: @labels)

    samen_module_routes(:banking, Samen.WebTest.Banking,
      repo: Samen.WebTest.Repo,
      labels: @labels
    )

    samen_erp_routes(:erp, Samen.WebTest.Erp, repo: Samen.WebTest.Repo, labels: @labels)

    samen_notifications_routes(:notifications, Samen.WebTest.Primitives,
      repo: Samen.WebTest.Repo,
      labels: @labels
    )

    samen_files_routes(:files, Samen.WebTest.Primitives,
      repo: Samen.WebTest.Repo,
      labels: @labels
    )

    samen_chat_routes(:chat, Samen.WebTest.Chat, repo: Samen.WebTest.Repo, labels: @labels)

    samen_search_routes(:search, Samen.WebTest.Primitives,
      repo: Samen.WebTest.Repo,
      labels: @labels
    )

    samen_ics_routes(:ics, Samen.WebTest.Calendar, repo: Samen.WebTest.Repo, labels: @labels)

    samen_flags_routes(:flags, Samen.WebTest.Primitives,
      repo: Samen.WebTest.Repo,
      labels: @labels
    )

    samen_tenant_analytics_routes(Samen.WebTest.Primitives,
      repo: Samen.WebTest.Repo,
      labels: @labels
    )

    samen_ai_routes(:ai, Samen.WebTest.Crm, repo: Samen.WebTest.Repo, labels: @labels)

    samen_automation_routes(:automation, Samen.WebTest.Automation,
      repo: Samen.WebTest.Repo,
      labels: @labels
    )

    samen_settings_routes(:settings, Samen.WebTest.Operator,
      repo: Samen.WebTest.Repo,
      labels: @labels
    )
  end
end
