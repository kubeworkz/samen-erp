defmodule Samen.Scopes.Livechat.Session do
  @moduledoc """
  Live Chat Session (WS-ERP E22; Flectra-inspired).

  A live chat session between a visitor/customer and an agent.

  ## Design

  - `channel_id` — which channel
  - `visitor_id` — visitor identifier (cookie/session)
  - `customer_id` — optional: logged-in customer
  - `agent_id` — assigned agent (nil if unassigned)
  - `state` — :waiting | :active | :closed
  - `started_at` — when the session started
  - `ended_at` — when the session ended
  - `wait_seconds` — how long the visitor waited
  - `duration_seconds` — session duration
  - `satisfaction_rating` — optional: visitor rating (1-5)
  - `tags` — JSON array of tags

  No PII (INV-1). Archivable.
  """

  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.Core.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "lcs",
    archivable: true

  postgres do
    table("lcs_session")
    repo(SamenCore.TestRepo)
  end

  attributes do
    attribute(:channel_id, :uuid, public?: true, allow_nil?: false)
    attribute(:visitor_id, :string, public?: true, allow_nil?: false)
    attribute(:customer_id, :uuid, public?: true)
    attribute(:agent_id, :uuid, public?: true)
    attribute(:state, :atom, public?: true, allow_nil?: false, default: :waiting)
    attribute(:started_at, :utc_datetime_usec, public?: true)
    attribute(:ended_at, :utc_datetime_usec, public?: true)
    attribute(:wait_seconds, :integer, public?: true)
    attribute(:duration_seconds, :integer, public?: true)
    attribute(:satisfaction_rating, :integer, public?: true)
    attribute(:tags, :map, public?: true)
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
