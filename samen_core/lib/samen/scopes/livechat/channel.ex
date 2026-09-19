defmodule Samen.Scopes.Livechat.Channel do
  @moduledoc """
  Live Chat Channel (WS-ERP E22; Flectra-inspired).

  Defines chat channels for different purposes (support, sales, general).

  ## Design

  - `name` — channel name (e.g., "Customer Support")
  - `code` — short code
  - `channel_type` — :support | :sales | :general
  - `is_active` — whether the channel is active
  - `welcome_message` — auto-message when chat starts
  - `offline_message` — message when no agents available
  - `max_wait_seconds` — max wait time before routing
  - `requires_pre_chat_form` — whether to show pre-chat form
  - `pre_chat_fields` — JSON array of form fields

  No PII (INV-1). Archivable.
  """

  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.Core.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "lch",
    archivable: true

  postgres do
    table("lch_channel")
    repo(SamenCore.TestRepo)
  end

  attributes do
    attribute(:name, :string, public?: true, allow_nil?: false)
    attribute(:code, :string, public?: true, allow_nil?: false)
    attribute(:channel_type, :atom, public?: true, allow_nil?: false, default: :support)
    attribute(:is_active, :boolean, public?: true, allow_nil?: false, default: true)
    attribute(:welcome_message, :string, public?: true)
    attribute(:offline_message, :string, public?: true)
    attribute(:max_wait_seconds, :integer, public?: true, default: 300)
    attribute(:requires_pre_chat_form, :boolean, public?: true, allow_nil?: false, default: false)
    attribute(:pre_chat_fields, :map, public?: true)
  end

  actions do
    defaults([:read, create: :*, update: :*])
  end

  policies do
    policy action_type(:read) do
      authorize_if(Samen.Policy.OrgScope)
    end

    policy action_type([:create, :update, :destroy]) do
      forbid_unless(Samen.Policy.OrgScope)
      forbid_unless({Samen.Policy.RoleAtLeast, role: :admin})
      authorize_if(always())
    end
  end
end
