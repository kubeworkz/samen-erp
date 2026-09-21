defmodule Samenerp.Marketing do
  @moduledoc """
  Samenerp's Marketing domain — mounted from the samen_core Marketing scope blueprint.
  One `use Samen.Scopes.Marketing` expands into seven host-owned resources in
  `Samenerp.Marketing.*`:

    * `Samenerp.Marketing.Campaign`    — outreach campaigns
    * `Samenerp.Marketing.Segment`     — audience segments
    * `Samenerp.Marketing.Subscriber`  — 🔒 (email vault-routed; consent tracked)
    * `Samenerp.Marketing.Template`    — reusable email templates
    * `Samenerp.Marketing.Send`        — single send events
    * `Samenerp.Marketing.EmailEvent`  — delivery/open/click/bounce events
    * `Samenerp.Marketing.Suppression` — opt-out / bounce suppression list
  """
  use Ash.Domain, validate_config_inclusion?: false

  use Samen.Scopes.Marketing,
    otp_app: :samenerp,
    repo: Samenerp.Repo,
    namespace: Samenerp.Marketing
end
