defmodule Samen.AI.AssistantConversation do
  @moduledoc """
  `Samen.AI.AssistantConversation` — one conversation thread under an assistant
  (docs/plans/ai-assistant-openclaw-lite.md §5/A5, P1).

  The bounded thread row for the assistant's OpenClaw-lite chat — the
  `Samen.AI.Agent.Run` vault-transcript pattern carried to a streaming
  completion surface. One thread stays in ONE org and points at ONE
  assistant; the bounded chat history (the ONE text artifact the surface
  manages) persists as the vault-routed `:transcript`.

  ## PII governance — vault, not scrub (the `Agent.Run` posture)

  The ONE persisted text artifact — the running chat transcript as
  `{assistant_id, title, turns: [{role, content, grounding_refs}]}` JSON —
  lives in the vault-routed `:transcript` (`pii do vault(:pii_transcript)`)
  inside the DEK envelope keyed on this row's own id (the
  `Samen.Vault.Change.resolve_subject_id/1` per-row crypto-shred unit). The
  domain column holds a `vt_*` token; the read presents `%Samen.Masked{}`; the
  reveal path is the single `Samen.Vault.reveal/3` chokepoint bound to
  `subject_id: conversation.id` (the `Samen.Identity.Totp` precedent). Every
  other column on this resource is token- or count-only (`Samen.AI.Agent.Turn`
  precedent) — ids, statuses, counts, timestamps — NO sample values outside the
  envelope.

  Therefore `transcript` must be covered by the `mix samen.verify.*`
  `vault_declared_parity` / `no_plaintext_pii` checks the same way `Agent.Run`
  is. The server reads on the actor's plane (`Samen.Api.PiiResolution`); the
  chokepoint re-scrubs each prior assistant/output turn as `:history` (§3.2a).

  ## The `Samen.AI.Assistant` link

  `assistant_id` names the `Samen.AI.Assistant` (ast) this thread belongs to.
  There is no FK or cross-resource hard guarantee enforced here beyond the usual
  org-scope pin: the Server seam and `AssistantReads` validate that the two ids
  agree and belong to the SAME `org_id` before a thread is rendered. The column
  is the join key, not a governance gate — the allow-list of visible assistants
  is `Samen.AI.Assistant`, org-scoped, at the Server seam.

  ## Status lifecycle

  `:active` → `:archived` (the `:archive` soft action) → restore or
  `destroy_permanently`. Achival is row-level, not key-shred — the vault
  row survives archiving (the D1 posture: sharding is `Samen.Erasure.shred/2`
  destroying the DEK, not a deleted row).
  """

  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.AI.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "asc",
    archivable: true,
    embeddable: [:title]

  postgres do
    table("ai_assistant_conversation")
    repo(Application.compile_env(:samen_core, :samen_ai_assistant_conversation_repo, SamenCore.TestRepo))
  end

  attributes do
    attribute(:assistant_id, :uuid, public?: true, allow_nil?: false)

    attribute(:title, :string, public?: true, allow_nil?: false)
    attribute(:status, :atom,
      public?: true,
      allow_nil?: false,
      default: :active,
      writable?: false,
      constraints: [one_of: [:active, :archived, :deleted]]
    )

    attribute(:model_id, :string, public?: true)
    attribute(:message_count, :integer, public?: true, allow_nil?: false, default: 0)
    attribute(:total_tokens, :integer, public?: true, allow_nil?: false, default: 0)
    attribute(:last_message_at, :utc_datetime_usec, public?: true)
  end

  pii do
    vault(:pii_transcript)
    pii_attribute(:transcript, :string, vault: :pii_transcript)
    reveal(:reveal_assistant_conversation)
  end

  actions do
    defaults([:read])

    create :new_conversation do
      description("Open a conversation thread under one assistant in the org.")
      accept([:org_id, :assistant_id, :title, :model_id, :transcript])
    end

    update :append_turn do
      description("Append one rendered assistant/user turn to the thread.")
      accept([:message_count, :total_tokens, :last_message_at, :transcript])
      require_atomic?(false)
    end

    update :rename do
      accept([:title, :model_id])
      require_atomic?(false)
    end

    update :archive_conversation do
      accept([])
      require_atomic?(false)
      change(set_attribute(:status, :archived))
    end

    action :reveal_assistant_conversation, :map do
      argument(:actor_id, :string, allow_nil?: false)
      argument(:subject_id, :string, allow_nil?: false)

      run(fn input, _ctx ->
        ctx = %Samen.Reveal.Context{
          actor: input.arguments.actor_id,
          subject_id: input.arguments.subject_id,
          resource: __MODULE__,
          action: :reveal_assistant_conversation,
          label: :transcript
        }

        if Samen.Reveal.grant_checker().granted?(ctx) do
          {:ok, %{status: "granted", subject_id: input.arguments.subject_id}}
        else
          {:error, :denied}
        end
      end)
    end
  end

  policies do
    bypass action(:reveal_assistant_conversation) do
      authorize_if(always())
    end

    policy action_type(:read) do
      authorize_if(Samen.Policy.OrgScope)
    end

    policy action_type([:create, :update, :destroy]) do
      forbid_unless(Samen.Policy.OrgScope)
      forbid_unless({Samen.Policy.RoleAtLeast, role: :member})
      authorize_if(always())
    end
  end
end
