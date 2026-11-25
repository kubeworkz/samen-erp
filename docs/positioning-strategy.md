# Samen ERP Positioning Strategy

> **Status note (2026-11-21).** This is target positioning, not a live feature
> inventory. The tested HuggingFace BYOK kernel ships, but the host settings/key
> flow, daily sweep, prompt-log writes, HF embeddings and in-workflow AI UI are not
> wired; SSO/SAML, monitoring, backups/PITR, plan-based limits, audit export,
> residency and white-label are named shells. See `README.md` for the claim set.
> Market sizing, pricing and phase timelines are targets, not results.

## Executive Summary

Samen ERP is an open-source ERP with an AI-native kernel, designed for developer-led companies with 10-200 employees. We don't compete with NetSuite — we serve the companies they ignore.

## The Market Gap

### Who NetSuite Serves
- Mid-market to enterprise
- Companies with multi-team finance and IT operations
- Budget: reported/planning range of $1,000+/month plus $10K+ implementation

### Who NetSuite Ignores
- **SMBs** (our 10-200 employee target)
- **Developer-led companies** (startups, agencies, SaaS)
- **Privacy-first teams** (GDPR/CCPA concerned)
- **AI-native companies** (want AI embedded everywhere)
- **Self-hosters** (want to own their infrastructure)

**This is our market: a $15B+ SMB ERP segment with a $1B+ self-hosted slice, underserved and growing.**

> Customer-size and revenue bands in this document are internal targeting
> assumptions, not vendor disclosures. The sourced table classifies NetSuite's
> target only as "mid-market to enterprise".

## Positioning Statement

> **Samen ERP is the open-source, developer-first ERP for companies that want control over their data, deep customization, and a governed AI architecture — without the cost and lock-in of traditional enterprise ERP.**

### Live vs shell (AI and enterprise)

- **Live:** kernel BYOK AES-256-GCM key storage, token validation, completion/SSE and
  usage analytics over supplied logs; PII vault, crypto-shred, hash-chained audit and
  audit-on-write.
- **Not live:** the `/settings/huggingface` key flow, daily credential sweep,
  `PromptLog` writes, HuggingFace embeddings provider, and in-workflow AI UI.
- **Enterprise shells:** SSO/SAML, monitoring, backups/PITR, plan-based API/AI limits,
  customer audit-log export, data residency and white-label branding.

## Target Segments

### Segment 1: Developer-Led Startups (Primary)
- **Size:** 10-50 employees
- **Revenue:** $1M-$10M
- **Profile:** Technical founders, engineering-first culture
- **Pain points:** Can't afford NetSuite, want to own code, want AI
- **Value prop:** Self-host, customize, integrate the AI kernel
- **Price:** Free (self-hosted)

### Segment 2: Digital Agencies (Secondary)
- **Size:** 20-100 employees
- **Revenue:** $5M-$50M
- **Profile:** Project-based work, client billing
- **Pain points:** Need project management + accounting, want modern UX
- **Value prop:** All-in-one with a governed AI kernel; host AI UI pending
- **Price:** $50/user/month SaaS (Pro; target)

### Segment 3: SaaS Companies (Tertiary)
- **Size:** 10-200 employees
- **Revenue:** $2M-$50M
- **Profile:** Subscription businesses, high growth
- **Pain points:** Need billing + usage tracking, want API-first
- **Value prop:** Built for SaaS metrics, API-native
- **Price:** $50-$100/user/month SaaS (Pro/Enterprise; target)

## Competitive Positioning

### vs NetSuite
- **NetSuite:** "Enterprise ERP for mid-market"
- **Samen:** "Developer-first ERP for startups"
- **Differentiation:** Open source, self-hostable, AI-native architecture, modern stack

### vs Odoo
- **Odoo:** "Open source ERP for everyone"
- **Samen:** "Developer-first ERP with a governed AI plane"
- **Differentiation:** Better tech stack, governed AI kernel, verified codebase

### vs ERPNext
- **ERPNext:** "Open source ERP for small business"
- **Samen:** "Developer-first ERP with an AI kernel"
- **Differentiation:** Modern Elixir stack, governed AI kernel, verified codebase

### vs QuickBooks/Xero
- **QuickBooks:** "Accounting for small business"
- **Samen:** "Full ERP with a governed AI plane for developers"
- **Differentiation:** Not just accounting, full ERP, self-hostable

## Messaging Framework

### Headline
**"The ERP developers actually want to use."**

### Subheadline
**"Open source. Governed AI kernel. Self-hosted. No lock-in."**

### Key Messages

1. **Own your data** — Self-host on your infrastructure, no vendor lock-in
2. **AI, governed by construction** — tested HuggingFace BYOK kernel and no-PII-egress chokepoint; the host key flow and in-workflow AI UI are the next milestone
3. **Developer-friendly** — Elixir/Phoenix, modern stack, versioned JSON:API
4. **Verify everything** — 425 sabotages and generative proof; verification, not a no-bug guarantee
5. **Scale with you** — From 10 to 200 employees, free to enterprise

### Proof Points
- Live-vs-shell claim set documented in `README.md`
- 425 sabotage tests proving correctness
- OpenAPI 3.0 JSON at `/api/openapi.json` (two paths today)
- Docker/Compose deploy files; Kubernetes guide only (no manifests)

## Go-to-Market Strategy

### Phase 1: Developer Community (Months 1-3)
- Launch on Product Hunt, Hacker News
- Open source on GitHub
- Write technical blog posts
- Build developer documentation
- Create tutorial videos

### Phase 2: Early Adopters (Months 3-6)
- Offer free implementation consulting
- Build case studies with first 5 customers
- Create integration guides (Zapier, webhooks)
- Launch SaaS beta

### Phase 3: Growth (Months 6-12)
- Launch SaaS pricing
- Build partner network
- Add 2-3 industry verticals
- Create certification program

### Phase 4: Enterprise (Months 12-24)
- SOC2 certification
- Enterprise support plans
- Advanced features (multi-entity, consolidations)
- White-label program

## Pricing Strategy (target)

### Self-Hosted (Open Source)
- **Free forever** — Core ERP + tested AI kernel
- **Enterprise license** — $500/month for premium support

### SaaS (Hosted)

> API allowances are **unenforced target limits**: plan-based API/AI rate limiting is
> an unwired shell, so no quota is enforced today. Segment prices above use the same
> per-user basis as these plans.

- **Free tier** — 1 user; 100 API calls/month (target, unenforced)
- **Pro** — $50/user/month; 10,000 API calls/month (target, unenforced)
- **Enterprise** — $100/user/month; unlimited API calls (target, unenforced)

### AI Features (target)
- **Bring your own HuggingFace key** — host key flow and credential sweep are not wired; this is a target, not a billable feature.
- **Usage-based** — target: $0.0001 per 1K tokens (pass-through pricing); no metered AI billing is wired.

## Success Metrics

### Year 1 Goals
- 500 GitHub stars
- 50 self-hosted deployments
- 10 SaaS customers
- $50K ARR

### Year 2 Goals
- 2,000 GitHub stars
- 200 self-hosted deployments
- 100 SaaS customers
- $500K ARR

### Year 3 Goals
- 5,000 GitHub stars
- 500 self-hosted deployments
- 500 SaaS customers
- $2M ARR

## Risk Mitigation

### Risk 1: Enterprise sales cycle too long
- **Mitigation:** Focus on self-serve, developer-led adoption

### Risk 2: Support costs scale linearly
- **Mitigation:** Build community support, documentation, tutorials

### Risk 3: Large vendors copy AI features
- **Mitigation:** Move fast, open source advantage, community moat

### Risk 4: Self-hosting too complex
- **Mitigation:** One-click deployment, managed hosting option

## Conclusion

Samen ERP can compete — but not by building a worse NetSuite. We compete by:

1. **Serving a different market** (SMBs, not enterprise)
2. **Differentiation** (open source, AI-native architecture, developer-first)
3. **Pricing** (free self-hosted, usage-based SaaS)
4. **Speed** (modern stack, rapid iteration)

The $15B+ SMB ERP market is ours to win, starting with the $1B+ self-hosted slice.
