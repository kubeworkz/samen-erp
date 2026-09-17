defmodule Samenerp.Operator do
  @moduledoc """
  Samenerp's OPERATOR namespace (ADR-010 §8.1) — a SECOND mount of the Identity +
  Billing + Support blueprints, alongside the vertical's own tenant mounts. Its rows
  describe the SaaS company's OWN book of business as a vendor: its tenant-org ACCOUNTS
  (`Identity.Org`), those accounts' tenant-ADMINS (`Identity.User` — PII the SaaS OWNS,
  CLEAR to the operator on its own tenant plane), each tenant's subscription-to-the-SaaS
  (`Billing`), and the tickets tenants file WITH the SaaS (`Support`). Mirrors
  `Driftwood.Operator` — the shipped reference.

  The operator workspace is mounted in the router by ONE `samen_operator_routes` line;
  the well-known operator org id lives in config (`:operator_org_id`).

  Fresh `eoo*`-family abbrevs (Identity `er→o`, Billing `→p`,
  Support `→q` — the driftwood per-plane convention), reserved append-only in the
  GLOBAL registry by the generator. No samen_core code changed — only data-file rows
  (ADR-006).
  """
  use Ash.Domain, validate_config_inclusion?: false

  use Samen.Scopes.Identity,
    otp_app: :samenerp,
    repo: Samenerp.Repo,
    namespace: Samenerp.Operator,
    abbrevs: %{
      org: "eoo",
      user: "eou",
      membership: "eom",
      role: "eor",
      api_key: "eok",
      invitation: "eon",
      credential: "eoc",
      auth_token: "eot",
      session: "eos",
      user_identity: "eoi",
      login_failure: "eol"
    }

  use Samen.Scopes.Billing,
    otp_app: :samenerp,
    repo: Samenerp.Repo,
    namespace: Samenerp.Operator,
    abbrevs: %{
      customer: "epc",
      subscription: "eps",
      plan: "epp",
      price: "epr",
      invoice: "epi",
      payment: "epy",
      usage: "epu",
      entitlement: "epe",
      subscription_event: "epv"
    }

  use Samen.Scopes.Support,
    otp_app: :samenerp,
    repo: Samenerp.Repo,
    namespace: Samenerp.Operator,
    abbrevs: %{
      ticket: "eqk",
      conversation: "eqc",
      message: "eqm",
      agent: "eqg",
      sla: "eql",
      macro: "eqn",
      csat: "eqs",
      csat_survey_token: "eqt"
    }
end
