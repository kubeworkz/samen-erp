defmodule Samenerp.Work do
  @moduledoc """
  Samenerp Work domain — tasks · projects (F1 / ADR-041), the same universal scope
  demo/driftwood/pawchart already mount, wired here so this host's activity
  composer and every Work surface become REAL instead of honestly-absent (the
  `Samen.Web.Work.*` UI + `__routes__(:work)` are framework-complete; pawchart
  mounts the identical one-liner).

  Abbrevs `wsp`/`wst` are allocator-reserved under THIS host (ADR-023,
  `mix samen.abbrev.reserve --propose`) — demo already owns the scope-default
  `wpj`/`wtk`, and one owner per prefix per namespace is the permanence rule.

  No resource here carries a vault-routed field (the Work scope's PII map is
  empty), so no masking trio applies.
  """
  use Ash.Domain, validate_config_inclusion?: false

  use Samen.Scopes.Work,
    otp_app: :samenerp,
    repo: Samenerp.Repo,
    namespace: Samenerp.Work,
    abbrevs: %{
      project: "wsp",
      task: "wst"
    }
end
