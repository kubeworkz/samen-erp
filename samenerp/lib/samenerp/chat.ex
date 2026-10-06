defmodule Samenerp.Chat do
  @moduledoc """
  Samenerp's Chat domain — mounts the framework `Samen.Scopes.Chat` blueprint
  (ADR-012, the flagship cross-plane realtime chat), exactly the one-line adoption
  driftwood ships (`Driftwood.Chat`).

  One `use Samen.Scopes.Chat` expands into four host-owned resources in this
  namespace:

    * `Samenerp.Chat.ChatThread`            — a conversation that may span the
      operator↔tenant plane boundary (no PII).
    * `Samenerp.Chat.ChatParticipant`       — 🔒 membership + the cross-plane grant
      carrier (`full_name` vault-routed; `handle` the safe label).
    * `Samenerp.Chat.ChatMessage`           — 🔒 a message (`body` vault-routed;
      `refs` the parsed object refs that unfurl per viewer).
    * `Samenerp.Chat.ChatDisclosureSetting` — Tier-0 per-org identity-disclosure
      config.

  Abbrevs are the scope's CANONICAL ADR-012 §11 defaults (cth/chp/cmg/cds),
  allocator-reserved in the global registry under this host — samenerp is the
  canonical mount, so no prefixed set was needed (driftwood prefixes with `d`).

  The realtime path additionally needs `{Samen.Web.Chat.Presence,
  pubsub_server: Samenerp.PubSub}` in the supervision tree (one line — see
  `Samenerp.Application`) and the `:pubsub` label on the router mount.
  """
  use Ash.Domain, validate_config_inclusion?: false

  use Samen.Scopes.Chat,
    otp_app: :samenerp,
    repo: Samenerp.Repo,
    namespace: Samenerp.Chat,
    abbrevs: %{
      thread: "cth",
      participant: "chp",
      message: "cmg",
      disclosure_setting: "cds"
    }
end
