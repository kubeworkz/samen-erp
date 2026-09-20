defmodule Samen.Scopes.Survey.Question do
  @moduledoc """
  Survey Question (WS-ERP E20;).

  An individual question within a survey. Supports multiple question
  types with scoring.

  ## Design

  - `survey_id` — parent survey
  - `text` — question text
  - `question_type` — :text | :multiple_choice | :single_choice | :rating | :boolean
  - `is_required` — whether the question must be answered
  - `score` — points awarded for correct answer
  - `sequence` — display order
  - `options` — JSON array of answer options (for choice types)
  - `correct_answer` — the correct answer (for auto-grading)
  - `explanation` — shown after answering (for educational surveys)

  No PII (INV-1). Archivable.
  """

  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.Core.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "svq",
    archivable: true

  postgres do
    table("svq_question")
    repo(SamenCore.TestRepo)
  end

  attributes do
    attribute(:survey_id, :uuid, public?: true, allow_nil?: false)
    attribute(:text, :string, public?: true, allow_nil?: false)
    attribute(:question_type, :atom, public?: true, allow_nil?: false, default: :text)
    attribute(:is_required, :boolean, public?: true, allow_nil?: false, default: true)
    attribute(:score, :integer, public?: true, allow_nil?: false, default: 1)
    attribute(:sequence, :integer, public?: true, allow_nil?: false, default: 0)
    attribute(:options, :map, public?: true)
    attribute(:correct_answer, :string, public?: true)
    attribute(:explanation, :string, public?: true)
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
