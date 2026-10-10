defmodule Samen.UI.ComponentsTest do
  @moduledoc """
  Structural tests for the `Samen.UI` component kit: each component renders its expected
  markup/classes, and `module_nav/1` renders the INHERITED CRM/Billing/Support groups
  (framework) with the host `:extra` slot rendering the vertical's own 20% nav.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias Samen.Web.{Mount, Plane}

  test "app_shell/1 renders the two-pane grid" do
    html =
      render_component(&Samen.UI.app_shell/1, %{
        sidebar: [%{inner_block: fn _, _ -> Phoenix.HTML.raw("<nav>side</nav>") end}],
        inner_block: [%{inner_block: fn _, _ -> Phoenix.HTML.raw("<p>main</p>") end}]
      })

    assert html =~ ~s(class="app")
    assert html =~ ~s(<main class="main">)
  end

  test "button/1 primary variant renders the filled class" do
    html =
      render_component(&Samen.UI.button/1, %{
        variant: "primary",
        rest: %{},
        inner_block: [%{inner_block: fn _, _ -> "Save" end}]
      })

    assert html =~ ~s(class="btn primary")
    assert html =~ "Save"
  end

  test "pill/1 renders the variant class" do
    html =
      render_component(&Samen.UI.pill/1, %{
        variant: "ok",
        inner_block: [%{inner_block: fn _, _ -> "active" end}]
      })

    assert html =~ ~s(class="pill ok")
    assert html =~ "active"
  end

  test "module_nav/1 renders the inherited CRM/Billing/Support groups with org-threaded hrefs" do
    html =
      render_component(&Samen.UI.module_nav/1, %{
        org_id: "ORG-123",
        active: :crm_contacts,
        extra: []
      })

    # Inherited groups present.
    assert html =~ ">CRM<"
    assert html =~ ">Billing<"
    assert html =~ ">Support<"
    # Org threaded into hrefs.
    assert html =~ "/crm/contacts?org=ORG-123"
    assert html =~ "/billing?org=ORG-123"
    assert html =~ "/support?org=ORG-123"
    # Active item highlighted.
    assert html =~ ~s(class="on")
  end

  test "module_nav/1 renders nav items for the CRM dashboard and mailbox surfaces (H3)" do
    html =
      render_component(&Samen.UI.module_nav/1, %{
        org_id: "ORG-123",
        active: :crm_dashboard,
        extra: []
      })

    # Both shipped surfaces are reachable via nav, not just hand-typed URLs.
    assert html =~ "Dashboard"
    assert html =~ "Mailbox"
    assert html =~ "/crm/dashboard?org=ORG-123"
    assert html =~ "/crm/mailbox?org=ORG-123"
    # The active dashboard item is highlighted.
    assert html =~ ~s(href="/crm/dashboard?org=ORG-123" class="on")
  end

  test "module_nav/1 honors custom path prefixes (host mounted at a different path)" do
    html =
      render_component(&Samen.UI.module_nav/1, %{
        org_id: "O1",
        active: nil,
        crm_path: "/customers",
        billing_path: "/money",
        support_path: "/help",
        extra: []
      })

    assert html =~ "/customers/companies?org=O1"
    assert html =~ "/money/invoices?org=O1"
    assert html =~ "/help?org=O1"
  end

  test "module_nav/1 renders the host's :extra vertical nav BEFORE the inherited groups" do
    html =
      render_component(&Samen.UI.module_nav/1, %{
        org_id: "O1",
        active: nil,
        extra: [%{inner_block: fn _, _ -> Phoenix.HTML.raw(~s(<div class="grp">Operations</div>)) end}]
      })

    assert html =~ "Operations"
    # Extra appears before CRM in the source order.
    assert :binary.match(html, "Operations") < :binary.match(html, ">CRM<")
  end

  # PP-8 (Batch 3 NAV-REACHABILITY) — Settings (Profile / API keys / Security / Invitations)
  # was a total nav island: no item anywhere in `module_nav/1`, reachable only by
  # hand-typing `/settings?org=...`.
  test "module_nav/1 renders a Settings nav item pointing at the settings route (PP-8)" do
    html =
      render_component(&Samen.UI.module_nav/1, %{
        org_id: "ORG-123",
        active: :settings,
        extra: []
      })

    assert html =~ "Settings"
    assert html =~ ~s(href="/settings?org=ORG-123" class="on")
  end

  # PP-9 (Batch 3 NAV-REACHABILITY) — same class of defect as PP-8: the shipped T118
  # workflow builder had no discoverable entry point anywhere in `module_nav/1`.
  # SIDEBAR-REACHABILITY (2026-10-10) — the item is now LABEL-gated (`@automation_path`), not
  # `surfaces`-gated, so a host that mounts no automation surface cannot emit a dead link
  # (pawchart); a host that DID mount it threads the label exactly as this fixture does.
  test "module_nav/1 renders an Automation nav item pointing at the automation route (PP-9)" do
    html =
      render_component(&Samen.UI.module_nav/1, %{
        org_id: "ORG-123",
        active: :automation,
        automation_path: "/automation",
        extra: []
      })

    assert html =~ "Automation"
    assert html =~ ~s(href="/automation?org=ORG-123" class="on")
  end

  # X1 (luminary pre-merge HIGH — ADR-045 §4.1) — a `mix samen.gen.app --modules …` app mounts
  # only a SUBSET of the inherited groups (its router mounts billing + notifications, plus the
  # selected `--modules`, and never CRM/Support/Marketing/Automation). `module_nav/1` must
  # render ONLY the mounted groups (`surfaces: [...]`) so it never emits a nav link to a route
  # the host never mounted — clicking one otherwise raises `Phoenix.Router.NoRouteError`. This
  # is the sabotage-flippable half of the X1 guard (the flagship probe proves it end-to-end
  # over real HTTP; this proves the filter at the component level in the `mix test` harness).
  test "module_nav/1 renders ONLY the mounted surfaces and omits dead-link groups (X1)" do
    # A generated `--modules settings` app: mounts billing + notifications (+ settings),
    # never CRM/Support/Marketing/Automation.
    html =
      render_component(&Samen.UI.module_nav/1, %{
        org_id: "ORG-123",
        active: nil,
        surfaces: [:inbox, :billing, :settings],
        extra: []
      })

    # Mounted groups present...
    assert html =~ ">Inbox<"
    assert html =~ ">Billing<"
    assert html =~ ">Workspace<"
    assert html =~ ~s(href="/notifications?org=ORG-123")
    assert html =~ ~s(href="/settings?org=ORG-123")

    # ...unmounted groups OMITTED — no dead links to routes the router never mounts.
    refute html =~ ">CRM<"
    refute html =~ ">Support<"
    refute html =~ ">Marketing<"
    refute html =~ "/crm/companies"
    refute html =~ "/support?org="
    refute html =~ "/marketing/campaigns"
    refute html =~ "/automation?org="

    # Positive control (anti-tautology): with the default `:all`, every inherited group still
    # renders — a full vertical that mounts them all. Proves the refutes above are the FILTER
    # doing work, not a group that never renders.
    full =
      render_component(&Samen.UI.module_nav/1, %{
        org_id: "ORG-123",
        active: nil,
        automation_path: "/automation",
        extra: []
      })

    assert full =~ ">CRM<"
    assert full =~ ">Support<"
    assert full =~ ">Marketing<"
    assert full =~ "/crm/companies?org=ORG-123"
    assert full =~ "/automation?org=ORG-123"
  end

  # WS-ERP E8 / the remaining nav islands — three surfaces that SHIP with an inherited
  # route macro yet had NO nav entry anywhere (hand-typed-URL-only, the PP-8 defect class):
  # `/crm/gallery` rides `__routes__(:crm, …)`, `/billing/settings` rides
  # `__routes__(:billing, …)`, `/notifications/settings` rides
  # `__routes__(:notifications, …)`. Each is therefore safe inside its OWN group — the X1
  # gate above already hides the whole group when the host doesn't mount the macro.
  test "module_nav/1 links the Gallery, Billing settings, and Notification preferences islands" do
    html =
      render_component(&Samen.UI.module_nav/1, %{
        org_id: "ORG-123",
        active: nil,
        extra: []
      })

    assert html =~ ~s(href="/crm/gallery?org=ORG-123")
    assert html =~ ~s(href="/billing/settings?org=ORG-123")
    assert html =~ ~s(href="/notifications/settings?org=ORG-123")

    # Each island's own active state highlights ITS item.
    gallery = render_component(&Samen.UI.module_nav/1, %{org_id: "ORG-123", active: :crm_gallery, extra: []})
    assert gallery =~ ~s(href="/crm/gallery?org=ORG-123" class="on")

    billing = render_component(&Samen.UI.module_nav/1, %{org_id: "ORG-123", active: :billing_settings, extra: []})
    assert billing =~ ~s(href="/billing/settings?org=ORG-123" class="on")

    prefs =
      render_component(&Samen.UI.module_nav/1, %{org_id: "ORG-123", active: :notifications_settings, extra: []})

    assert prefs =~ ~s(href="/notifications/settings?org=ORG-123" class="on")
  end

  # WS-ERP E8 — all six ERP surfaces were mounted (`samen_erp_routes/3`) but linked from
  # NOWHERE: a total nav island. The group renders ONLY when the host threads a non-nil
  # `erp_path` (the `:erp_path` mount label set alongside the macro), so a host that never
  # mounts `/erp/:surface` never emits it — the X1 posture for a route macro no generated
  # `--modules` subset selects (there is no `surfaces` atom for it).
  test "module_nav/1 renders the six ERP surface items only when the host mounts ERP" do
    # Default (no :erp_path label threaded): the whole group is absent — zero dead links.
    hidden =
      render_component(&Samen.UI.module_nav/1, %{
        org_id: "ORG-123",
        active: nil,
        extra: []
      })

    refute hidden =~ ">ERP<"
    refute hidden =~ "/erp/"

    html =
      render_component(&Samen.UI.module_nav/1, %{
        org_id: "ORG-123",
        active: :erp_stock,
        erp_path: "/erp",
        extra: []
      })

    assert html =~ ">ERP<"

    for surface <- Samen.Web.Erp.surfaces() do
      assert html =~ ~s(href="/erp/#{surface}?org=ORG-123")
    end

    # The labels come from the registry (`Erp.label/1` — "the nav + heading").
    assert html =~ "Chart of Accounts"
    assert html =~ "Purchase Orders"

    # The active surface is highlighted.
    assert html =~ ~s(href="/erp/stock?org=ORG-123" class="on")
  end

  # SIDEBAR-REACHABILITY (2026-10-10) — the seven host-adoption PHASES
  # (`docs/samenerp-mount-ledger.md`) each mounted a module group whose surfaces were reachable
  # only by hand-typing a URL (Files · Chat · Search · own-org analytics · `.ics` · AI · flags).
  # `nav_paths/1` is the single seam that resolves every gated group path from a host mount's
  # labels, so `module_nav/1` renders a group exactly when the host mounted that module — the X1
  # dead-link posture, extended from the `erp_path`/`banking_path`/`work_path` trio.
  describe "module_nav/1 phase-module groups (SIDEBAR-REACHABILITY)" do
    def phase_labels do
      %{
        files_path: "/files",
        chat_path: "/chat",
        search_path: "/search",
        analytics_path: "/analytics",
        ics_path: "/calendar.ics",
        ai_path: "/ai",
        flags_path: "/flags"
      }
    end

    defp tenant_mount(labels) do
      Mount.new(:crm, Samen.WebTest.Crm, Samen.WebTest.Repo,
        plane: Plane.tenant(),
        labels: labels
      )
    end

    defp nav_assigns(mount, extra) do
      mount
      |> Samen.UI.nav_paths()
      |> Enum.into(Map.merge(%{active: nil, extra: []}, extra))
    end

    test "renders one group per mounted phase module, org-threaded" do
      html =
        render_component(
          &Samen.UI.module_nav/1,
          nav_assigns(tenant_mount(phase_labels()), %{org_id: "ORG-123"})
        )

      for {group, item, href} <- [
            {"Documents", "Files", "/files?org=ORG-123"},
            {"Chat", "Conversations", "/chat?org=ORG-123"},
            {"Discover", "Search", "/search?org=ORG-123"},
            {"Insights", "Activation", "/analytics?org=ORG-123"},
            {"Calendar", "Export .ics", "/calendar.ics"},
            {"AI", "AI workspace", "/ai?org=ORG-123"},
            {"Workspace", "Feature flags", "/flags?org=ORG-123"}
          ] do
        assert html =~ ">#{group}<", "the #{group} group must render when its path label is set"

        assert html =~ ~r/>\s*#{Regex.escape(item)}\s*<\/a>/,
               "the #{item} item (link text) must render in the #{group} group"

        assert html =~ ~s(href="#{href}"), "the #{item} item must link #{href}"
      end
    end

    test "the phase module's own page atom highlights its item (:files / :search)" do
      files =
        render_component(
          &Samen.UI.module_nav/1,
          nav_assigns(tenant_mount(phase_labels()), %{org_id: "ORG-123", active: :files})
        )

      assert files =~ ~s(href="/files?org=ORG-123" class="on")

      # `/search` already passed `active: :search` into `module_nav/1` before this group existed,
      # so the item it had nothing to light up now highlights.
      search =
        render_component(
          &Samen.UI.module_nav/1,
          nav_assigns(tenant_mount(phase_labels()), %{org_id: "ORG-123", active: :search})
        )

      assert search =~ ~s(href="/search?org=ORG-123" class="on")
    end

    test "omits every phase group when the host's mount labels carry no path (X1 red half)" do
      html =
        render_component(
          &Samen.UI.module_nav/1,
          nav_assigns(tenant_mount(%{}), %{org_id: "ORG-123"})
        )

      for marker <- [
            "Documents",
            "Conversations",
            "Discover",
            "Activation",
            "Export .ics",
            "AI workspace",
            "Feature flags",
            # SIDEBAR-REACHABILITY (2026-10-10) — the Automation item is label-gated too: the
            # pawchart host mounts no automation surface, so an unlabelled mount must emit NO
            # `/automation` link (this is the live dead link the verifier was written for).
            "Automation"
          ] do
        refute html =~ ">#{marker}<", "#{marker} must NOT render without its path label"
      end

      refute html =~ "/files"
      refute html =~ "/chat"
      refute html =~ "/search?org="
      refute html =~ "/analytics"
      refute html =~ "/calendar.ics"
      refute html =~ "/ai?org="
      refute html =~ "/flags?org="
      refute html =~ "/automation"
    end

    # A chat mount can be an OPERATOR-plane desk chat (driftwood's `/operator/desk-chat`, which
    # carries `chat_path` on ITS OWN labels). An operator-plane sidebar must never emit a bare
    # tenant-plane module link (the silent-crossing class T116 bars), so `nav_paths/1` resolves
    # the tenant-only groups for a `:tenant`-plane mount and nothing else.
    test "nav_paths/1 resolves the tenant-only groups ONLY on the tenant plane" do
      labels = Map.put(phase_labels(), :erp_path, "/erp")

      operator =
        Mount.new(:crm, Samen.WebTest.Crm, Samen.WebTest.Repo,
          plane: Plane.operator("sb-operator", "11111111-0000-4000-8000-000000000001", "sb-session"),
          labels: labels
        )

      paths = Samen.UI.nav_paths(operator)

      for key <- [
            :files_path,
            :chat_path,
            :search_path,
            :analytics_path,
            :ics_path,
            :ai_path,
            :flags_path
          ] do
        assert paths[key] == nil, "#{key} must not resolve on an operator-plane mount"
      end

      # Pre-existing ERP/Banking/Work resolution is deliberately unchanged (label presence only).
      assert paths[:erp_path] == "/erp"

      operator_html =
        render_component(&Samen.UI.module_nav/1, nav_assigns(operator, %{org_id: "ORG-123"}))

      refute operator_html =~ "/files?org="
      refute operator_html =~ "Conversations"
      refute operator_html =~ "AI workspace"

      # Anti-tautology: the SAME labels on a tenant-plane mount DO render the groups.
      tenant_html =
        render_component(
          &Samen.UI.module_nav/1,
          nav_assigns(tenant_mount(labels), %{org_id: "ORG-123"})
        )

      assert tenant_html =~ "/files?org=ORG-123"
      assert tenant_html =~ "AI workspace"
    end
  end

  # PP-10 (Batch 3 NAV-REACHABILITY) — `host_nav_extra/1` is the shared, DATA-driven way
  # a host's own vertical nav (e.g. driftwood's freight "Operations") renders identically
  # from every framework sidebar, instead of only the host's own bespoke page.
  describe "host_nav_extra/1 (PP-10)" do
    def nav_extra_data(org_id),
      do: %{label: "Operations", items: [%{label: "Dispatch board", href: "/broker?panel=dashboard&org=#{org_id}"}]}

    def malformed_nav_extra_data(_org_id), do: :not_a_group_map

    test "renders the host's :host_nav_extra mount-label DATA as a nav group" do
      mount =
        Mount.new(:crm, Samen.UI.ComponentsTest, Samen.WebTest.Repo,
          labels: %{host_nav_extra: {__MODULE__, :nav_extra_data, []}}
        )

      html = render_component(&Samen.UI.host_nav_extra/1, %{mount: mount, org_id: "O1"})

      assert html =~ ">Operations<"
      assert html =~ "Dispatch board"
      assert html =~ ~s(href="/broker?panel=dashboard&amp;org=O1")
    end

    test "renders nothing when the mount carries no :host_nav_extra label" do
      mount = Mount.new(:crm, Samen.UI.ComponentsTest, Samen.WebTest.Repo)
      html = render_component(&Samen.UI.host_nav_extra/1, %{mount: mount, org_id: "O1"})

      refute html =~ "Operations"
      refute html =~ ~s(class="grp")
    end

    test "fails SAFE (renders nothing, never raises) when the MFA returns a malformed shape" do
      mount =
        Mount.new(:crm, Samen.UI.ComponentsTest, Samen.WebTest.Repo,
          labels: %{host_nav_extra: {__MODULE__, :malformed_nav_extra_data, []}}
        )

      html = render_component(&Samen.UI.host_nav_extra/1, %{mount: mount, org_id: "O1"})
      refute html =~ ~s(class="grp")
    end
  end

  test "token_blind_bar/1 and mask_bar/1 render their banners with the chip" do
    tb =
      render_component(&Samen.UI.token_blind_bar/1, %{
        chip: "no reveal path",
        inner_block: [%{inner_block: fn _, _ -> "blind" end}]
      })

    assert tb =~ ~s(class="tb-bar")
    assert tb =~ "no reveal path"

    mb =
      render_component(&Samen.UI.mask_bar/1, %{
        chip: "TTL 10:00",
        inner_block: [%{inner_block: fn _, _ -> "masked" end}]
      })

    assert mb =~ ~s(class="mask-bar")
    assert mb =~ "TTL 10:00"
  end

  # ==========================================================================
  # ADR-011 §6.2 — the activity timeline component (pure, host-agnostic)
  # ==========================================================================

  test "timeline/1 renders typed entries with subject, body, status, and the who/when line" do
    entries = [
      %{
        id: "a1",
        type: :call,
        subject: "Check call — ETA confirmed",
        body: "Driver on schedule, delivering 14:00.",
        status: :completed,
        at: ~U[2026-07-08 13:00:00Z],
        who: "dispatch"
      },
      %{id: "a2", type: :note, subject: "Left voicemail", body: nil, status: :pending, at: nil, who: nil}
    ]

    html = render_component(&Samen.UI.timeline/1, %{entries: entries, composer: []})

    assert html =~ ~s(class="tl-rail")
    assert html =~ "Check call — ETA confirmed"
    assert html =~ "Driver on schedule"
    assert html =~ "Left voicemail"
    # Type label + status pill.
    assert html =~ "Call"
    assert html =~ ~s(class="pill ok")
    # who/when line.
    assert html =~ "dispatch"
    assert html =~ "2026-07-08 13:00 UTC"
    # Per-entry id from the entry.
    assert html =~ "tl-entry-a1"
  end

  test "timeline/1 renders the empty state when there are no entries" do
    html = render_component(&Samen.UI.timeline/1, %{entries: [], empty: "Nothing here.", composer: []})

    assert html =~ ~s(class="tl-empty")
    assert html =~ "Nothing here."
    refute html =~ ~s(class="tl-rail")
  end

  test "timeline/1 slots a composer above the rail without knowing about writes" do
    html =
      render_component(&Samen.UI.timeline/1, %{
        entries: [],
        composer: [%{inner_block: fn _, _ -> Phoenix.HTML.raw(~s(<form id="the-composer"></form>)) end}]
      })

    assert html =~ ~s(class="tl-composer")
    assert html =~ ~s(id="the-composer")
  end

  test "timeline/1 renders a %Masked{} entry field verbatim (•••• — no unmasking)" do
    masked = %Samen.Masked{token: "vt_ignored", label: :pii_name}
    entries = [%{id: "m1", type: :note, subject: masked, body: nil, status: :completed, at: nil, who: nil}]
    html = render_component(&Samen.UI.timeline/1, %{entries: entries, composer: []})

    assert html =~ "••••"
  end

  test "lifecycle_pill/1 renders a known stage and nothing for an unknown/nil stage" do
    assert render_component(&Samen.UI.lifecycle_pill/1, %{stage: "lead"}) =~ "Lead"
    assert render_component(&Samen.UI.lifecycle_pill/1, %{stage: "customer"}) =~ ~s(class="pill ok")
    # Unknown/nil renders no pill.
    refute render_component(&Samen.UI.lifecycle_pill/1, %{stage: "bogus"}) =~ ~s(class="pill)
    refute render_component(&Samen.UI.lifecycle_pill/1, %{stage: nil}) =~ ~s(class="pill)
  end

  test "social_links/1 renders icon-links for known flat bag keys and nothing when absent" do
    custom = %{"social_linkedin" => "https://linkedin.com/in/sofia", "social_github" => "https://github.com/sofia"}
    html = render_component(&Samen.UI.social_links/1, %{custom: custom})

    assert html =~ "https://linkedin.com/in/sofia"
    assert html =~ "https://github.com/sofia"
    assert html =~ ~s(class="social-linkedin")

    # No bag → no links element.
    refute render_component(&Samen.UI.social_links/1, %{custom: nil}) =~ ~s(class="social-links")
  end

  # Linked breadcrumbs (Samen.Web.Crumbs) — a `{label, href}` crumb renders as a
  # LIVE anchor; a plain-string crumb (the trail's leaf / the current page) stays
  # inert text, byte-for-byte the pre-link rendering.
  test "topbar/1 renders {label, href} crumbs as live links and string crumbs as inert text" do
    html =
      render_component(&Samen.UI.topbar/1, %{
        title: "Acme",
        crumbs: [
          {"Gridworkz QA", "/crm/dashboard?org=ORG-1"},
          "CRM",
          {"Companies", "/crm/companies?org=ORG-1"},
          "Acme"
        ]
      })

    # Linked crumbs are real anchors…
    assert html =~ ~s(<a href="/crm/dashboard?org=ORG-1")
    assert html =~ ~s(<a href="/crm/companies?org=ORG-1")
    assert html =~ ">Gridworkz QA</a>"
    assert html =~ ">Companies</a>"
    # …plain crumbs (mid-trail plain section + leaf) render as text, never as links.
    refute html =~ ">CRM</a>"
    refute html =~ ">Acme</a>"
    assert html =~ "CRM"
    assert html =~ "Acme"
    # Exactly one anchor per tuple crumb.
    assert length(Regex.scan(~r/<a /, html)) == 2
  end

  test "topbar/1 keeps an all-string trail inert (sep-joined, zero anchors)" do
    html = render_component(&Samen.UI.topbar/1, %{title: "Fleet", crumbs: ["Operator plane", "Fleet"]})

    refute html =~ "<a "
    assert html =~ "Operator plane"
    assert html =~ "Fleet"
    assert html =~ ~s(class="sep")
  end
end
