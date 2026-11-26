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
  not an illustration of it. A DETAIL page is the one exception to "link it":
  it carries the `:id` a reader arrives with, so it is listed as its route
  template (code text, never an href) — a template URL has no record to open and
  would land on the page's not-found state. Content is data (`groups/0`) with one
  renderer, so growing the docs is adding a map — no template surgery.

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
        {"Expense Reports", "/erp/expense_reports",
         "Employee claims with their totals and status; submit → approve → settle is the report's own " <>
           "gated chain."},
        {"Expense Categories", "/erp/expense_categories",
         "The policy rows a claim is filed under: the account it posts to, whether a receipt is " <>
           "required, and the per-claim cap."},
        {"Corporate Cards", "/erp/corporate_cards",
         "The card register behind card claims: name, last four digits, cardholder and active flag."},
        {"AP capture", "/erp/ap-capture", "Capture an incoming invoice document into an AP invoice."},
        {"AP payments", "/erp/ap-payments",
         "The payment run. A pending reversal of a payment needs a DIFFERENT admin's decision — the nav " <>
           "badge counts what is waiting on someone else."},
        {"AP payment run", "/erp/ap-payments/:id",
         "One immutable run record: who requested it, who approved, rejected or cancelled it and when, the " <>
           "bill snapshot that was reviewed, and the remittance CSV stored at approval. The database trigger " <>
           "refuses a self-approval, a rewritten snapshot and every DELETE, so this page reads evidence rather " <>
           "than a process-memory summary. A reversal of a paid run is its own durable row, requested by one " <>
           "admin and approved by another; a run from another org is indistinguishable from a missing one."},
        {"AP aging", "/erp/ap-aging", "Open payables bucketed by age."},
        {"AP approval", "/erp/ap-approval",
         "The AP chain's approval policy: the generic approval-policy row for the ap_invoice approve action."},
        {"AR receipts", "/erp/ar-receipts", "Customer receipts applied against invoices."},
        {"AR aging", "/erp/ar-aging", "Open receivables bucketed by age, sourced from this host's Billing invoices."},
        {"AR settings", "/erp/ar-settings", "The AR control row (terms and defaults)."},
        {"Journal approval", "/erp/journal-approval",
         "The org's journal-approval control. Changing the control itself is a two-admin act."},
        {"Reconciliation", "/erp/reconciliation", "Ledger-versus-bank reconciliation over the Banking bridge."},
        {"Payroll mappings", "/erp/payroll-mappings", "Which GL accounts a payroll run posts to."},
        {"Grants", "/grants",
         "The bounded grants index (personnel grants behind reveals) — grants never unlock the AI egress class."},
        {"Grant report", "/grants/:id",
         "One grant's personnel report: tenant names in the clear, operator names ••••, and the table and its " <>
           "CSV/JSON downloads all inside the grant's org scope. Without an HR namespace the page says so and " <>
           "shows only the bounded employment facts (employee id, effort, effective date)."},
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
        {"Account detail", "/banking/accounts/:id",
         "One account with its bounded statement ledger, CSV/OFX statement import, ranked match suggestions " <>
           "and the guarded Match action. Matching goes through the resource's own action, never a " <>
           "surface-local write: no double match, no match to a voided entry, and the cash leg must equal " <>
           "the statement amount within a cent. Suggestions are advisory; the user confirms through the form."},
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
        {"Task detail", "/work/tasks/:id",
         "One task's metadata and its direct subtasks. The status select matches a bounded enum, so client " <>
           "input never mints an atom, and write affordances are offered on the tenant plane only. No PII."},
        {"Projects", "/work/projects", "Projects that group tasks and carry the billable context."},
        {"Timeline", "/work/timeline", "Tasks on a time axis, multi-anchor."},
        {"Tree", "/work/tree",
         "The same tasks as a parent/child hierarchy over the self-referential Task.parent_id — depth-bounded, " <>
           "cycle-safe and org-scoped at every level. A truncated node's ?focus=<id> link re-roots the walk as a " <>
           "plain GET, so it descends without JavaScript."}
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
        {"Company detail", "/crm/companies/:id",
         "One company, with Overview, Activity and Deals tabs. The company itself carries no PII, but the " <>
           "people sub-list on Overview resolves through PiiResolution (tenant clear, operator ••••), and the " <>
           "activity composer is tenant-plane only — an operator does not author into a tenant's timeline. " <>
           "Edit, and a delete behind its confirmation interlock, write through the kernel's org scope and " <>
           "role checks."},
        {"Contacts", "/crm/contacts", "People at those companies (PII fields are vault-routed)."},
        {"Contact detail", "/crm/contacts/:id",
         "One contact, with Overview, Activity and Deals tabs. Full name, emails and phones are vault-routed " <>
           "and resolved on the caller's plane: the org reads its own person in the clear, an operator " <>
           "without a grant sees ••••, and the activity composer is hidden there. Edit submits through the " <>
           "vault change path, never a raw column."},
        {"Gallery", "/crm/gallery", "The visual card view over the same records."},
        {"Pipeline", "/crm/pipeline", "Deals by stage."},
        {"Calendar", "/crm/calendar", "Dated CRM activity."},
        {"Dashboard", "/crm/dashboard", "The workspace home: the CRM read every mount lands on."},
        {"Mailbox", "/crm/mailbox",
         "Two-way email sync: inbound threads anchor to the RIGHT person (matched over vaulted addresses, " <>
           "org-pinned) and outbound lands on the same timeline."},
        {"Sequences", "/crm/sequences",
         "Multi-step outreach enrollment with honest step status — a blocked step never reads as delivered."},
        {"CSV import", "/csv/import/company",
         "Import rows through the resource's governed create action — every row passes the same write guard and vault " <>
           "change as the UI, and a bad column mapping fails the whole file before any write. Deny-by-default onto " <>
           "this host's CRM resources."},
        {"CSV export", "/csv/export/company",
         "Download a CSV of a CRM resource's public columns only: vaulted cells resolve on the caller's plane, so an " <>
           "operator without a grant gets •••• — the same pixels the UI shows. A resource outside the domain 404s."}
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
        {"Invoice detail", "/billing/invoices/:id",
         "The record behind the invoices list: label, status and amount, the line items as stored, and the " <>
           "provider's tax breakdown when one exists (absent means the provider computed no tax — never a " <>
           "fabricated zero). Status moves only through a closed transition table the server re-checks, so a " <>
           "hand-crafted transition event is a no-op."},
        {"Dunning", "/billing/dunning", "Failed-payment recovery runs."},
        {"Plans", "/billing/plans", "The plans a customer can be on."},
        {"Plan detail", "/billing/plans/:id",
         "One plan: interval, primary price, its real feature keys as chips (no default feature is " <>
           "invented) and its price rows. Enable/disable is the same sanctioned toggle as the list row, and " <>
           "Archive soft-archives the plan, so it leaves the live list and can be restored from the archived " <>
           "view."},
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
        {"Ticket detail", "/support/tickets/:id",
         "The ticket's conversation thread and metadata. Message bodies and agent names are vault-routed and " <>
           "plane-resolved; the reply composer writes through the vault change (absent on the operator plane, " <>
           "where the write guard refuses it), and the status select matches a bounded enum, so client input " <>
           "never mints an atom. A KB panel suggests related articles from the ticket subject — the message " <>
           "body is not fed to the AI plane."},
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
        {"Campaign detail", "/marketing/campaigns/:id",
         "Compose and send against one campaign: pick a template and a segment, then send to the segment. " <>
           "Consent and suppression are enforced at the send seam — a suppressed subscriber gets no send row " <>
           "and no job, and the page shows that refusal per recipient. Recipient emails resolve on the " <>
           "caller's plane, and the send itself carries only the opaque subscriber id."},
        {"Segments", "/marketing/segments", "The saved audiences a campaign targets."},
        {"Segment detail", "/marketing/segments/:id",
         "One segment: its filter criteria, its subscriber count, and a bounded audience preview resolved " <>
           "through PiiResolution. Edit and an Archive that soft-archives the row (restorable from the " <>
           "list's archived view) are admin-gated by the kernel."},
        {"Leads", "/marketing/leads", "Captured leads feeding the CRM."},
        {"Lead detail", "/marketing/leads/:id",
         "A lead IS a CRM person, so this is the leads lens's read-only twin: plane-resolved facts and a " <>
           "jump to the full CRM contact page, where the CRUD lives. No edit modal and no delete — the lens " <>
           "has always been read-only because those writes belong to the CRM surfaces."},
      ]
    },
    %{
      id: "documents",
      label: "Documents",
      glyph: "📄",
      summary:
        "Pages (the Docs scope: titled pages, untitled notes, typed blocks and [[links]] between them) and " <>
          "Files (the upload chokepoint — a file is quarantined until a clean scan promotes it, and " <>
          "a storage_key is minted only by the upload seam).",
      pages: [
        {"Pages", "/pages", "Write and browse pages; secure bodies and blocks are vault-routed."},
        {"Page editor", "/pages/:id",
         "The block editor: each block is one textarea and every structural intent (split, merge, indent, " <>
           "move) is a server event carrying a bounded token, so stored text is never HTML. Vaulted block " <>
           "text renders as the mask on a masked plane and a masked write is refused rather than faked; every " <>
           "write carries the revision the client last saw, so a stale tab gets a conflict banner instead of " <>
           "overwriting, and moving text out of the vault is an admin form that posts a reason."},
        {"Trash", "/pages/trash",
         "Deleted pages, still findable once the undo notice is gone: a delete is a soft archive, and Restore brings " <>
           "the page back with its blocks, children and [[links]] in one transaction. An archived page in another " <>
           "org is simply absent."},
        {"Files", "/files", "Upload and download, with the quarantine → promotion lifecycle and retention."},
        {"File preview", "/files/:id",
         "One file: the plane-resolved filename and, for an active file on the tenant plane, an inline view " <>
           "of images and text. A quarantined file is not previewable, and an operator cannot pull a " <>
           "tenant's bytes without a reveal grant — the byte-serve route re-enforces both gates server-side. " <>
           "Read-only."}
      ]
    },
    %{
      id: "chat",
      label: "Chat",
      glyph: "💬",
      summary:
        "Internal conversations. Reads are org-scoped and keyset-bounded; attachments go through the same " <>
          "upload chokepoint as Files.",
      pages: [
        {"Conversations", "/chat", "Channels and threads for this workspace."},
        {"Conversation", "/chat/:id",
         "The realtime room. Messages broadcast as id-only envelopes and are re-read for each viewer's " <>
           "scope, so the same broadcast renders clear for a tenant and •••• for an operator; presence tracks " <>
           "the party and handle, never a message body."}
      ]
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
      pages: [
        {"AI workspace", "/ai", "Ask, draft and propose — writes still go through approvals."},
        {"Agent run", "/ai/agents/:id",
         "One agent run: progress, the bounded turn log and the plane-resolved transcript, plus cancel and the " <>
           "approve/reject card for a run parked awaiting approval. The card passes through to the approvals " <>
           "engine, so the requester can never approve their own proposal, the approver must be a real member " <>
           "of the run's org, and the card shows arg key names and a digest — never a value."}
      ]
    },
    %{
      id: "workspace",
      label: "Workspace",
      glyph: "⚙️",
      summary:
        "Workspace-level administration: the settings tabs (profile, API keys, security, invitations, the " <>
          "two approval queues, the AI key), the automation builder, and feature flags.",
      pages: [
        {"Settings", "/settings", "Your own profile — the one screen where you edit your own vaulted name, email and handle."},
        {"API keys", "/settings/api-keys",
         "Mint, list and revoke this org's API keys. The raw key is shown EXACTLY ONCE (only a token digest is " <>
           "stored), and minted authority is capped by the minter's own role ceiling."},
        {"Security", "/settings/security",
         "Impersonation sessions and the reveal ledger, read-only. Host-owned auth (passwords, 2FA, login " <>
           "sessions) renders as the identity provider's, never as a control this page does not have."},
        {"Invitations", "/settings/invitations",
         "Invite a teammate by email with a role, see pending/accepted/revoked/expired invites, and revoke a " <>
           "pending one — the invite link is shown once, the token is stored only as a digest."},
        {"Approvals", "/settings/approvals",
         "The pending approval-policy changes an admin can decide: the AP policy update surfaced in one queue, " <>
           "with its proposed thresholds and scope, so a distinct admin can act on it."},
        {"Reveal approvals", "/settings/reveal-approvals",
         "Pending PII reveal requests that a SECOND party approves (minting the time-boxed grant) or denies; " <>
           "the read-only ledger of who unmasked what stays on Security."},
        {"Hugging Face key", "/settings/huggingface",
         "Bring-your-own HuggingFace key for the AI plane: connect, validate, revoke and read usage. Keys are " <>
           "encrypted on input and never stored raw."},
        {"Automation", "/automation", "Workflow builder: triggers, conditions and actions."},
        {"Feature flags", "/flags", "Flag admin over this host's FeatureFlag rows."},
        {"Status page", "/status",
         "The public, unauthenticated fleet status page: current status only, token-blind, and empty until an app is " <>
           "opted in to publish. Rate-limited per remote IP."}
      ]
    }
  ]

  @guides [
    %{
      id: "getting-started",
      title: "Getting started",
      summary: "Run samenerp locally, sign in, and find your way around the workspace."
    },
    %{
      id: "api-reference",
      title: "API reference",
      summary:
        "Every operation, server and schema in the OpenAPI 3.0 document, rendered — generated from the " <>
          "same spec that /api/openapi.json serves."
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
         #{length(@groups)} categories, #{page_count()} pages. Every link opens the live screen;
         detail pages are listed by their route template, because they open from a record in
         their list rather than on their own.</p>
    </div>

    <div class="container">
      <div class="section">
        <h2 class="plain">Start here</h2>
        <div class="grid">
          #{guides}
          <a class="card" href="/api/openapi.json">
            <h3>Raw OpenAPI JSON</h3>
            <p>The machine contract the rendered API reference is generated from.</p>
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
            page =
              if template?(path),
                do: esc(name),
                else: ~s(<a href="#{path}">#{esc(name)}</a>)

            """
            <tr>
              <td>#{page}</td>
              <td><code>#{esc(path)}</code></td>
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
            #{detail_hint(group)}
            <table class="ref pages">
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
        <p>Keys are minted at <a href="/settings/api-keys">/settings/api-keys</a> (tenant plane, admin-gated)
           over the operator Identity mount; a request carries
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

  @doc """
  The rendered API reference.

  Built from `Samenerp.ApiDocs.generate_spec/0` — the SAME document
  `/api/openapi.json` serves — so the readable page and the machine contract
  cannot drift: an operation added to the spec appears here, and the guard
  asserts this page carries every operation the spec lists.
  """
  def api_reference_html do
    spec = Samenerp.ApiDocs.generate_spec()
    info = map_get(spec, :info, %{})
    servers = map_get(spec, :servers, [])
    schemas = spec |> map_get(:components, %{}) |> map_get(:schemas, %{})

    operations =
      for {path, item} <- map_get(spec, :paths, %{}),
          {method, operation} <- item,
          method in [:get, :post, :put, :patch, :delete],
          do: {method, path, operation}

    operations = Enum.sort_by(operations, fn {method, path, _op} -> {path, method} end)

    layout("API reference — Documentation", """
    <div class="hero small">
      <p class="crumb"><a href="/docs">Documentation</a> / API reference</p>
      <h1>API reference</h1>
      <p>#{esc(map_get(info, :title, "API"))} v#{esc(map_get(info, :version, "—"))} —
         #{esc(map_get(info, :description, ""))}</p>
    </div>

    <div class="container">
      <section class="cat">
        <p class="sum">Generated from the same OpenAPI 3.0 document served at
           <a href="/api/openapi.json">/api/openapi.json</a>, so this page cannot describe a
           different API than the machine contract. Clients take the raw document from that URL.</p>

        <h2 class="plain">Servers</h2>
        <table class="ref">
          <thead><tr><th>URL</th><th>Description</th></tr></thead>
          <tbody>#{Enum.map_join(servers, "\n", &server_row/1)}</tbody>
        </table>

        <h2>Authentication</h2>
        <p>#{auth_line(spec)}</p>

        <h2>Operations</h2>
        <table class="ref">
          <thead><tr><th>Method</th><th>Path</th><th>Summary</th><th>Responses</th></tr></thead>
          <tbody>#{Enum.map_join(operations, "\n", &operation_row/1)}</tbody>
        </table>

        <h2>Schemas</h2>
        <table class="ref">
          <thead><tr><th>Schema</th><th>Fields</th></tr></thead>
          <tbody>#{Enum.map_join(Enum.sort_by(schemas, fn {name, _schema} -> name end), "\n", &schema_row/1)}</tbody>
        </table>
      </section>
      <p class="back"><a href="/docs">← All documentation</a> ·
         <a href="/api/openapi.json">raw OpenAPI JSON</a></p>
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

  defp server_row(server) do
    """
    <tr><td><code>#{esc(map_get(server, :url, ""))}</code></td><td>#{esc(map_get(server, :description, ""))}</td></tr>
    """
  end

  defp auth_line(spec) do
    schemes = spec |> map_get(:components, %{}) |> map_get(:securitySchemes, %{})

    lines =
      Enum.map(schemes, fn {name, scheme} ->
        "#{name}: #{map_get(scheme, :type, "?")}/#{map_get(scheme, :scheme, "?")} " <>
          "(#{map_get(scheme, :bearerFormat, "token")})"
      end)

    case lines do
      [] ->
        "No security scheme is declared in the document."

      lines ->
        enc = Enum.map_join(lines, " · ", &esc/1)
        "#{enc}. A request carries <code>Authorization: Bearer &lt;api_key&gt;</code>."
    end
  end

  defp operation_row({method, path, operation}) do
    verb = method |> to_string() |> String.upcase()
    tag = operation |> map_get(:tags, []) |> List.first() || "Other"
    summary = map_get(operation, :summary, "")

    responses =
      operation
      |> map_get(:responses, %{})
      |> Enum.sort_by(fn {code, _response} -> code end)
      |> Enum.map_join(" · ", fn {code, response} ->
        "#{code} #{map_get(response, :description, "")}"
      end)

    """
    <tr class="op" data-op="#{esc("#{verb} #{path}")}">
      <td><code>#{verb}</code></td>
      <td><code>#{esc(path)}</code></td>
      <td><strong>#{esc(tag)}</strong><br>#{esc(summary)}#{request_body(operation)}</td>
      <td>#{esc(responses)}</td>
    </tr>
    """
  end

  defp request_body(operation) do
    case map_get(operation, :requestBody, nil) do
      nil ->
        ""

      body ->
        required = if map_get(body, :required, false), do: " (required)", else: ""

        schema =
          body
          |> map_get(:content, %{})
          |> Map.values()
          |> List.first()
          |> case do
            nil -> nil
            content -> map_get(content, :schema, nil)
          end

        "<br><span class=\"muted\">body#{required}: #{esc(schema_label(schema))}</span>"
    end
  end

  defp schema_label(nil), do: "—"
  defp schema_label(%{"$ref" => ref}), do: ref |> String.split("/") |> List.last()
  defp schema_label(schema) when is_map(schema), do: to_string(map_get(schema, :type, "object"))
  defp schema_label(_schema), do: "—"

  defp schema_row({name, schema}) do
    fields =
      schema
      |> map_get(:properties, %{})
      |> Enum.sort_by(fn {field, _spec} -> field end)
      |> Enum.map_join(", ", fn {field, spec} -> "#{field} (#{schema_label(spec)})" end)

    """
    <tr data-schema="#{esc(name)}"><td><code>#{esc(name)}</code></td><td>#{esc(fields)}</td></tr>
    """
  end

  # The spec mixes atom keys (the Elixir map) with string keys (as parsed from
  # JSON); read either, so a spec that starts life as a decoded document still
  # renders through the same page.
  defp map_get(map, key, default) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, to_string(key), default)
    end
  end

  defp map_get(_map, _key, default), do: default

  # A detail page is reached THROUGH a record, so the catalog carries its route as
  # a TEMPLATE. Rendering that as an href would break the page's one promise — every
  # link opens the live screen — because `/crm/contacts/:id` without a record answers
  # the detail page's not-found state. So a template renders as code text, naming the
  # page it belongs to, and the href guard refutes any template that reaches an href.
  defp page_item(name, path, note) do
    if template?(path) do
      """
      <li><span>#{esc(name)} — <code>#{esc(path)}</code></span><span>#{esc(note)}</span></li>
      """
    else
      """
      <li><a href="#{path}">#{esc(name)}</a><span>#{esc(note)}</span></li>
      """
    end
  end

  defp template?(path), do: String.contains?(path, ":id")

  # Says why a detail row is not a link, instead of leaving the reader to guess.
  defp detail_hint(group) do
    if Enum.any?(group.pages, fn {_name, path, _note} -> template?(path) end) do
      """
      <p class="sum">Detail pages open from a record in their list; their routes are templates,
         so they are shown as code rather than as links.</p>
      """
    else
      ""
    end
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
      /* On a wide screen the page name is the row's label, not a sentence: "Company
         detail" must not break into "Company / detail" while the route sits whole
         beside it, so the first column shrinks to fit and What-it-does takes the rest.
         Narrow screens keep the default: wrapping the name is far better than squeezing
         the note into a column two words wide. */
      @media (min-width: 700px) {
        table.ref th:first-child, table.ref td:first-child { width: 1%; white-space: nowrap; }
      }
      /* Below 700px a three-column table cannot hold a page name, a route and a
         paragraph: the note column collapsed to ~88px and wrapped one or two words
         per line. Each category row becomes its own block instead — name, route,
         then the note at full width, with no horizontal scrolling. */
      @media (max-width: 699px) {
        table.ref.pages thead { display: none; }
        table.ref.pages tr { display: block; padding: 12px 0; border-bottom: 1px solid #e5e7eb; }
        table.ref.pages td { display: block; border: 0; padding: 0 0 4px; }
        table.ref.pages td:first-child { font-weight: 600; padding-top: 0; }
        table.ref.pages td:last-child { padding-bottom: 0; color: #374151; }
      }
      code { background: #f3f4f6; padding: 1px 5px; border-radius: 4px; font-size: 0.92em; }
      pre { background: #0f172a; color: #e2e8f0; padding: 14px 16px; border-radius: 8px; overflow-x: auto; margin: 10px 0 14px; }
      pre code { background: none; color: inherit; padding: 0; }
      .crumb { font-size: 0.85em; margin-bottom: 6px; }
      .back { margin-top: 26px; font-size: 0.9em; color: #6b7280; }
      .footer { text-align: center; padding: 22px 20px; color: #9ca3af; font-size: 0.85em; border-top: 1px solid #e5e7eb; }
      .muted { color: #6b7280; }
    </style>
    </head>
    <body>
      #{body}
      <div class="footer">
        <p><a href="/">Samen ERP</a> · <a href="/docs">Documentation</a> ·
           <a href="/docs/api-reference">API reference</a> · <a href="/healthz">Health</a></p>
      </div>
    </body></html>
    """
  end
end
