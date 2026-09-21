defmodule Samenerp.Crm do
  @moduledoc """
  Samenerp's CRM domain — mounted from the samen_core CRM scope blueprint.
  One `use Samen.Scopes.Crm` expands into five host-owned resources in
  `Samenerp.Crm.*`:

    * `Samenerp.Crm.Company`     — company records
    * `Samenerp.Crm.Person`      — contacts (vaulted PII)
    * `Samenerp.Crm.Pipeline`    — deal stages
    * `Samenerp.Crm.Opportunity` — deals / opportunities
    * `Samenerp.Crm.Attachment`  — file attachments
  """
  use Ash.Domain, validate_config_inclusion?: false

  use Samen.Scopes.Crm,
    otp_app: :samenerp,
    repo: Samenerp.Repo,
    namespace: Samenerp.Crm
end
