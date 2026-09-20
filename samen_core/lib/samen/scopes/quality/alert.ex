defmodule Samen.Scopes.Quality.Alert do
  @moduledoc """
  Quality Alert (WS-ERP E19;).

  Triggered when a quality check fails. Alerts notify quality teams
  and track corrective actions.

  ## Design

  - `check_id` — which check triggered the alert
  - `control_point_id` — originating control point
  - `title` — alert title (auto-generated or manual)
  - `description` — what went wrong
  - `priority` — :low | :medium | :high | :critical
  - `status` — :open | :in_progress | :resolved | :closed
  - `team_id` — responsible quality team
  - `responsible_id` — individual responsible
  - `root_cause` — why it failed (filled during investigation)
  - `corrective_action` — what was done to fix
  - `preventive_action` — what to prevent recurrence
  - `resolved_at` — when resolved
  - `closed_at` — when closed

  No PII (INV-1). Archivable.
  """

  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.Core.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "qal",
    archivable: true

  postgres do
    table("qal_alert")
    repo(SamenCore.TestRepo)
  end

  attributes do
    attribute(:check_id, :uuid, public?: true, allow_nil?: false)
    attribute(:control_point_id, :uuid, public?: true, allow_nil?: false)
    attribute(:title, :string, public?: true, allow_nil?: false)
    attribute(:description, :string, public?: true)
    attribute(:priority, :atom, public?: true, allow_nil?: false, default: :medium)
    attribute(:status, :atom, public?: true, allow_nil?: false, default: :open)
    attribute(:team_id, :uuid, public?: true)
    attribute(:responsible_id, :uuid, public?: true)
    attribute(:root_cause, :string, public?: true)
    attribute(:corrective_action, :string, public?: true)
    attribute(:preventive_action, :string, public?: true)
    attribute(:resolved_at, :utc_datetime_usec, public?: true)
    attribute(:closed_at, :utc_datetime_usec, public?: true)
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
