defmodule Samenerp.Support do
  @moduledoc """
  Samenerp's TENANT Support domain — the `Samen.Scopes.Support` universal scope
  (T3.6: `ticket · conversation · message🔒 · agent🔒 · sla · macro · csat` +
  the I6 `csat_survey_token`) mounted AS-IS, exactly as demo
  (`Demo.SupportScope`), driftwood (`Driftwood.Support`) and pawchart
  (`PawChart.Support`) mount it.

  This mount exists so the app INHERITS the framework support surfaces
  (`samen_module_routes(:support, ...)` in the router — tickets list + detail +
  KB, zero LiveView code).

  Fresh `z`-family abbrevs, reserved in the GLOBAL registry
  (samen_core/priv/abbrev_registry.json):

    * `ztk` Ticket (archivable — SLA deadline, priority, status; no PII)
    * `zcv` Conversation (archivable — a thread on a ticket)
    * `zmo` Message (🔒 `pii_zmo_body` free-text vault; archivable)
    * `zag` Agent (🔒 `zag_full_name` composite + `pii_zag_email` scalar; archivable)
    * `zla` Sla (Tier-0 SLA policies per org; archivable)
    * `zma` Macro (Tier-0 canned responses; archivable)
    * `zca` Csat (satisfaction responses — excluded ledger, NOT archivable)
    * `zct` CsatSurveyToken (single-use hashed-at-rest survey link; NOT archivable)

  The scope's default abbrevs (`stk`/`scv`/…) belong to demo and are
  permanently registry-owned — hence the fresh overrides.
  """
  use Ash.Domain, validate_config_inclusion?: false

  use Samen.Scopes.Support,
    otp_app: :samenerp,
    repo: Samenerp.Repo,
    namespace: Samenerp.Support,
    abbrevs: %{
      ticket: "ztk",
      conversation: "zcv",
      message: "zmo",
      agent: "zag",
      sla: "zla",
      macro: "zma",
      csat: "zca",
      csat_survey_token: "zct"
    }
end
