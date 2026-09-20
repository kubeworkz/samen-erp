defmodule Samen.Scopes.Elearning.Course do
  @moduledoc """
  eLearning Course (WS-ERP E20;).

  A learning course containing lessons, quizzes, and enrollment.

  ## Design

  - `title` — course title
  - `description` — course description
  - `category` — course category (e.g., "Safety", "Onboarding", "Technical")
  - `difficulty` — :beginner | :intermediate | :advanced
  - `state` — :draft | :published | :archived
  - `instructor_id` — who teaches the course
  - `duration_minutes` — estimated total duration
  - `max_enrollment` — optional enrollment cap
  - `is_certification` — whether completing grants a certification
  - `certification_score` — minimum score to earn certification

  No PII (INV-1). Archivable.
  """

  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.Core.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "elc",
    archivable: true

  postgres do
    table("ecs_course")
    repo(SamenCore.TestRepo)
  end

  attributes do
    attribute(:title, :string, public?: true, allow_nil?: false)
    attribute(:description, :string, public?: true)
    attribute(:category, :string, public?: true)
    attribute(:difficulty, :atom, public?: true, allow_nil?: false, default: :beginner)
    attribute(:state, :atom, public?: true, allow_nil?: false, default: :draft)
    attribute(:instructor_id, :uuid, public?: true)
    attribute(:duration_minutes, :integer, public?: true)
    attribute(:max_enrollment, :integer, public?: true)
    attribute(:is_certification, :boolean, public?: true, allow_nil?: false, default: false)
    attribute(:certification_score, :integer, public?: true, allow_nil?: false, default: 70)
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
