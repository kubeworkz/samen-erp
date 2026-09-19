defmodule Samen.Scopes.SocialMarketing.Account do
  @moduledoc """
  Social Marketing Account (WS-ERP E30; Flectra-inspired).

  A connected social media account.

  ## Design

  - `name` — display name (e.g., "Company Twitter")
  - `platform` — :facebook | :twitter | :linkedin | :instagram | :tiktok | :youtube
  - `account_id` — platform account ID
  - `status` — :connected | :disconnected | :error
  - `access_token` — OAuth access token (vaulted)
  - `token_expires_at` — token expiration
  - `last_sync_at` — last data sync
  - `followers_count` — current follower count

  No PII (INV-1). Archivable.
  """

  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.Core.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "sak",
    archivable: true

  postgres do
    table("sak_account")
    repo(SamenCore.TestRepo)
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string, allow_nil?: false
    attribute :platform, :atom, allow_nil?: false, constraints: [one_of: [:facebook, :twitter, :linkedin, :instagram, :tiktok, :youtube]]
    attribute :account_id, :string, allow_nil?: false
    attribute :status, :atom, default: :connected, constraints: [one_of: [:connected, :disconnected, :error]]
    attribute :access_token, :string
    attribute :token_expires_at, :utc_datetime_usec
    attribute :last_sync_at, :utc_datetime_usec
    attribute :followers_count, :integer, default: 0

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  actions do
    defaults [:create, :read, :update, :destroy]

    update :disconnect do
      require_atomic? false
      change set_attribute(:status, :disconnected)
    end

    update :reconnect do
      require_atomic? false
      change set_attribute(:status, :connected)
    end
  end

  policies do
    policy action_type([:read, :create, :update, :destroy]) do
      authorize_if always()
    end
  end
end
