defmodule Samenerp.Marketing do
  @moduledoc """ Samenerp Marketing domain. """
  use Ash.Domain, validate_config_inclusion?: false

  use Samen.Scopes.Marketing,
    otp_app: :samenerp,
    repo: Samenerp.Repo,
    namespace: Samenerp.Marketing,
    abbrevs: %{
      campaign: "zmc",
      segment: "zmg",
      subscriber: "zms",
      template: "zmt",
      send: "zmn",
      email_event: "zme",
      suppression: "zmp",
      consent_event: "zmv"
    }
end
