defmodule Samen.Scopes.Elearning.Enrollment do
  @moduledoc """
  eLearning Enrollment (WS-ERP E20; Flectra-inspired).

  Tracks a user's enrollment in a course and their overall progress.

  ## Design

  - `course_id` — which course
  - `user_id` — enrolled user
  - `state` — :enrolled | :in_progress | :completed | :dropped
  - `enrolled_at` — when enrolled
  - `completed_at` — when completed
  - `progress_percent` — completion percentage (0-100)
  - `certification_earned` — whether certification was earned
  - `final_score` — overall score (for certification courses)

  No PII (INV-1). Archivable.
  """

  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.Core.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "evl",
    archivable: true

  postgres do
    table("ece_enrollment")
    repo(SamenCore.TestRepo)
  end

  attributes do
    attribute(:course_id, :uuid, public?: true, allow_nil?: false)
    attribute(:user_id, :uuid, public?: true, allow_nil?: false)
    attribute(:state, :atom, public?: true, allow_nil?: false, default: :enrolled)
    attribute(:enrolled_at, :utc_datetime_usec, public?: true)
    attribute(:completed_at, :utc_datetime_usec, public?: true)
    attribute(:progress_percent, :integer, public?: true, allow_nil?: false, default: 0)
    attribute(:certification_earned, :boolean, public?: true, allow_nil?: false, default: false)
    attribute(:final_score, :float, public?: true)
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
