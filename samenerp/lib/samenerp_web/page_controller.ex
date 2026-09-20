defmodule SamenerpWeb.PageController do
  @moduledoc """
  The Samenerp landing + health endpoints (scaffolded by `mix samen.gen.app`).

  `/` renders a plain HTML index linking the inherited framework surfaces;
  `/healthz` returns `ok` (the LIVENESS probe — the BEAM is up).
  `/readyz` is the READINESS probe — it returns 200 only when Postgres, the KMS
  wrapped-DEK store, and Oban all answer (`Samen.Web.Readiness`), else 503.
  """
  use Phoenix.Controller, formats: [:html]

  import Plug.Conn

  def index(conn, _params) do
    html(conn, """
    <!DOCTYPE html>
    <html><head>
    <title>Samen ERP — Open-Source AI-Native ERP System</title>
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <style>
      * { box-sizing: border-box; margin: 0; padding: 0; }
      body { font-family: system-ui, -apple-system, sans-serif; background: #f8faf9; color: #1a1a1a; line-height: 1.6; }
      .hero { background: linear-gradient(135deg, #0e7c5a 0%, #0a5c42 100%); color: white; padding: 60px 20px 40px; text-align: center; }
      .hero h1 { font-size: 2.8em; font-weight: 700; margin-bottom: 8px; }
      .hero p { font-size: 1.2em; opacity: 0.9; max-width: 600px; margin: 0 auto; }
      .hero .badge { display: inline-block; background: rgba(255,255,255,0.2); padding: 4px 12px; border-radius: 20px; font-size: 0.85em; margin-top: 16px; }
      .stats { display: flex; justify-content: center; gap: 40px; padding: 24px 20px; background: white; border-bottom: 1px solid #e5e7eb; flex-wrap: wrap; }
      .stat { text-align: center; }
      .stat .num { font-size: 2em; font-weight: 700; color: #0e7c5a; }
      .stat .label { font-size: 0.85em; color: #6b7280; }
      .container { max-width: 960px; margin: 0 auto; padding: 32px 20px; }
      .section { margin-bottom: 32px; }
      .section h2 { font-size: 1.3em; color: #0e7c5a; margin-bottom: 12px; padding-bottom: 8px; border-bottom: 2px solid #d1fae5; }
      .grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(280px, 1fr)); gap: 12px; }
      .card { background: white; border: 1px solid #e5e7eb; border-radius: 8px; padding: 16px; transition: box-shadow 0.2s; }
      .card:hover { box-shadow: 0 2px 8px rgba(0,0,0,0.08); }
      .card h3 { font-size: 0.95em; color: #1a1a1a; margin-bottom: 4px; }
      .card p { font-size: 0.82em; color: #6b7280; }
      .card .tag { display: inline-block; background: #ecfdf5; color: #065f46; padding: 2px 8px; border-radius: 4px; font-size: 0.75em; font-weight: 500; margin-top: 6px; }
      .inherited { background: white; border: 1px solid #e5e7eb; border-radius: 8px; padding: 20px; }
      .inherited ul { list-style: none; padding: 0; }
      .inherited li { padding: 6px 0; border-bottom: 1px solid #f3f4f6; }
      .inherited li:last-child { border-bottom: none; }
      .inherited a { color: #0e7c5a; text-decoration: none; font-weight: 500; }
      .inherited a:hover { text-decoration: underline; }
      .footer { text-align: center; padding: 24px 20px; color: #9ca3af; font-size: 0.85em; border-top: 1px solid #e5e7eb; margin-top: 32px; }
      .footer a { color: #0e7c5a; text-decoration: none; }
    </style>
    </head>
    <body>        <div class="hero">
        <h1>Samen ERP</h1>
        <p>Open-source, AI-native ERP system for developer-led companies. 47 modules, 697 tests, correct-by-construction.</p>
        <div class="badge">Open Source · Built with Elixir/Phoenix/Ash · AI-Native</div>
        <div style="margin-top:24px">
          <a href="/signup" style="display:inline-block;background:white;color:#0e7c5a;padding:12px 32px;border-radius:8px;text-decoration:none;font-weight:600;font-size:1.1em;margin-right:12px">Get Started Free</a>
          <a href="/login" style="display:inline-block;background:rgba(255,255,255,0.15);color:white;padding:12px 32px;border-radius:8px;text-decoration:none;font-weight:600;font-size:1.1em;border:1px solid rgba(255,255,255,0.3)">Sign In</a>
        </div>
      </div>

      <div class="stats">
        <div class="stat"><div class="num">47</div><div class="label">ERP Modules</div></div>
        <div class="stat"><div class="num">697</div><div class="label">Tests</div></div>
        <div class="stat"><div class="num">308</div><div class="label">Sabotages</div></div>
        <div class="stat"><div class="num">109</div><div class="label">AI Tests</div></div>
      </div>

      <div class="container">
        <!-- Core ERP -->
        <div class="section">
          <h2>📊 Core ERP (E1–E8)</h2>
          <div class="grid">
            <div class="card">
              <h3>Finance — Chart of Accounts</h3>
              <p>Double-entry bookkeeping with account types, cost centers, and multi-currency support.</p>
              <span class="tag">Gl</span>
            </div>
            <div class="card">
              <h3>Finance — Journal Entries</h3>
              <p>General journal with automated posting, reversal, and period-close workflows.</p>
              <span class="tag">Gl</span>
            </div>
            <div class="card">
              <h3>Procurement — AP Invoices</h3>
              <p>Accounts payable with three-way matching, payment scheduling, and vendor management.</p>
              <span class="tag">Ap</span>
            </div>
            <div class="card">
              <h3>Procurement — Purchase Orders</h3>
              <p>Full procurement cycle: RFQ → PO → Goods Receipt → Invoice matching.</p>
              <span class="tag">Ap</span>
            </div>
            <div class="card">
              <h3>Inventory — Stock Management</h3>
              <p>Real-time stock levels, lot tracking, warehouse transfers, and reorder points.</p>
              <span class="tag">Inventory</span>
            </div>
            <div class="card">
              <h3>Manufacturing — Work Orders</h3>
              <p>BOM management, production scheduling, and work-in-progress tracking.</p>
              <span class="tag">Mfg</span>
            </div>
          </div>
        </div>

        <!-- Extended ERP -->
        <div class="section">
          <h2>🚀 Extended ERP (E9–E18)</h2>
          <div class="grid">
            <div class="card">
              <h3>Bank Reconciliation</h3>
              <p>Import bank statements, auto-match transactions, and reconcile accounts.</p>
              <span class="tag">Banking</span>
            </div>
            <div class="card">
              <h3>Landed Costs</h3>
              <p>Allocate freight, duties, and insurance across inventory items proportionally.</p>
              <span class="tag">Inventory</span>
            </div>
            <div class="card">
              <h3>Multi-Currency</h3>
              <p>Currency exchange rates, GL/AP/AR in foreign currencies, gain/loss tracking.</p>
              <span class="tag">Finance</span>
            </div>
            <div class="card">
              <h3>Financial Statements</h3>
              <p>Balance Sheet, P&L, Trial Balance — read-only rollups over the GL.</p>
              <span class="tag">Finance</span>
            </div>
            <div class="card">
              <h3>Project Management</h3>
              <p>Projects, tasks, timesheets, and billable hours tracking.</p>
              <span class="tag">Work</span>
            </div>
            <div class="card">
              <h3>Time Tracking</h3>
              <p>Timesheet entries against tasks with approval workflows.</p>
              <span class="tag">Work</span>
            </div>
            <div class="card">
              <h3>Helpdesk / Support</h3>
              <p>Tickets, SLAs, escalation paths, macros, CSAT surveys, and multi-agent routing.</p>
              <span class="tag">Support</span>
            </div>
            <div class="card">
              <h3>Point of Sale (POS)</h3>
              <p>Storefront config, sessions, payments, and receipt generation.</p>
              <span class="tag">Retail</span>
            </div>
            <div class="card">
              <h3>eCommerce</h3>
              <p>Stores, products, variants, shopping carts, and checkout flows.</p>
              <span class="tag">Retail</span>
            </div>
          </div>
        </div>

        <div class="section">
          <h2>⚡ Extended ERP (E19–E38)</h2>
          <div class="grid">
            <div class="card">
              <h3>Quality Control</h3>
              <p>Quality points, checks, and non-conformance tracking.</p>
              <span class="tag">Mfg</span>
            </div>
            <div class="card">
              <h3>Fleet Management</h3>
              <p>Vehicle registry, fuel tracking, and maintenance scheduling.</p>
              <span class="tag">Assets</span>
            </div>
            <div class="card">
              <h3>Survey &amp; eLearning</h3>
              <p>Survey builder with questions, responses, scoring, and course modules.</p>
              <span class="tag">Learning</span>
            </div>
            <div class="card">
              <h3>Payroll &amp; Leave</h3>
              <p>Payroll runs, leave types, time-off requests, and accruals.</p>
              <span class="tag">HR</span>
            </div>
            <div class="card">
              <h3>Live Chat &amp; Social</h3>
              <p>Real-time chat, social media integration, and engagement tracking.</p>
              <span class="tag">Communication</span>
            </div>
            <div class="card">
              <h3>Marketing Automation</h3>
              <p>Campaign workflows, triggers, A/B testing, and conversion tracking.</p>
              <span class="tag">Marketing</span>
            </div>
            <div class="card">
              <h3>SMS Marketing</h3>
              <p>SMS campaigns with templates, scheduling, and delivery tracking.</p>
              <span class="tag">Marketing</span>
            </div>
            <div class="card">
              <h3>Social Marketing UI</h3>
              <p>Social media post scheduling, publishing, and engagement analytics.</p>
              <span class="tag">Marketing</span>
            </div>
            <div class="card">
              <h3>Multi-Company Consolidation</h3>
              <p>Company groups, account mapping, intercompany transactions, and elimination rules.</p>
              <span class="tag">Finance</span>
            </div>
            <div class="card">
              <h3>Forum &amp; Blog</h3>
              <p>Discussion forums, blog posts, comments, and community features.</p>
              <span class="tag">Community</span>
            </div>
            <div class="card">
              <h3>E-Signatures</h3>
              <p>Document signing workflows with templates, parties, and audit trails.</p>
              <span class="tag">Documents</span>
            </div>
            <div class="card">
              <h3>Appointments</h3>
              <p>Scheduling with appointment types, slots, participants, and booking.</p>
              <span class="tag">Scheduling</span>
            </div>
            <div class="card">
              <h3>Email Marketing</h3>
              <p>Email campaigns with templates, A/B testing, and delivery analytics.</p>
              <span class="tag">Marketing</span>
            </div>
            <div class="card">
              <h3>Planning &amp; Scheduling</h3>
              <p>Resource planning, shift scheduling, and capacity management.</p>
              <span class="tag">Operations</span>
            </div>
            <div class="card">
              <h3>Approvals</h3>
              <p>Multi-level approval workflows with routing rules and escalation.</p>
              <span class="tag">Workflows</span>
            </div>
            <div class="card">
              <h3>IoT Integration</h3>
              <p>Device management, telemetry collection, and automated triggers.</p>
              <span class="tag">Hardware</span>
            </div>
            <div class="card">
              <h3>Document Management</h3>
              <p>File storage, versioning, access control, and retention policies.</p>
              <span class="tag">Documents</span>
            </div>
            <div class="card">
              <h3>CMS / Website Builder</h3>
              <p>Pages, menus, media library, SEO, and content workflows.</p>
              <span class="tag">Web</span>
            </div>
            <div class="card">
              <h3>Studio</h3>
              <p>Custom models, fields, views, and workflows — low-code ERP builder.</p>
              <span class="tag">Low-Code</span>
            </div>
            <div class="card">
              <h3>Expenses</h3>
              <p>Expense reports, receipt capture, approval workflows, and reimbursement.</p>
              <span class="tag">Finance</span>
            </div>
          </div>
        </div>

        <!-- AI & Enterprise -->
        <div class="section">
          <h2>🤖 AI &amp; Enterprise</h2>
          <div class="grid">
            <div class="card">
              <h3>HuggingFace BYOK Integration</h3>
              <p>Bring your own API key. Text generation, summarization, classification, streaming inference, and usage tracking.</p>
              <span class="tag">AI · 109 tests</span>
            </div>
            <div class="card">
              <h3>SSO / SAML</h3>
              <p>Enterprise single sign-on with SAML 2.0, identity providers, and session management.</p>
              <span class="tag">Security</span>
            </div>
            <div class="card">
              <h3>Audit Log</h3>
              <p>Append-only audit chain with tamper-evident hashing and compliance reporting.</p>
              <span class="tag">Compliance</span>
            </div>
            <div class="card">
              <h3>Data Residency</h3>
              <p>Region-aware data storage (US, EU, APAC) with transfer controls.</p>
              <span class="tag">Compliance</span>
            </div>
            <div class="card">
              <h3>White-Label Support</h3>
              <p>Custom branding, logos, colors, domains, and email templates per tenant.</p>
              <span class="tag">SaaS</span>
            </div>
            <div class="card">
              <h3>PII Vault &amp; Crypto-Shred</h3>
              <p>Encrypted PII storage with reveal grants, audit trails, and GDPR crypto-shred.</p>
              <span class="tag">Privacy</span>
            </div>
          </div>
        </div>

        <!-- Infrastructure -->
        <div class="section">
          <h2>🏗️ Infrastructure</h2>
          <div class="grid">
            <div class="card">
              <h3>Production Deployment</h3>
              <p>Docker, docker-compose, Fly.io, AWS ECS, Kubernetes — deploy anywhere.</p>
              <span class="tag">DevOps</span>
            </div>
            <div class="card">
              <h3>API Rate Limiting</h3>
              <p>Free / Pro / Enterprise tiers with token bucket rate limiting.</p>
              <span class="tag">SaaS</span>
            </div>
            <div class="card">
              <h3>Monitoring &amp; Alerting</h3>
              <p>Sentry error tracking, OpenTelemetry tracing, and structured logging.</p>
              <span class="tag">Observability</span>
            </div>
            <div class="card">
              <h3>Backup &amp; Recovery</h3>
              <p>Automated database backups, retention policies, and restore procedures.</p>
              <span class="tag">DevOps</span>
            </div>
            <div class="card">
              <h3>API Documentation</h3>
              <p>OpenAPI 3.0 spec, auto-generated from AshJsonApi resources.</p>
              <span class="tag">Developer</span>
            </div>
            <div class="card">
              <h3>Security Hardening</h3>
              <p>CSP headers, HSTS, XSS protection, and secure cookie configuration.</p>
              <span class="tag">Security</span>
            </div>
          </div>
        </div>

        <!-- Inherited -->
        <div class="section">
          <h2>🔗 Inherited from Samen Web</h2>
          <div class="inherited">
            <ul>
              <li><a href="/billing">Billing → Overview</a></li>
              <li><a href="/billing/invoices">Billing → Invoices</a></li>
              <li><a href="/notifications">Notifications → Inbox</a></li>
              <li><a href="/operator/accounts">Operator → Accounts</a></li>
              <li><a href="/healthz">Health Check</a></li>
            </ul>
          </div>
        </div>
      </div>

      <div class="footer">
        <p><a href="/signup">Sign Up</a> · <a href="/login">Sign In</a> · <a href="https://github.com/kubeworkz/samen-erp">GitHub</a> · <a href="https://ckluis.github.io/samen/">Design Story</a> · <a href="https://samenerp.kubeworkz.io/healthz">Health</a></p>
        <p style="margin-top:8px">Samen ERP — The open-source, AI-native ERP for developer-led companies</p>
      </div>
    </body></html>
    """)
  end

  def healthz(conn, _params) do
    send_resp(conn, 200, "ok")
  end

  def readyz(conn, _params) do
    case Samen.Web.Readiness.check(repo: Samenerp.Repo) do
      {:ok, _checks} ->
        send_resp(conn, 200, "ready")

      {:error, checks} ->
        body =
          Enum.map_join(checks, "\n", fn
            {component, :ok} -> "#{component}: ok"
            {component, {:error, _reason}} -> "#{component}: FAIL"
          end)

        send_resp(conn, 503, "not ready\n" <> body)
    end
  end
end
