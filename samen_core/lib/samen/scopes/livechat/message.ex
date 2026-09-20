defmodule Samen.Scopes.Livechat.Message do
  @moduledoc """
  Live Chat Message (WS-ERP E22;).

  An individual message in a live chat session.

  ## Design

  - `session_id` — parent session
  - `sender_type` — :visitor | :agent | :system
  - `sender_id` — who sent it (user_id or nil for system)
  - `body` — message text
  - `message_type` — :text | :file | :image | :system
  - `sent_at` — when the message was sent
  - `read_at` — when the message was read

  No PII (INV-1). Archivable.
  """

  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.Core.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "lcm",
    archivable: true

  postgres do
    table("lcm_message")
    repo(SamenCore.TestRepo)
  end

  attributes do
    attribute(:session_id, :uuid, public?: true, allow_nil?: false)
    attribute(:sender_type, :atom, public?: true, allow_nil?: false)
    attribute(:sender_id, :uuid, public?: true)
    attribute(:body, :string, public?: true, allow_nil?: false)
    attribute(:message_type, :atom, public?: true, allow_nil?: false, default: :text)
    attribute(:sent_at, :utc_datetime_usec, public?: true)
    attribute(:read_at, :utc_datetime_usec, public?: true)
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
      authorize_if(always())
    end
  end
end
