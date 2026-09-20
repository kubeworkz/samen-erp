defmodule Samen.Scopes.Survey.Answer do
  @moduledoc """
  Survey Answer (WS-ERP E20;).

  An individual answer to a survey question within a response.

  ## Design

  - `response_id` — parent response
  - `question_id` — which question
  - `answer_text` — text answer (for text/boolean questions)
  - `selected_option` — selected option value (for choice questions)
  - `rating_value` — rating value (for rating questions)
  - `is_correct` — whether the answer was correct (auto-graded)
  - `points_earned` — points earned for this answer

  No PII (INV-1). Archivable.
  """

  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.Core.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "sva",
    archivable: true

  postgres do
    table("sva_answer")
    repo(SamenCore.TestRepo)
  end

  attributes do
    attribute(:response_id, :uuid, public?: true, allow_nil?: false)
    attribute(:question_id, :uuid, public?: true, allow_nil?: false)
    attribute(:answer_text, :string, public?: true)
    attribute(:selected_option, :string, public?: true)
    attribute(:rating_value, :integer, public?: true)
    attribute(:is_correct, :boolean, public?: true)
    attribute(:points_earned, :integer, public?: true, allow_nil?: false, default: 0)
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
