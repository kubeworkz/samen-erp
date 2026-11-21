# Samen ERP Competitive Analysis

> **Status note (2026-11-21).** The Samen column follows the README's live-vs-shell
> split, not an aspirational feature list. "Core only" means the kernel ships but the
> host key flow or UI is unwired; "shell only" means the module is compile-listed but
> unmounted. Competitor cells, cost figures and market sizing are estimates, not
> audited figures.

## Executive Summary

This analysis compares Samen ERP against major ERP competitors across 12 dimensions. Samen has an **estimated cost advantage** and a **kernel-level lead** in PII governance and AI plumbing, but those are not the same as shipped AI or enterprise features; it loses on **maturity**, **ecosystem**, and **support**.

## Competitive Landscape

> **Market-figure basis (2026-11-21).** Revenue and headcount are rounded, directional
> estimates for segmentation, not audited product-line disclosures. Public-company
> reference points: [Oracle](https://investor.oracle.com/),
> [SAP](https://www.sap.com/investors/en.html),
> [Microsoft](https://www.microsoft.com/en-us/investor),
> [Intuit](https://investors.intuit.com/), and
> [Xero](https://www.xero.com/investors/); those groups generally do not break out the
> named product line. Headcount is not a consistent denominator — some rows are
> product estimates, others group-level proxies. Odoo, Frappe/ERPNext, Katana, Mrpeasy
> and FreshBooks are private/open-source planning estimates. Recheck before external use.

### Tier 1: Enterprise ERP (Not Our Market)
| Competitor | Revenue (est.) | Employees (est.) | Target |
|---|---|---|---|
| NetSuite (Oracle) | $3B+ | 10,000+ | Mid-market to enterprise |
| SAP Business One | $5B+ | 100,000+ (SAP group total) | Mid-market |
| Microsoft Dynamics | $10B+ | 200,000+ (Microsoft group total) | Enterprise |

### Tier 2: Mid-Market ERP (Our Competition)
| Competitor | Revenue (est.) | Employees (est.) | Target |
|---|---|---|---|
| Odoo | $500M+ | 5,000+ | SMB to mid-market |
| ERPNext | $50M+ | 500+ | Small business |
| Katana MRP | $50M+ | 500+ | Manufacturing |
| Mrpeasy | $20M+ | 200+ | Manufacturing |

### Tier 3: Accounting Only (Partial Overlap)
| Competitor | Revenue (est.) | Employees (est.) | Target |
|---|---|---|---|
| QuickBooks | $5B+ | 10,000+ | Small business |
| Xero | $1B+ | 5,000+ | Small business |
| FreshBooks | $100M+ | 500+ | Freelancers |

## Detailed Comparison

### 1. Core ERP Features

| Feature | Samen | NetSuite | Odoo | ERPNext |
|---|---|---|---|---|
| General Ledger | ✅ | ✅ | ✅ | ✅ |
| AP/AR | ✅ | ✅ | ✅ | ✅ |
| Inventory | ✅ | ✅ | ✅ | ✅ |
| Manufacturing | ✅ | ✅ | ✅ | ✅ |
| HR | ✅ | ✅ | ✅ | ✅ |
| CRM | ✅ | ✅ | ✅ | ✅ |
| Project Management | ✅ | ✅ | ✅ | ✅ |
| eCommerce | ❌ | ✅ | ✅ | ✅ |

**Verdict: Parity on shipped ERP scopes** — Finance, Inventory, Procurement, SalesOrder,
Manufacturing, HR and CRM/Billing/Support are live; eCommerce is not a shipped scope.

### 2. AI Integration (kernel vs host)

| Feature | Samen | NetSuite | Odoo | ERPNext |
|---|---|---|---|---|
| AI Text Generation | ⚠️ Core only | ❌ Limited | ❌ | ❌ |
| AI Embeddings | ⚠️ Keyless only | ❌ | ❌ | ❌ |
| AI in Workflows | ⚠️ Kernel verbs only | ⚠️ Oracle AI | ❌ | ❌ |
| Custom AI Models | ⚠️ Registry only | ❌ | ❌ | ❌ |
| AI Usage Tracking | ⚠️ Needs PromptLog writes | ❌ | ❌ | ❌ |

**Verdict: Kernel lead, host gap** — the tested AI plane (BYOK crypto, token validation,
completion/SSE, no-PII-egress chokepoint, kernel verbs) is real, but the
`/settings/huggingface` key flow, daily sweep, prompt-log writes, HF embeddings and
in-workflow UI are not wired. Not a shipping AI feature yet.

### 3. Deployment Options

| Option | Samen | NetSuite | Odoo | ERPNext |
|---|---|---|---|---|
| Self-Hosted | ✅ | ❌ | ✅ | ✅ |
| Cloud SaaS | ⚠️ Deployable, not operated | ✅ | ✅ | ✅ |
| Docker/K8s | ⚠️ Docker only | ❌ | ✅ | ✅ |
| One-Click Deploy | ⚠️ Scripted | N/A | ✅ | ✅ |
| Data Residency | ❌ US-only | ✅ | ⚠️ | ⚠️ |

**Verdict: Partial** — Docker/Compose and deploy files ship; Kubernetes is a guide,
not manifests. There is no operated hosted SaaS, no one-click deploy and no
per-tenant residency (US-only).

### 4. Security & Compliance

| Feature | Samen | NetSuite | Odoo | ERPNext |
|---|---|---|---|---|
| SOC2 | ❌ Not certified | ✅ | ✅ | ❌ |
| GDPR | ⚠️ Control posture | ✅ | ✅ | ⚠️ |
| PII Vaulting | ✅ Advanced | ✅ Basic | ⚠️ | ❌ |
| Crypto-Shred | ✅ | ❌ | ❌ | ❌ |
| Audit Log | ✅ Hash-chained (no export) | ✅ | ✅ | ✅ |
| 2FA/MFA | ✅ TOTP | ✅ | ✅ | ✅ |
| SSO/SAML | ❌ Shell only | ✅ | ✅ | ⚠️ |

**Verdict: Partial win** — PII vaulting, crypto-shred, hash-chained audit and
audit-on-write are live; SSO/SAML and customer audit-log export are shells, and the
compliance posture is controls, not certification or an audit.

### 5. Developer Experience

| Feature | Samen | NetSuite | Odoo | ERPNext |
|---|---|---|---|---|
| API | ✅ REST/JSON:API | ⚠️ REST only | ⚠️ RPC | ✅ REST |
| OpenAPI Spec | ⚠️ 2 paths | ❌ | ❌ | ⚠️ |
| SDKs | ❌ (coming) | ⚠️ SuiteScript | ⚠️ Python | ⚠️ Python |
| Webhooks | ✅ | ⚠️ | ✅ | ✅ |
| Custom Code | ✅ Elixir | ⚠️ SuiteScript | ✅ Python | ✅ Python |
| Code Quality | ✅ Verified | ⚠️ | ⚠️ | ⚠️ |

**Verdict: Partial** — modern stack and verified codebase; the served OpenAPI
document covers only auth-login and AI-generate today, not a full API reference.

### 6. Cost Structure (estimated)

> **Pricing basis (checked 2026-11-21, USD).** License figures use vendor-published
> prices where available; the remaining ranges are planning estimates, not vendor
> quotes or benchmarks.
>
> - **Odoo** — Standard is US$24.90/user/month on annual billing for the first 12
>   months, then US$31.10; Odoo Online hosting and support are included.
>   [Odoo pricing](https://www.odoo.com/pricing?currency=USD)
> - **ERPNext** — GPL-3.0; no license fee. Hosting, implementation and paid support
>   are separate. [ERPNext pricing](https://frappe.io/erpnext/pricing)
> - **NetSuite** — Oracle publishes no list price and prices by annual quote; the
>   `$1,000+/mo` entry is a third-party planning range (reported US$999–$2,000/mo),
>   not an Oracle quote. [Oracle NetSuite ERP](https://www.netsuite.com/portal/products/erp.shtml)
>   · [reported range](https://ensurva.com/us/software-pricing/netsuite)
> - **Samen** — self-hosted OSS; the `$0-$6K` Year 1 range is a hosting/ops
>   allowance, with staff time excluded.
>
> Implementation, NetSuite premium-support and Year 1 ranges are internal planning
> envelopes as of 2026-11-21, not vendor quotes. Samen excludes staff time, so the
> comparison is directional. Vendor prices vary by country, currency, user count,
> modules, term and discounts.

| Cost (estimated, USD) | Samen | NetSuite | Odoo | ERPNext |
|---|---|---|---|---|
| License | Free (OSS) | $1,000+/mo (quote) | $24.90–$31.10/user/mo | Free (GPL-3.0) |
| Implementation | DIY | $10K-$100K | $5K-$50K | DIY |
| Hosting | Self-hosted | Included | Included (Odoo Online) | Self-hosted |
| Support | Community | $2K+/mo (premium allowance) | Included | Community |
| Total Year 1 | $0-$6K | $24K-$200K | $12K-$100K | $0-$12K |

**Verdict: Estimated major advantage** — roughly 4x–30x lower Year 1 cost than
NetSuite's reported range on the table's assumptions; not a measured benchmark.

### 7. Customization

| Feature | Samen | NetSuite | Odoo | ERPNext |
|---|---|---|---|---|
| Custom Fields | ✅ Dynamic | ✅ | ✅ | ✅ |
| Custom Workflows | ✅ Full Elixir | ⚠️ SuiteScript | ✅ Python | ✅ Python |
| White-Label | ❌ Shell only | ❌ | ✅ | ✅ |
| Custom Themes | ❌ Not shipped | ❌ | ✅ | ✅ |
| Custom Modules | ✅ Full code | ⚠️ Limited | ✅ | ✅ |

**Verdict: Partial** — custom fields/workflows/modules and code access are live;
white-label branding and a theme layer are not shipped.

### 8. Ecosystem & Integrations

| Feature | Samen | NetSuite | Odoo | ERPNext |
|---|---|---|---|---|
| App Marketplace | ❌ | ✅ 100+ apps | ✅ 30K+ modules | ✅ 1K+ apps |
| Zapier | ❌ (coming) | ✅ | ✅ | ⚠️ |
| Stripe | ⚠️ Adapter, unconfigured | ✅ | ✅ | ✅ |
| Email Providers | ⚠️ 3 adapters, unconfigured | ✅ | ✅ | ✅ |
| Accounting | ⚠️ Basic | ✅ Advanced | ✅ | ✅ |

**Verdict: Loss** — ecosystem is immature; Stripe is a tested adapter with no live
host wiring, and the three ESP adapters ship but no host wires a live provider.

### 9. Support & Documentation

| Feature | Samen | NetSuite | Odoo | ERPNext |
|---|---|---|---|---|
| 24/7 Support | ❌ | ✅ | ✅ | ❌ |
| Enterprise Support | ❌ (coming) | ✅ | ✅ | ⚠️ |
| Documentation | ⚠️ Growing | ✅ | ✅ | ✅ |
| Tutorials | ⚠️ | ✅ | ✅ | ✅ |
| Community | ⚠️ New | ✅ | ✅ | ✅ |

**Verdict: Loss** — Support infrastructure is immature.

### 10. Scalability

| Feature | Samen | NetSuite | Odoo | ERPNext |
|---|---|---|---|---|
| Multi-Entity | ❌ Not shipped (roadmap) | ✅ Advanced | ✅ | ✅ |
| Global Operations | ⚠️ Limited | ✅ 200+ countries | ✅ | ⚠️ |
| Concurrent Users | ⚠️ Untested | ✅ 10K+ | ✅ | ✅ |
| Data Volume | ⚠️ Untested | ✅ | ✅ | ✅ |

**Verdict: Loss** — Scalability unproven at enterprise level.

### 11. Industry Verticals

| Feature | Samen | NetSuite | Odoo | ERPNext |
|---|---|---|---|---|
| Manufacturing | ✅ Basic | ✅ Advanced | ✅ | ✅ |
| Retail | ⚠️ | ✅ | ✅ | ✅ |
| Services | ⚠️ Generic | ✅ | ✅ | ✅ |
| Healthcare | ❌ | ✅ | ⚠️ | ❌ |
| Construction | ❌ | ✅ | ⚠️ | ❌ |

**Verdict: Loss** — Generic, not industry-specific.

### 12. Innovation Speed

| Feature | Samen | NetSuite | Odoo | ERPNext |
|---|---|---|---|---|
| Release Cadence | ⚠️ Active | ⚠️ Quarterly | ⚠️ Monthly | ⚠️ Monthly |
| AI Features | ⚠️ Kernel only | ⚠️ Basic | ❌ | ❌ |
| Modern Stack | ✅ Elixir | ❌ Java | ⚠️ Python | ⚠️ Python |
| Open Source | ✅ Full | ❌ | ✅ | ✅ |

**Verdict: Partial win** — faster iteration and modern technology; AI remains
kernel-only.

## SWOT Analysis

### Strengths
1. **AI-native architecture** — tested kernel AI plane and no-PII-egress chokepoint; host AI flow is not shipped yet
2. **Open source** — Full code access, no vendor lock-in
3. **Modern stack** — Elixir/Phoenix, fast and scalable
4. **Verified codebase** — 308 sabotages, generative proof
5. **Cost** — estimated 4x–30x lower Year 1 cost than NetSuite's reported range; not benchmarked
6. **Self-hosted** — Full data control
7. **Security** — Advanced PII vaulting, crypto-shred

### Weaknesses
1. **Maturity** — New codebase, unproven at scale
2. **Ecosystem** — Limited integrations and apps
3. **Support** — No enterprise support yet
4. **Documentation** — Growing but incomplete
5. **Scalability** — Untested with 1000+ users
6. **Industry verticals** — Generic, not specialized
7. **Team** — Small team, limited bandwidth

### Opportunities
1. **AI market boom** — Every company wants AI
2. **Open source movement** — Growing adoption
3. **Developer-led companies** — Underserved market
4. **Privacy regulations** — GDPR/CCPA driving self-hosting
5. **Cost pressure** — Companies seeking cheaper alternatives
6. **Remote work** — Need modern, cloud-native tools
7. **SaaS growth** — SMBs moving to cloud

### Threats
1. **Enterprise vendors** — NetSuite adding AI features
2. **Open source competitors** — Odoo, ERPNext improving
3. **Market downturn** — Budget cuts affecting IT spending
4. **Technical debt** — Rapid development creating issues
5. **Talent acquisition** — Elixir developers are rare
6. **Customer acquisition** — Hard to reach SMBs
7. **Support costs** — Scaling support is expensive

## Competitive Advantages

### Sustainable Advantages
1. **AI kernel depth** — no-PII-egress chokepoint and governed verbs; host wiring still needed
2. **Code verification** — Unique selling point
3. **Modern architecture** — Elixir/Phoenix performance
4. **Open source community** — Network effects over time

### Temporary Advantages
1. **Speed to market** — AI-native architecture; host AI surfaces pending
2. **Cost structure** — estimated room to undercut reported entry pricing; not a measured benchmark
3. **Flexibility** — Self-hosted option

## Recommended Strategy

### 1. Don't Compete on Features
- NetSuite has 25 years of features
- We can't catch up on breadth
- Compete on **depth** (AI kernel, security, developer experience)

### 2. Compete on Experience
- Modern UI/UX
- API-first design
- Developer-friendly
- Fast performance

### 3. Compete on Cost
- Free self-hosted option
- Usage-based SaaS
- No implementation fees
- Transparent pricing

### 4. Compete on Values
- Open source
- Data ownership
- Privacy-first
- No vendor lock-in

### 5. Target Underserved Segments
- Developer-led startups
- Privacy-conscious companies
- AI-native teams
- Cost-sensitive SMBs

## Market Sizing (estimated)

> **Basis (2026-11-21).** TAM/SAM/SOM are internal, rounded planning assumptions,
> not third-party market research or a forecast. No external market study is cited;
> SOM is a goal, not a committed outcome. Re-derive before external use.

### Total Addressable Market (TAM)
- Global ERP market: $50B+ annually
- SMB segment: $15B+ annually

### Serviceable Addressable Market (SAM)
- Developer-led companies: $2B+ annually
- Self-hosted ERP market: $1B+ annually

### Serviceable Obtainable Market (SOM)
- Year 1: $50K ARR (50 customers)
- Year 2: $500K ARR (500 customers)
- Year 3: $2M ARR (2,000 customers)

## Conclusion

Samen ERP can compete — but not by being a better NetSuite. We compete by:

1. **Serving a different market** (SMBs, not enterprise)
2. **Differentiation** (AI-native architecture, open source, developer-first)
3. **Pricing** (free self-hosted, usage-based SaaS)
4. **Speed** (modern stack, rapid iteration)

The opportunity is real. The market is underserved. The kernel is ready; the host AI
and enterprise surfaces still need wiring.

**Next steps:**
1. Launch open source
2. Build developer community
3. Get first 10 customers
4. Iterate based on feedback
5. Scale what works
