defmodule Samen.AI.Assistant do
  @moduledoc """
  `Samen.AI.Assistant` — the OpenClaw-lite AI assistant definition
  (docs/plans/ai-assistant-openclaw-lite.md, P1).

  One row per assistant within an org (the General default plus up to three
  org-scoped custom assistants — the cap is enforced at the Server seam, not
  here, so this module stays a governed resource, not a policy actor).

  ## Tenancy / policy

  `Samen.Policy.OrgScope` on every read; create/update are org-scoped +
  member-or-above (`RoleAtLeast :member`). `Samen.AI.Domain` hosts the resource
  so a vertical mounts it by adding that domain to its `:ash_domains` (INV-5).

  ## PII governance

  `name` / `title` are bounded admin-authored labels; `system_prompt` is
  tenant free text guarded at write by `Samen.Pii.FreeTextScan` (the same
  tenant free-text chokepoint `Prompt` uses) and by the `vt_` sentinel
  refusal `Samen.AI.AssistantChange`. The resource adds no vault-routed
  column — its one sensitive concern (prompt shape) is a write-time scan.
  Grounding, history and file-drop context travel as chokepoint-scrubbed
  `MaskedPayload` segments, never as persisted columns here.

  ## Archival

  `archivable: true` — conversations already carry `archivable: true`; the
  assistant follows the same tier. A trashed assistant lists via the injected
  `archived` read. `destroy_permanently` is retained for GC/erasure paths.
  """

  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.AI.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "ast",
    archivable: true

  postgres do
    table("ai_assistant")
    repo(Application.compile_env(:samen_core, :samen_ai_assistant_repo, SamenCore.TestRepo))
  end

  attributes do
    # Bounded authored identifier (the `Samen.AI.Agent` `name` precedent:
    # ~r/\\A[a-z0-9][a-z0-9_.\\-]*\\z/). Enforced by AssistantChange.
    attribute(:name, :string, public?: true, allow_nil?: false)

    # Human display label.
    attribute(:title, :string, public?: true, allow_nil?: false)

    # The system/instruction prompt tenant authored for this assistant.
    # Write-governed: vt_ refusal + FreeTextScan (see actions).
    attribute(:system_prompt, :string, public?: true, allow_nil?: false)

    # The HuggingFace model this assistant defaults to
    # (e.g. meta-llama/Llama-3.1-8B-Instruct). An S100-style bounded id string
    # — no FK, so a model availability flip does not break the row. Empty means
    # "use the host/org default".
    attribute(:model_id, :string, public?: true, allow_nil?: true)

    # The allowed tool surfaces this assistant may surface in a future P2 turn
    # (T183 closed set — read in the Server seam, not here). Stored as plain
    # bounded label atoms rendered to text — no execution happens here.
    attribute(:tools, {:array, :string}, public?: true, allow_nil?: false, default: [])

    # Whether the assistant is active (visible to send against) or archived.
    attribute(:status, :atom,
      public?: true,
      allow_nil?: false,
      default: :active,
      writable?: false,
      constraints: [one_of: [:active, :archived]]
    )
  end

  identities do
    # One name per org — the `Samen.AI.Prompt` `name_version` precedent. A
    # second write with the same {org_id, name} is a DB-level conflict, not a
    # silent overwrite (belt to the change's braces).
    identity(:org_name, [:org_id, :name])
  end

  actions do
    defaults([:read])

    create :create_assistant do
      description("Create a tenant assistant (org-scoped, name unique per org).")
      accept([:org_id, :name, :title, :system_prompt, :model_id, :tools])
      change(Samen.AI.AssistantChange)
      change({Samen.Pii.FreeTextScan, fields: [:system_prompt]})
    end

    update :rename do
      accept([:title, :model_id, :tools, :system_prompt])
      require_atomic?(false)
      change(Samen.AI.AssistantChange)
      change({Samen.Pii.FreeTextScan, fields: [:system_prompt]})
    end
  end

  policies do
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
