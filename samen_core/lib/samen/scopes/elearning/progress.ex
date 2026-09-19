defmodule Samen.Scopes.Elearning.Progress do
  @moduledoc """
  eLearning Progress (WS-ERP E20; Flectra-inspired).

  Tracks completion of individual lessons within an enrollment.

  ## Design

  - `enrollment_id` — parent enrollment
  - `lesson_id` — which lesson
  - `state` — :not_started | :in_progress | :completed
  - `score` — quiz score (for quiz lessons)
  - `passed` — whether the lesson was passed
  - `started_at` — when the lesson was started
  - `completed_at` — when the lesson was completed
  - `time_spent_seconds` — time spent on the lesson

  No PII (INV-1). Archivable.
  """

  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.Core.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "elp",
    archivable: true

  postgres do
    table("ecp_progress")
    repo(SamenCore.TestRepo)
  end

  attributes do
    attribute(:enrollment_id, :uuid, public?: true, allow_nil?: false)
    attribute(:lesson_id, :uuid, public?: true, allow_nil?: false)
    attribute(:state, :atom, public?: true, allow_nil?: false, default: :not_started)
    attribute(:score, :float, public?: true)
    attribute(:passed, :boolean, public?: true, allow_nil?: false, default: false)
    attribute(:started_at, :utc_datetime_usec, public?: true)
    attribute(:completed_at, :utc_datetime_usec, public?: true)
    attribute(:time_spent_seconds, :integer, public?: true)
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
