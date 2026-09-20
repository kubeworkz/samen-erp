defmodule Samen.Core.Domain do
  @moduledoc """
  The Ash domain that hosts the core ERP resources including the new AI integration.

  This domain manages resources for:
  - AI/ML integration (HuggingFace BYOK)
  - Core ERP functionality

  Host apps mount this domain by adding `Samen.Core.Domain` to their `:ash_domains` config.
  """
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    # AI Integration resources
    resource(Samen.Scopes.Ai.ApiKey)
    resource(Samen.Scopes.Ai.PromptLog)
    resource(Samen.Scopes.Ai.Model)
    resource(Samen.Scopes.Ai.Conversation)
  end
end
