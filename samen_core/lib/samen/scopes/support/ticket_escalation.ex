defmodule Samen.Scopes.Support.TicketEscalation do
  @moduledoc """
  Ticket Escalation (WS-ERP E16; helpdesk).

  Tracks the escalation history of a support ticket. Each row records
  one escalation event — when the ticket was escalated, from whom,
  to whom, and why.

  ## Design

  - `ticket_id` — the ticket being escalated
  - `from_agent_id` — who escalated (nullable for auto-escalations)
  - `to_agent_id` — who it was escalated to (nullable for level-up)
  - `level` — escalation level (1 = first response, 2 = supervisor, 3 = management)
  - `reason` — why it was escalated
  - `escalated_at` — when the escalation happened

  Append-only: escalations are facts, not editable.

  No PII (INV-1). The agent PII lives in the Agent resource.
  """

  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.Core.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "tes",
    archivable: false

  postgres do
    table("tes_ticket_escalation")
    repo(SamenCore.TestRepo)
  end

  attributes do
    attribute(:ticket_id, :uuid, public?: true, allow_nil?: false)
    attribute(:from_agent_id, :uuid, public?: true)
    attribute(:to_agent_id, :uuid, public?: true)

    attribute(:level, :integer,
      public?: true,
      allow_nil?: false,
      default: 1
    )

    attribute(:reason, :string, public?: true)
    attribute(:escalated_at, :utc_datetime, public?: true, allow_nil?: false)
  end

  actions do
    # Read-only: escalations are append-only facts
    read :read do
      primary?(true)
      pagination(keyset?: true, required?: false)
    end

    create :create do
      accept([:org_id, :ticket_id, :from_agent_id, :to_agent_id, :level, :reason, :escalated_at])
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if(Samen.Policy.OrgScope)
    end

    policy action_type(:create) do
      forbid_unless(Samen.Policy.OrgScope)
      forbid_unless({Samen.Policy.RoleAtLeast, role: :member})
      authorize_if(always())
    end
  end
end
