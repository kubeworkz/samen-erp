defmodule Samenerp.Automation do
  @moduledoc """
  Samenerp's Automation domain — the `Samen.Scopes.Automation` universal scope
  (ADR-039 §3.1: `Workflow` · `Reminder` · `Escalation` · `Run`) mounted AS-IS,
  exactly as driftwood (`Driftwood.Automation`) mounts it — the first vertical
  adoption this host mirrors.

  This mount exists so the app INHERITS the framework automation builder
  (`samen_automation_routes(:automation, ...)` in the router — one LiveView for
  list + author/edit + pause/resume + run-now, zero authored LiveView code).

  Fresh `z`-family abbrevs, reserved in the GLOBAL registry
  (samen_core/priv/abbrev_registry.json). The scope's defaults
  (`awf`/`arm`/`aes`/`sar`) are permanently owned by the samen_core automation
  fixtures, hence the fresh overrides:

    * `zwf` Workflow — E1 rule definition (trigger → conditions → actions),
      incl. the §8.4 operator kill columns. No PII by schema.
    * `zrm` Reminder — E4 first-class reminder (🔒 `pii_zrm_note` vaulted).
    * `zes` Escalation — E5 generic escalation primitive (AshStateMachine).
    * `zrn` Run — E8 run log (`queued → running → …`), kernel-written.

  The engine seams are wired in config.exs
  (`config :samen_core, Samen.Automation, workflow_module: …`).
  """
  use Ash.Domain, validate_config_inclusion?: false

  use Samen.Scopes.Automation,
    otp_app: :samenerp,
    repo: Samenerp.Repo,
    namespace: Samenerp.Automation,
    abbrevs: %{
      workflow: "zwf",
      reminder: "zrm",
      escalation: "zes",
      run: "zrn"
    }
end
