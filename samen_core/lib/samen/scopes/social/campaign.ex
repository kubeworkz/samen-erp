defmodule Samen.Scopes.Social.Campaign do
  @moduledoc """
  Social Marketing Campaign (WS-ERP E22; Flectra-inspired).

  A marketing campaign containing multiple social media posts.

  ## Design

  - `name` — campaign name
  - `description` — campaign description
  - `state` — :draft | :running | :paused | :completed
  - `start_date` — when the campaign starts
  - `end_date` — when the campaign ends
  - `budget` — optional budget in minor units
  - `spent` — amount spent so far
  - `target_audience` — JSON audience definition
  - `objective` — campaign objective (e.g., "brand_awareness", "leads")

  No PII (INV-1). Archivable.
  """

  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.Core.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "soc",
    archivable: true

  postgres do
    table("soc_campaign")
    repo(SamenCore.TestRepo)
  end

  attributes do
    attribute(:name, :string, public?: true, allow_nil?: false)
    attribute(:description, :string, public?: true)
    attribute(:state, :atom, public?: true, allow_nil?: false, default: :draft)
    attribute(:start_date, :date, public?: true)
    attribute(:end_date, :date, public?: true)
    attribute(:budget, :integer, public?: true)
    attribute(:spent, :integer, public?: true, allow_nil?: false, default: 0)
    attribute(:target_audience, :map, public?: true)
    attribute(:objective, :string, public?: true)
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
