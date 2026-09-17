defmodule Samenerp.Primitives do
  @moduledoc """
  Samenerp's Primitives domain — the samen_core Primitives scope blueprint
  (ADR-004; `Samen.Scopes.Primitives`) mounted AS-IS, exactly as demo
  (`Demo.PrimitivesScope`), driftwood (`Driftwood.Primitives`) and pawchart
  (`PawChart.Primitives`) mount it.

  This mount exists so the app INHERITS the framework notifications inbox
  (`samen_notifications_routes` in the router — zero LiveView code) and the
  FeatureFlag rows the operator flag admin manages (the `flags_namespace` label).

  Fresh `ent/enp/efl/esh/ewh/eff` abbrevs,
  reserved in the GLOBAL registry (samen_core/priv/abbrev_registry.json) by the
  generator:

    * `ent` Notification (🔒 rendered_body → vault; `pii_ent_rendered_body`)
    * `enp` NotificationPreference (no PII — bounded id + enums + bools)
    * `efl`/`esh`/`ewh`/`eff` — File/SearchIndex/Webhook/
      FeatureFlag (blueprint completeness; the flag rows back the operator flag admin)
  """
  use Ash.Domain, validate_config_inclusion?: false

  use Samen.Scopes.Primitives,
    otp_app: :samenerp,
    repo: Samenerp.Repo,
    namespace: Samenerp.Primitives,
    abbrevs: %{
      notification: "ent",
      notification_preference: "enp",
      file: "efl",
      search_index: "esh",
      webhook: "ewh",
      feature_flag: "eff"
    }
end
