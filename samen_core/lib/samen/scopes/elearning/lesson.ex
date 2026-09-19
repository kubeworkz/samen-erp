defmodule Samen.Scopes.Elearning.Lesson do
  @moduledoc """
  eLearning Lesson (WS-ERP E20; Flectra-inspired).

  An individual lesson within a course. Lessons can be text, video,
  or quiz-based.

  ## Design

  - `course_id` — parent course
  - `title` — lesson title
  - `content_type` — :text | :video | :quiz
  - `content` — lesson content (text or URL)
  - `duration_minutes` — estimated duration
  - `sequence` — display order
  - `is_required` — whether the lesson must be completed
  - `passing_score` — for quiz lessons: minimum score to pass

  No PII (INV-1). Archivable.
  """

  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.Core.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "ell",
    archivable: true

  postgres do
    table("ecl_lesson")
    repo(SamenCore.TestRepo)
  end

  attributes do
    attribute(:course_id, :uuid, public?: true, allow_nil?: false)
    attribute(:title, :string, public?: true, allow_nil?: false)
    attribute(:content_type, :atom, public?: true, allow_nil?: false, default: :text)
    attribute(:content, :string, public?: true)
    attribute(:duration_minutes, :integer, public?: true)
    attribute(:sequence, :integer, public?: true, allow_nil?: false, default: 0)
    attribute(:is_required, :boolean, public?: true, allow_nil?: false, default: true)
    attribute(:passing_score, :integer, public?: true, allow_nil?: false, default: 70)
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
