defmodule Samen.Scopes.Support.TicketCategory do
  @moduledoc """
  Ticket Category (WS-ERP E16; Flectra-inspired helpdesk).

  Tier-0 config row: one category per org. Used to classify support
  tickets by type (bug, feature request, question, billing, etc.).

  ## Design

  - `name` — human-readable name (e.g., "Bug Report")
  - `color` — optional hex color for UI display
  - `default_priority` — default priority for tickets in this category
  - `is_active` — whether the category is available for new tickets

  No PII (INV-1). Archivable.
  """

  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.Core.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "tct",
    archivable: true

  postgres do
    table("tct_ticket_category")
    repo(SamenCore.TestRepo)
  end

  attributes do
    attribute(:name, :string, public?: true, allow_nil?: false)
    attribute(:color, :string, public?: true)

    attribute(:default_priority, :atom,
      public?: true,
      allow_nil?: false,
      default: :normal,
      constraints: [one_of: [:low, :normal, :high, :urgent]]
    )

    attribute(:is_active, :boolean, public?: true, allow_nil?: false, default: true)
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
