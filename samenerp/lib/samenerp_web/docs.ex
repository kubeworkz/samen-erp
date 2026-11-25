defmodule SamenerpWeb.Docs do
  @moduledoc """
  The samenerp feature documentation, rendered at `/docs`.

  The categories ARE the tenant sidebar's groups (`Samen.UI.Nav.module_nav/1`,
  in its own order): ERP · Banking · Work · Inbox · CRM · Billing · Support ·
  Marketing · Documents · Chat · Discover · Insights · Calendar · AI ·
  Workspace. A reader who knows where a screen lives in the app therefore
  knows where its page lives in the docs — there is no second taxonomy.

  Every `path` below is a route THIS host mounts
  (`samenerp/lib/samenerp_web/router.ex`); the doc pages link the live screen,
  not an illustration of it. Content is data (`groups/0`) with one renderer, so
  growing the docs is adding a map — no template surgery.

  Deliberately plain HTML (the same posture as
  `SamenerpWeb.PageController.index/2`): the docs are public, static, need no
  session, no org and no LiveView, and must render even while the database is
  down. Nothing here reads the request.
  """

  # `?org=` is the disarmed-dev convenience selector the landing page also uses;
  # every tenant page resolves the org from it (or from the session when armed).
  @groups [
    %{
      id: "erp",
      label: "ERP",
      glyph: "📊",
      summary:
        "The WS-ERP surfaces over this host's Finance, Procurement, Inventory and Manufacturing " <>
          "scopes. Every surface is a bounded read — only the registry's column list renders, and no " <>
          "PII column exists on any of them — and every write is a form or button over the resource's " <>
          "own governed action. There is no destroy and no export path on these surfaces.",
      pages: [
        {"Dashboard", "/erp", "The ERP group's landing page: the surfaces this host mounted."},
        {"Chart of Accounts", "/erp/coa",
         "The account tree the ledger posts against — types, codes, and the accounts foreign-currency revaluation reads."},
        {"Journal", "/erp/entries",
         "Journal entries with their lines. An unbalanced entry is refused by construction; the posting and " <>
           "void transitions are the resource's own gated actions."},
        {"Journal templates", "/erp/journal_templates", "Recurring entry shapes to start an entry from."},
        {"AP Invoices", "/erp/ap_invoices",
         "Accounts payable. Approval-time three-way match (PO · receipt · invoice) is enforced by the invoice's " <>
           "own approval path, not by the page."},
        {"Credit Notes", "/erp/credit_notes", "Customer credits against AR documents."},
        {"Vendor Credits", "/erp/vendor_credits", "Supplier credits against AP documents."},
        {"Stock", "/erp/stock",
         "The append-only stock ledger and its derived rollup. Negative stock is refused fail-closed."},
        {"Purchase Orders", "/erp/purchase_orders",
         "Procurement: RFQ → PO → goods receipt → invoice match. A PO posts nothing on approval; " <>
           "realization happens at the receipt."},
        {"Goods Receipts", "/erp/goods_receipts",
         "The one-transaction chokepoint: a receipt posts stock AND the GL entry together, or neither."},
        {"Work Orders", "/erp/work_orders",
         "Manufacturing over BOMs — consume, produce and log agree exactly once; a BOM cycle is refused."},
        {"AP capture", "/erp/ap-capture", "Capture an incoming invoice document into an AP invoice."},
        {"AP payments", "/erp/ap-payments",
         "The payment run. A pending reversal of a payment needs a DIFFERENT admin's decision — the nav " <>
           "badge counts what is waiting on someone else."},
        {"AP aging", "/erp/ap-aging", "Open payables bucketed by age."},
        {"AP approval", "/erp/ap-approval",
         "The AP chain's approval policy: the generic approval-policy row for `ap_invoice:approve`."},
        {"AR receipts", "/erp/ar-receipts", "Customer receipts applied against invoices."},
        {"AR aging", "/erp/ar-aging", "Open receivables bucketed by age, sourced from this host's Billing invoices."},
        {"AR settings", "/erp/ar-settings", "The AR control row (terms and defaults)."},
        {"Journal approval", "/erp/journal-approval",
         "The org's journal-approval control. Changing the control itself is a two-admin act."},
        {"Reconciliation", "/erp/reconciliation", "Ledger-versus-bank reconciliation over the Banking bridge."},
        {"Payroll mappings", "/erp/payroll-mappings", "Which GL accounts a payroll run posts to."},
        {"Grants", "/grants",
         "The bounded grants index (personnel grants behind reveals) — grants never unlock the AI egress class."},
        {"Close", "/close", "The monthly close dashboard."},
        {"Board pack", "/board", "The board-report read over the ledger: TB/WIP/headcount rollups and budget-vs-actual."}
      ]
    },
    %{
      id: "banking",
      label: "Banking",
      glyph: "🏦",
      summary:
        "Bank accounts and the rules that match statement lines to ledger entries. Banking resolves its GL " <>
          "account and journal references through this host's Finance namespace, so a match always points at " <>
          "a real ledger row.",
      pages: [
        {"Accounts", "/banking", "Statement accounts and their running balance."},
        {"Rules", "/banking/rules", "Matching rules that turn a statement line into a proposed GL match."}
      ]
    },
    %{
      id: "work",
      label: "Work",
      glyph: "✅",
      summary:
        "The canonical Work scope: Task (the single work item every surface rides), Project, and the " <>
          "timeline view. CRM timelines and CDC ride the same Task rows — there is no second activity model.",
      pages: [
        {"Tasks", "/work", "The task list, filterable by project and status."},
        {"Projects", "/work/projects", "Projects that group tasks and carry the billable context."},
        {"Timeline", "/work/timeline", "Tasks on a time axis, multi-anchor."
        }
      ]
    },
    %{
      id: "inbox",
      label: "Inbox",
      glyph: "🔔",
      summary:
        "The framework notifications inbox over this host's Primitives mount: rendered notifications, and the " <>
          "per-user preferences that decide what lands in it.",
      pages: [
        {"Notifications", "/notifications", "Rendered notifications for the signed-in user."},
        {"Preferences", "/notifications/settings", "Per-channel, per-kind delivery preferences."}
      ]
    },
    %{
      id: "crm",
      label: "CRM",
      glyph: "👥",
      summary:
        "Companies, contacts and the pipeline, plus the surfaces that turn them into a working book of " <>
          "business: mailbox sync, sequences, the activity calendar and the dashboard. Vault-routed fields " <>
          "resolve on the caller's plane — an operator without a grant sees a mask, never plaintext.",
      pages: [
        {"Companies", "/crm/companies", "Accounts you sell to, with their owners and custom fields."},
        {"Contacts", "/crm/contacts", "People at those companies (PII fields are vault-routed)."},
        {"Gallery", "/crm/gallery", "The visual card view over the same records."},
        {"Pipeline", "/crm/pipeline", "Deals by stage."},
        {"Calendar", "/crm/calendar", "Dated CRM activity."},
        {"Dashboard", "/crm/dashboard", "The workspace home: the CRM read every mount lands on."},
        {"Mailbox", "/crm/mailbox",
         "Two-way email sync: inbound threads anchor to the RIGHT person (matched over vaulted addresses, " <>
           "org-pinned) and outbound lands on the same timeline."},
        {"Sequences", "/crm/sequences",
         "Multi-step outreach enrollment with honest step status — a blocked step never reads as delivered."}
      ]
    },
    %{
      id: "billing",
      label: "Billing",
      glyph: "💳",
      summary:
        "The Billing scope mounted as-is from samen_core: the subscription and invoice book for this " <>
          "workspace, separate from the ERP's AR documents but readable by them.",
      pages: [
        {"Customers", "/billing", "The billing overview: customers and their subscription state."},
        {"Invoices", "/billing/invoices", "Issued invoices and their payment status."},
        {"Dunning", "/billing/dunning", "Failed-payment recovery runs."},
        {"Plans", "/billing/plans", "The plans a customer can be on."},
        {"Settings", "/billing/settings", "Billing-level configuration for this org."}
      ]
    },
    %{
      id: "support",
      label: "Support",
      glyph: "🎧",
      summary:
        "The helpdesk: tickets with SLAs and macros, and a knowledge base whose public/internal boundary is " <>
          "enforced on every read path (direct read, portal deflection, and the AI suggestion path).",
      pages: [
        {"Tickets", "/support", "The ticket queue with SLA state and assignment."},
        {"Knowledge base", "/support/kb", "Articles, with the public/internal visibility boundary."}
      ]
    },
    %{
      id: "marketing",
      label: "Marketing",
      glyph: "📣",
      summary:
        "Campaigns, segments and leads over the Marketing scope. A send runs through the suppression " <>
          "chokepoint: a suppressed or unconsented address is refused at the single send seam.",
      pages: [
        {"Campaigns", "/marketing/campaigns", "Campaign definitions and their send state."},
        {"Segments", "/marketing/segments", "The saved audiences a campaign targets."},
        {"Leads", "/marketing/leads", "Captured leads feeding the CRM."}
      ]
    },
    %{
      id: "documents",
      label: "Documents",
      glyph: "📄",
      summary:
        "Pages (the Docs scope: titled pages, untitled notes, typed blocks and `[[links]]` between them) and " <>
          "Files (the upload chokepoint — a file is `:quarantined` until a clean scan promotes it, and " <>
          "`storage_key` is minted only by `Samen.Files.upload/3`).",
      pages: [
        {"Pages", "/pages", "Write and browse pages; secure bodies and blocks are vault-routed."},
        {"Files", "/files", "Upload and download, with the quarantine → promotion lifecycle and retention."}
      ]
    },
    %{
      id: "chat",
      label: "Chat",
      glyph: "💬",
      summary:
        "Internal conversations. Reads are org-scoped and keyset-bounded; attachments go through the same " <>
          "upload chokepoint as Files.",
      pages: [{"Conversations", "/chat", "Channels and threads for this workspace."}]
    },
    %{
      id: "discover",
      label: "Discover",
      glyph: "🔎",
      summary:
        "Cross-surface search. The match oracle runs over the PLANE-RESOLVED value, so a field the caller " <>
          "cannot see is structurally unmatchable — present and absent look identical.",
      pages: [{"Search", "/search", "One query across the records this caller can read."}]
    },
    %{
      id: "insights",
      label: "Insights",
      glyph: "📈",
      summary:
        "Product analytics over this workspace's own events. Aggregates are token-blind; a refused read " <>
          "explains the role it needs instead of rendering a made-up number.",
      pages: [{"Activation", "/analytics", "Activation and usage for this org."}]
    },
    %{
      id: "calendar",
      label: "Calendar",
      glyph: "🗓️",
      summary: "A calendar feed of this workspace's dated records, for any client that speaks iCalendar.",
      pages: [{"Export .ics", "/calendar.ics", "The iCalendar feed (subscribe from your own calendar app)."}]
    },
    %{
      id: "ai",
      label: "AI",
      glyph: "✨",
      summary:
        "The AI workspace over the kernel AI plane. Prompts are masked before egress through the " <>
          "no-PII-egress chokepoint, and the model is the operator's own BYOK configuration — an " <>
          "unconfigured key refuses honestly instead of pretending to answer.",
      pages: [{"AI workspace", "/ai", "Ask, draft and propose — writes still go through approvals."}]
    },
    %{
      id: "workspace",
      label: "Workspace",
      glyph: "⚙️",
      summary:
        "Workspace-level administration: settings (org, members, security), the automation builder, and " <>
          "feature flags.",
      pages: [
        {"Settings", "/settings", "Org profile, members and their roles, and security settings."},
        {"Automation", "/automation", "Workflow builder: triggers, conditions and actions."},
        {"Feature flags", "/flags", "Flag admin over this host's FeatureFlag rows."}
      ]
    }
  ]

  @guides [
    %{
      id: "getting-started",
      title: "Getting started",
      summary: "Run samenerp locally, sign in, and find your way around the workspace."
    }
  ]

  @doc "Every documentation category, in sidebar order."
  def groups, do: @groups

  @doc "The non-category guides shown above the categories in the index."
  def guides, do: @guides

  @doc "One category by `id`, or `nil`."
  def group(id), do: Enum.find(@groups, &(&1.id == id))

  @doc "How many feature pages the catalog links."
  def page_count, do: @groups |> Enum.map(&length(&1.pages)) |> Enum.sum()

  @doc "The `/docs` index page."
  def index_html do
    cards =
      Enum.map_join(@groups, "\n", fn group ->
        """
        <section class="cat" id="#{group.id}">
          <h2><a href="/docs/#{group.id}">#{group.glyph} #{esc(group.label)}</a></h2>
          <p class="sum">#{esc(group.summary)}</p>
          <ul class="pages">
            #{Enum.map_join(group.pages, "\n", fn {name, path, note} -> page_item(name, path, note) end)}
          </ul>
        </section>
        """
      end)

    guides =
      Enum.map_join(@guides, "\n", fn guide ->
        """
        <a class="card" href="/docs/#{guide.id}">
          <h3>#{esc(guide.title)}</h3>
          <p>#{esc(guide.summary)}</p>
        </a>
        """
      end)

    layout("Documentation", """
    <div class="hero">
      <h1>Documentation</h1>
      <p>Samen ERP's features, grouped exactly as the workspace sidebar groups them —
         #{length(@groups)} categories, #{page_count()} pages.</p>
    </div>

    <div class="container">
      <div class="section">
        <h2 class="plain">Start here</h2>
        <div class="grid">
          #{guides}
          <a class="card" href="/api/openapi.json">
            <h3>API reference</h3>
            <p>The OpenAPI 3.0 contract for the public <code>/api/v1</code> JSON:API surface.</p>
          </a>
        </div>
      </div>
      #{cards}
      <p class="back"><a href="/">← Back to Samen ERP</a></p>
    </div>
    """)
  end

  @doc "One category page, or `nil` for an unknown id."
  def group_html(id) do
    case group(id) do
      nil ->
        nil

      group ->
        pages =
          Enum.map_join(group.pages, "\n", fn {name, path, note} ->
            """
            <tr>
              <td><a href="#{path}">#{esc(name)}</a></td>
              <td><code>#{path}</code></td>
              <td>#{esc(note)}</td>
            </tr>
            """
          end)

        layout("#{group.label} — Documentation", """
        <div class="hero small">
          <p class="crumb"><a href="/docs">Documentation</a> / #{esc(group.label)}</p>
          <h1>#{group.glyph} #{esc(group.label)}</h1>
        </div>

        <div class="container">
          <section class="cat">
            <p class="sum">#{esc(group.summary)}</p>
            <table class="ref">
              <thead><tr><th>Page</th><th>Route</th><th>What it does</th></tr></thead>
              <tbody>#{pages}</tbody>
            </table>
          </section>
          <p class="back"><a href="/docs">← All documentation</a> · <a href="/">Samen ERP</a></p>
        </div>
        """)
    end
  end

  @doc "The getting-started guide."
  def getting_started_html do
    layout("Getting started — Documentation", """
    <div class="hero small">
      <p class="crumb"><a href="/docs">Documentation</a> / Getting started</p>
      <h1>Getting started</h1>
    </div>

    <div class="container">
      <section class="cat">
        <h2 class="plain">Run it locally</h2>
        <pre><code>mix deps.get
        MIX_ENV=dev mix ecto.create &amp;&amp; MIX_ENV=dev mix ecto.migrate
        mix phx.server</code></pre>
        <p>Open <a href="http://localhost:4050">http://localhost:4050</a>. <code>/healthz</code> is the
           liveness probe; <code>/readyz</code> turns 200 only when Postgres, the KMS wrapped-DEK store
           and Oban all answer.</p>

        <h2 class="plain">Sign in</h2>
        <p>Create the first workspace at <a href="/signup">/signup</a>, or use the seeded dev identity
           (<code>?org=…</code> selects a workspace while the host is disarmed in dev/test).</p>

        <h2 class="plain">Find a screen</h2>
        <p>The workspace sidebar is the map: <strong>ERP</strong> · <strong>Banking</strong> ·
           <strong>Work</strong> · <strong>Inbox</strong> · <strong>CRM</strong> ·
           <strong>Billing</strong> · <strong>Support</strong> · <strong>Marketing</strong> ·
           <strong>Documents</strong> · <strong>Chat</strong> · <strong>Discover</strong> ·
           <strong>Insights</strong> · <strong>Calendar</strong> · <strong>AI</strong> ·
           <strong>Workspace</strong>. Each group has a page here with the same name and the same links.</p>

        <h2 class="plain">Use the API</h2>
        <p>Keys are minted over the operator Identity mount; a request carries
           <code>Authorization: Bearer &lt;api_key&gt;</code>. <code>GET /api/v1/records</code> is bounded
           (keyset pagination, <code>default_limit 50</code>, <code>max_page_size 200</code>) and
           deny-by-default serialized: a field absent from the resource's JSON:API allowlist is absent
           from every payload. The contract is pinned in <code>api_contract.v1.json</code>.</p>

        <h2 class="plain">Who sees what</h2>
        <p>Everything in the workspace is org-scoped: a cross-org read returns zero rows, structurally.
           Vault-routed (🔒) fields resolve on the caller's plane, so a signed-in operator without a
           reveal grant sees a mask — never plaintext, never a token.</p>
      </section>
      <p class="back"><a href="/docs">← All documentation</a> · <a href="/">Samen ERP</a></p>
    </div>
    """)
  end

  @doc "The 404 body for an unknown `/docs/:id`."
  def not_found_html do
    layout("Not found — Documentation", """
    <div class="hero small">
      <p class="crumb"><a href="/docs">Documentation</a></p>
      <h1>Page not found</h1>
    </div>
    <div class="container">
      <p>There is no documentation page at that address.</p>
      <p class="back"><a href="/docs">← All documentation</a></p>
    </div>
    """)
  end

  defp page_item(name, path, note) do
    """
    <li><a href="#{path}">#{esc(name)}</a><span>#{esc(note)}</span></li>
    """
  end

  defp esc(text), do: Phoenix.HTML.html_escape(text) |> Phoenix.HTML.safe_to_string()

  defp layout(title, body) do
    """
    <!DOCTYPE html>
    <html lang="en"><head>
    <meta charset="utf-8">
    <title>#{esc(title)}</title>
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <meta name="description" content="Samen ERP documentation — features grouped like the workspace sidebar.">
    <style>
      * { box-sizing: border-box; margin: 0; padding: 0; }
      body { font-family: system-ui, -apple-system, sans-serif; background: #f8faf9; color: #1a1a1a; line-height: 1.6; }
      a { color: #0e7c5a; text-decoration: none; }
      a:hover { text-decoration: underline; }
      .hero { background: linear-gradient(135deg, #0e7c5a 0%, #0a5c42 100%); color: white; padding: 48px 20px 36px; text-align: center; }
      .hero.small { padding: 28px 20px 24px; }
      .hero h1 { font-size: 2.1em; font-weight: 700; }
      .hero p { font-size: 1.05em; opacity: 0.9; max-width: 720px; margin: 8px auto 0; }
      .hero a { color: #d1fae5; }
      .container { max-width: 980px; margin: 0 auto; padding: 28px 20px 48px; }
      .section { margin-bottom: 28px; }
      h2 { font-size: 1.15em; color: #0e7c5a; margin: 24px 0 10px; }
      h2 a { color: inherit; }
      h2.plain { margin-top: 0; }
      .grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(260px, 1fr)); gap: 12px; }
      .card { background: white; border: 1px solid #e5e7eb; border-radius: 8px; padding: 16px; display: block; color: inherit; }
      .card:hover { box-shadow: 0 2px 8px rgba(0,0,0,0.08); text-decoration: none; }
      .card h3 { font-size: 0.95em; margin-bottom: 4px; }
      .card p { font-size: 0.82em; color: #6b7280; }
      .cat { background: white; border: 1px solid #e5e7eb; border-radius: 8px; padding: 18px 20px; margin-bottom: 18px; }
      .cat h2 { margin-top: 0; }
      .cat .sum { color: #374151; font-size: 0.9em; margin-bottom: 12px; }
      ul.pages { list-style: none; }
      ul.pages li { padding: 7px 0; border-bottom: 1px solid #f3f4f6; font-size: 0.9em; }
      ul.pages li:last-child { border-bottom: none; }
      ul.pages li span { color: #6b7280; display: block; font-size: 0.88em; }
      table.ref { width: 100%; border-collapse: collapse; font-size: 0.88em; }
      table.ref th, table.ref td { text-align: left; padding: 8px 8px 8px 0; border-bottom: 1px solid #f3f4f6; vertical-align: top; }
      table.ref th { color: #6b7280; font-weight: 600; font-size: 0.85em; text-transform: uppercase; letter-spacing: 0.04em; }
      code { background: #f3f4f6; padding: 1px 5px; border-radius: 4px; font-size: 0.92em; }
      pre { background: #0f172a; color: #e2e8f0; padding: 14px 16px; border-radius: 8px; overflow-x: auto; margin: 10px 0 14px; }
      pre code { background: none; color: inherit; padding: 0; }
      .crumb { font-size: 0.85em; margin-bottom: 6px; }
      .back { margin-top: 26px; font-size: 0.9em; color: #6b7280; }
      .footer { text-align: center; padding: 22px 20px; color: #9ca3af; font-size: 0.85em; border-top: 1px solid #e5e7eb; }
    </style>
    </head>
    <body>
      #{body}
      <div class="footer">
        <p><a href="/">Samen ERP</a> · <a href="/docs">Documentation</a> ·
           <a href="/api/openapi.json">API reference</a> · <a href="/healthz">Health</a></p>
      </div>
    </body></html>
    """
  end
end
