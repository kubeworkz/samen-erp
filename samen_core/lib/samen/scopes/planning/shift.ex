defmodule Samen.Scopes.Planning.Shift do
  @moduledoc """
  Planning Shift (WS-ERP E34; Flectra-inspired).

  An individual scheduled shift or assignment.

  ## Design

  - `resource_id` — reference to PlanningResource
  - `template_id` — reference to PlanningTemplate (if from template)
  - `project_id` — reference to project/task
  - `title` — shift title
  - `description` — shift description
  - `start_at` — shift start datetime
  - `end_at` — shift end datetime
  - `duration_hours` — computed duration
  - `status` — :draft | :published | :confirmed | :in_progress | :completed | :cancelled
  - `color` — UI color code for Gantt/calendar
  - `recurring` — whether shift repeats
  - `recurrence_rule` — RRULE string for recurrence
  - `subject_key` / `subject_id` — object-ref attachment

  Lifecycle: draft → published → confirmed → in_progress → completed
  No PII (INV-1). Archivable.
  """

  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.Core.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "plt",
    archivable: true

  postgres do
    table("plt_shift")
    repo(SamenCore.TestRepo)
  end

  attributes do
    uuid_primary_key :id
    attribute :resource_id, :uuid, allow_nil?: false
    attribute :template_id, :uuid
    attribute :project_id, :uuid
    attribute :title, :string, allow_nil?: false
    attribute :description, :string
    attribute :start_at, :utc_datetime_usec, allow_nil?: false
    attribute :end_at, :utc_datetime_usec, allow_nil?: false
    attribute :duration_hours, :float
    attribute :status, :atom, default: :draft,
      constraints: [one_of: [:draft, :published, :confirmed, :in_progress, :completed, :cancelled]]
    attribute :color, :string
    attribute :recurring, :boolean, default: false
    attribute :recurrence_rule, :string
    attribute :subject_key, :string
    attribute :subject_id, :string

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  actions do
    defaults [:create, :read, :update, :destroy]

    update :publish do
      require_atomic? false
      change set_attribute(:status, :published)
    end

    update :confirm do
      require_atomic? false
      change set_attribute(:status, :confirmed)
    end

    update :start_shift do
      require_atomic? false
      change set_attribute(:status, :in_progress)
    end

    update :complete do
      require_atomic? false
      change set_attribute(:status, :completed)
    end

    update :cancel do
      require_atomic? false
      change set_attribute(:status, :cancelled)
    end
  end

  policies do
    policy action_type([:read, :create, :update, :destroy]) do
      authorize_if always()
    end
  end
end
