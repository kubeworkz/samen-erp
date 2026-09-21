defmodule Samenerp.Crm do
  @moduledoc "Samenerp CRM domain."
  use Ash.Domain, validate_config_inclusion?: false

  use Samen.Scopes.Crm,
    otp_app: :samenerp,
    repo: Samenerp.Repo,
    namespace: Samenerp.Crm,
    abbrevs: %{
      company: "zcm",
      person: "zpr",
      pipeline: "zpl",
      opportunity: "zop",
      attachment: "zat"
    }
end
