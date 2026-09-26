defmodule Samen.Web.AI.Server do
  @moduledoc """
  The context seam behind the tenant-plane AI UI kit (T155, ADR-043 §5.3 ≈0-LOC adoption).
  Every AI LiveView in `Samen.Web.AI.*` calls THIS module; this module calls ONLY the
  `Samen.AI` kernel surfaces (`Samen.AI`, `Samen.AI.Verbs`, `Samen.AI.Embeddings`,
  `Samen.AI.Crm`, `Samen.AI.Analytics`, `Samen.AI.SupportOperator`) — never a
  `Samen.AI.Provider` callback and never `%Samen.AI.MaskedPayload{}`. So every
  provider-bound byte the UI produces routes through `Samen.AI.Chokepoint` by
  construction (INV-7): the full-tree `Samen.AI.ChokepointAntiBypassProbeTest` scans
  `samen_web/lib` too, so a raw provider call introduced here would flip it exactly
  like one in a verb module (RP-AI-1). The UI cannot become a PII-egress path the
  plane's chokepoint does not see. The assistant seam (`assistant_run/6`) also routes
  through `Samen.AI.complete/4` with a BYOK provider config — never a direct provider
  call.

  ## Scope is the caller's REAL scope (INV-2)

  Every function builds the scope from the mount's plane via `Samen.Web.Mount.scope/2` — the
  same actor every other framework read surface runs on. The AI plane never elevates: a
  tenant-plane mount reads clear over its OWN org (masked egress to the provider per §6.1);
  an operator-plane mount reads masked. No function here substitutes or synthesizes an actor.

  ## Org-scope pins (deny-by-default, drop-filter-flips-a-test)

  The two reads THIS module owns — `crm_preview/4` (the grounded record the CRM surface
  renders) and `list_drafts/2` — filter `org_id == ^org` from the TRUSTED scope, never from
  params. Dropping either filter flips a named cross-org test. The remaining reads
  (`search/3`, the CRM verbs, analytics) org-scope inside the kernel already.
  """

  alias Samen.AI
  alias Samen.AI.Assistant
  alias Samen.AI.AssistantConversation
  alias Samen.AI.Embeddings
  alias Samen.Web.Mount

  require Ash.Query

  @type result :: {:ok, Samen.AI.Completion.t()} | {:error, term()}

  @assistant_cap 4
  @max_history_turns 20
  @default_hf_model "mistralai/Mistral-7B-Instruct-v0.3"
  @assistant_agent Samen.AI.AssistantAgent
  @assistant_max_messages 100
  @assistant_max_tokens 60_000
  @assistant_recall_limit 5

  @doc "The verb names the Verbs surface exposes (the six ADR-043 §7.5 intelligence verbs)."
  @spec verbs() :: [atom()]
  def verbs, do: Samen.AI.Verbs.verbs()

  @doc """
  The human-facing provider-config pointer (`Samen.AI.configuration_hint/0`), rendered
  VERBATIM by every surface's `:not_configured` state. The machine error stays the bare
  `{:error, :not_configured}` atom — this is the additive DX guidance path, never the error
  term (T152).
  """
  @spec configuration_hint() :: String.t()
  def configuration_hint, do: AI.configuration_hint()

  # --- Verbs surface (the six verbs over free text / a record's pasted content) ------------

  @doc """
  Run one of the six verbs in the mount's scope over `input` (free text — the record's own
  content, §3.2 step 2d user-consented keystrokes). `params` are extra `{{key}}` template
  substitutions (e.g. `%{labels: \"billing, sales\"}` for classify). Returns the kernel
  `complete/4` result verbatim (fail-honest `{:error, :not_configured}` when unwired).
  """
  @spec run_verb(Mount.t(), String.t() | nil, atom(), String.t(), map(), keyword()) :: result()
  def run_verb(mount, org_id, verb, input, params \\ %{}, opts \\ [])
      when is_atom(verb) and is_binary(input) do
    Samen.AI.Verbs.run(verb, scope(mount, org_id), input, Keyword.merge([params: params], opts))
  end

  # --- Semantic search surface (T152 Hit snippets + the simulated ranking badge) -----------

  @doc """
  Org-scoped semantic search. Returns `{search_result, simulated?}` where `search_result`
  is `{:ok, [%Samen.AI.Embeddings.Hit{}]}` | `{:error, term()}` and `simulated?` is the
  T78/T152 honesty flag for the ranking (`Samen.AI.Embeddings.embedder_simulated?/1`) — the
  UI renders an honest \"simulated ranking\" badge from it, never a confident-looking real
  result. Cross-org rows are never ranked (the `Embeddings.search/3` `aie_org_id` filter).
  """
  @spec search(Mount.t(), String.t() | nil, String.t(), keyword()) ::
          {{:ok, [Embeddings.Hit.t()]} | {:error, term()}, boolean()}
  def search(mount, org_id, query, opts \\ []) when is_binary(query) do
    search_opts = Keyword.merge([repo: mount.repo], opts)
    result = Embeddings.search(scope(mount, org_id), query, search_opts)

    simulated? =
      case Embeddings.embedder_simulated?(search_opts) do
        {:ok, sim} -> sim
        {:error, _} -> false
      end

    {result, simulated?}
  end

  # --- CRM-AI surface (D6 helpers on a named record — masked-path, org-scoped) -------------

  @crm_helpers [:summarize_timeline, :classify_inbound, :recommend_next_step, :draft_sequence]

  @doc "The CRM-AI helper names the CRM surface exposes (ADR-043 §6.4)."
  @spec crm_helpers() :: [atom()]
  def crm_helpers, do: @crm_helpers

  @doc """
  Run a CRM-AI helper. `:classify_inbound` runs over free text (`input`); the other three
  ground on the named CRM `resource` + `id` (read org-scoped by `Samen.AI.Crm`, every
  vault-routed field `••••`-masked in the provider payload — grants never apply here).
  Returns the kernel result verbatim; for `:draft_sequence` a `{:ok, %{status: :draft, ...}}`.
  """
  @spec crm_run(Mount.t(), String.t() | nil, atom(), module() | nil, String.t(), String.t(), map()) ::
          result() | {:ok, %{status: :draft, body: String.t(), simulated: boolean()}}
  def crm_run(mount, org_id, helper, resource, id, input, params \\ %{})

  def crm_run(mount, org_id, :classify_inbound, _resource, _id, input, params) do
    Samen.AI.Crm.classify_inbound(scope(mount, org_id), input, params: params)
  end

  def crm_run(_mount, _org_id, _helper, resource, id, _input, _params)
      when is_nil(resource) or id == "" do
    {:error, :no_record}
  end

  def crm_run(mount, org_id, :summarize_timeline, resource, id, input, _params),
    do: Samen.AI.Crm.summarize_timeline(scope(mount, org_id), resource, id, input: input)

  def crm_run(mount, org_id, :recommend_next_step, resource, id, input, _params),
    do: Samen.AI.Crm.recommend_next_step(scope(mount, org_id), resource, id, input: input)

  def crm_run(mount, org_id, :draft_sequence, resource, id, input, _params),
    do: Samen.AI.Crm.draft_sequence(scope(mount, org_id), resource, id, input)

  @doc """
  A masking-safe preview of the CRM record the surface will ground on — read ORG-SCOPED
  (a hard `org_id == ^org` filter from the trusted scope, NEVER from params) and resolved
  through `Samen.Api.PiiResolution` on the mount's plane, exactly like every framework read
  surface. Returns `{:ok, resolved_record}` (a map of the public fields, vault-routed ones
  as `%Samen.Masked{}` on the operator plane) or `{:error, :not_found}`.

  ORG-SCOPE PIN: the `org_id == ^org` conjunct is the guarantee patch 141 flips — drop it and
  a caller can render another org's record on the AI grounding surface.
  """
  @spec crm_preview(Mount.t(), String.t() | nil, module() | nil, String.t()) ::
          {:ok, map()} | {:error, term()}
  def crm_preview(_mount, org_id, resource, id)
      when is_nil(org_id) or is_nil(resource) or id == "",
      do: {:error, :not_found}

  def crm_preview(mount, org_id, resource, id) do
    query =
      resource
      |> Ash.Query.filter(org_id == ^org_id and id == ^id)
      |> ensure_public_selected(resource)

    case Ash.read(query, authorize?: false) do
      {:ok, [record | _]} ->
        [resolved] =
          Samen.Api.PiiResolution.resolve(
            [record],
            resource,
            actor_of(scope(mount, org_id)),
            repo: mount.repo
          )

        {:ok, preview_fields(resolved, resource)}

      {:ok, []} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, {:read_failed, reason}}
    end
  rescue
    _ -> {:error, :not_found}
  end

  # --- Analytics surface (D7 token-blind ask box — operator/platform-gated by the kernel) --

  @doc """
  Ask a natural-language analytics question over `resource` (a `use Samen.Aggregate.Resource`
  projection). The read runs as the singleton token-blind aggregate actor with
  k-anon/l-diversity floors; the CALLER must hold a platform/operator capability
  (`Samen.AI.Analytics.ask/4`'s T144 deny-by-default gate). A tenant-plane caller is refused
  `{:error, :unauthorized}` fail-closed BEFORE any row is read — the surface renders that
  honestly, never a fabricated answer. Returns the kernel result verbatim.
  """
  @spec analytics_ask(Mount.t(), String.t() | nil, module() | nil, String.t()) :: result()
  def analytics_ask(_mount, _org_id, resource, _question) when is_nil(resource),
    do: {:error, :no_resource}

  def analytics_ask(mount, org_id, resource, question) when is_binary(question) do
    Samen.AI.Analytics.ask(scope(mount, org_id), resource, question)
  end

  # --- Support-draft surface (D5 compose — persists in a host that adopted Samen.AI.Domain) -

  @doc """
  Compose an AI support-reply draft: `Samen.AI.SupportOperator.draft_reply/3` grounds
  (masked), persists a `Samen.AI.SupportReplyDraft` row, and opens a PENDING `ai_support_reply`
  approval decided by a DISTINCT human — it NEVER sends. `attrs` must carry `:org_id`
  (injected from the trusted scope by the caller LiveView, never from client params) +
  `:to_subscriber_id`; optional `:inbound_ref`/`:subject`/`:source_resource`/`:source_id`.
  Fail-honest `{:error, :not_configured}` on an unwired provider; `{:error, ...}` when the
  host has not adopted `Samen.AI.Domain` (no draft repo/table) — the surface reports it truthfully.
  """
  @spec support_draft(Mount.t(), String.t() | nil, map(), keyword()) ::
          {:ok, term()} | {:error, term()}
  def support_draft(mount, org_id, attrs, opts \\ []) when is_map(attrs) do
    attrs = Map.put(attrs, :org_id, org_id)
    Samen.AI.SupportOperator.draft_reply(scope(mount, org_id), attrs, opts)
  rescue
    e -> {:error, {:persist_unavailable, Exception.message(e)}}
  end

  @doc """
  List this org's support-reply drafts (org-scoped read of `Samen.AI.SupportReplyDraft`).
  ORG-SCOPE PIN: the `org_id == ^org` filter is from the trusted scope; dropping it flips a
  named cross-org test (patch 142). Fail-safe `[]` when the host has not adopted the AI domain
  (no table/repo) — an empty list, NEVER another org's drafts.
  """
  @spec list_drafts(Mount.t(), String.t() | nil) :: [struct()]
  def list_drafts(_mount, nil), do: []

  def list_drafts(_mount, org_id) do
    Samen.AI.SupportReplyDraft
    |> Ash.Query.filter(org_id == ^org_id)
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.Query.limit(50)
    |> Ash.read(authorize?: false)
    |> case do
      {:ok, drafts} -> drafts
      {:error, _} -> []
    end
  rescue
    _ -> []
  end

  # --- Assistant surface (OpenClaw-lite P1 — tenant chat, org-scoped) ---------------------

  @doc """
  List this org's assistants (bounded labels, no vault field). ORG-SCOPE PIN:
  `org_id == ^org` is from the trusted scope; dropping it would cross-scope.
  """
  @spec list_assistants(Mount.t(), String.t() | nil) :: [struct()]
  def list_assistants(_mount, nil), do: []

  def list_assistants(_mount, org_id) when is_binary(org_id) do
    Assistant
    |> Ash.Query.filter(org_id == ^org_id)
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.Query.limit(20)
    |> Ash.read(authorize?: false)
    |> case do
      {:ok, rows} -> rows
      _ -> []
    end
  rescue
    _ -> []
  end

  @doc """
  Fetch one assistant, org-scoped. Returns `{:ok, assistant}` or `{:error, :not_found}`
  (no existence oracle — a foreign org's assistant does not exist).
  """
  @spec get_assistant(Mount.t(), String.t() | nil, String.t()) ::
          {:ok, struct()} | {:error, :not_found}
  def get_assistant(_mount, nil, _id), do: {:error, :not_found}

  def get_assistant(_mount, org_id, id) when is_binary(org_id) and is_binary(id) do
    Assistant
    |> Ash.Query.filter(org_id == ^org_id and id == ^id)
    |> Ash.Query.limit(1)
    |> Ash.read(authorize?: false)
    |> case do
      {:ok, [row]} -> {:ok, row}
      _ -> {:error, :not_found}
    end
  rescue
    _ -> {:error, :not_found}
  end

  def get_assistant(_mount, _org_id, _id), do: {:error, :not_found}

  @doc """
  Create an assistant in the org (org-scoped, name unique per org, `vt_` refused +
  `FreeTextScan` via the resource). Caps at 4 assistants per org — the Server seamowns the cap so the resource stays a governed resource, not a policy actor.
  """
  @spec create_assistant(Mount.t(), String.t() | nil, map()) ::
          {:ok, struct()} | {:error, term()}
  def create_assistant(_mount, nil, _attrs), do: {:error, :no_org}

  def create_assistant(mount, org_id, attrs) when is_binary(org_id) and is_map(attrs) do
    scope = scope(mount, org_id)

    with :ok <- check_assistant_cap(org_id) do
      attrs = Map.put(attrs, :org_id, org_id)

      Assistant
      |> Ash.Changeset.for_create(:create_assistant, attrs, scope: scope)
      |> Ash.create()
    end
  end

  @doc """
  List this org's conversations. When `assistant_id` is given, scoped to that
  assistant; otherwise all assistants in the org. Still org-scoped — never
  params. Delegates to `AssistantReads` after the PIN so LiveView need call
  only the Server seam.
  """
  @spec list_conversations(Mount.t(), String.t() | nil, String.t() | nil) :: [struct()]
  def list_conversations(_mount, nil, _assistant_id), do: []

  def list_conversations(mount, org_id, assistant_id) when is_binary(org_id) do
    alias Samen.Web.AI.AssistantReads

    case assistant_id do
      id when is_binary(id) and id != "" ->
        AssistantReads.list_conversations(mount, org_id, id, [])

      _ ->
        AssistantReads.list_all_conversations(mount, org_id, [])
    end
  end

  @doc """
  Open a conversation thread under one assistant in the org (the General default
  or a custom assistant). Validates the assistant belongs to the SAME org before
  persisting — a thread under a foreign org's assistant is refused.
  """
  @spec create_conversation(Mount.t(), String.t() | nil, String.t(), map()) ::
          {:ok, struct()} | {:error, term()}
  def create_conversation(_mount, nil, _assistant_id, _attrs), do: {:error, :no_org}

  def create_conversation(_mount, _org_id, assistant_id, _attrs)
      when not is_binary(assistant_id) or assistant_id == "",
      do: {:error, :invalid_assistant}

  def create_conversation(mount, org_id, assistant_id, attrs)
      when is_binary(org_id) and is_binary(assistant_id) do
    scope = scope(mount, org_id)

    with {:ok, _assistant} <- get_assistant(mount, org_id, assistant_id) do
      title = Map.get(attrs, :title) || Map.get(attrs, "title") || "New conversation"
      model_id = Map.get(attrs, :model_id) || Map.get(attrs, "model_id")

      transcript = Jason.encode!(%{"turns" => []})

      create_attrs = %{
        org_id: org_id,
        assistant_id: assistant_id,
        title: title,
        model_id: model_id,
        transcript: transcript
      }

      case AssistantConversation
           |> Ash.Changeset.for_create(:new_conversation, create_attrs, scope: scope)
           |> Ash.create() do
        {:ok, conv} ->
          _ = reindex_conversation(scope, conv)
          {:ok, conv}

        other ->
          other
      end
    end
  end

  @doc """
  Fetch one conversation with its transcript resolved on the mount's plane
  (delegates to `AssistantReads.get_conversation/3`).
  """
  @spec get_conversation(Mount.t(), String.t() | nil, String.t()) ::
          {:ok, map()} | {:error, :not_found}
  def get_conversation(_mount, nil, _id), do: {:error, :not_found}

  def get_conversation(mount, org_id, conv_id) when is_binary(conv_id) do
    Samen.Web.AI.AssistantReads.get_conversation(mount, org_id, conv_id)
  end

  # --- Assistant recall (P3 title-only, org-scoped HNSW, deterministic in CI) ---------------

  @doc """
  Recall conversations for an assistant via title embeddings (P3 title-only recall).

  The vector sidecar is CANDIDATE RETRIEVAL ONLY: every hit is RE-VERIFIED against
  the caller's own org-scoped `AssistantConversation` read (defense in depth — the
  `KbReads` pattern, generalized to the assistant's own title field). Stale or
  over-broad vectors can never surface another org's thread or a thread under a
  different assistant. Honest states, never a fabricated suggestion:

    * `:ok` — real hits (embedder configured, `simulated: false`) or the keyless
      `:test`-only deterministic ranking (`simulated: true`, clearly signposted —
      T152 via `Embeddings.embedder_simulated?/1`).
    * `:empty` — embedder ran, found nothing (never a match-all default).
    * `:not_configured` — no embedder wired; `configuration_hint` carries
      `Samen.AI.configuration_hint()` verbatim.
  """
  @spec assistant_recall(Mount.t(), String.t() | nil, String.t() | nil, String.t(), keyword()) ::
          map()
  def assistant_recall(mount, org_id, assistant_id, query, opts \\ [])
  def assistant_recall(_mount, nil, _assistant_id, _query, _opts), do: %{state: :empty, hits: []}
  def assistant_recall(_mount, _org_id, _assistant_id, query, _opts)
      when not is_binary(query) or query == "",
      do: %{state: :empty, hits: []}

  def assistant_recall(mount, org_id, assistant_id, query, opts)
      when is_binary(org_id) and is_binary(query) do
    scope = scope(mount, org_id)
    search_opts = Keyword.merge([repo: mount.repo, limit: @assistant_recall_limit], opts)

    case Embeddings.search(scope, query, search_opts) do
      {:ok, []} ->
        %{state: :empty, hits: [], simulated: false}

      {:ok, raw_hits} ->
        {:ok, simulated} = simulated_or_false(Embeddings.embedder_simulated?(search_opts))
        by_id = Map.new(raw_hits, &{&1.source_id, &1})
        hit_ids = Enum.map(raw_hits, & &1.source_id)

        rows =
          case reverify_conversations(org_id, assistant_id, hit_ids) do
            {:ok, rows} -> rows
            _ -> []
          end

        # Preserve rank order (nearest first) — the refetch does not.
        ordered =
          rows
          |> Enum.sort_by(&Map.get(by_id, &1.id).distance)

        if ordered == [] do
          %{state: :empty, hits: [], simulated: simulated}
        else
          %{
            state: :ok,
            simulated: simulated,
            hits:
              Enum.map(ordered, fn c ->
                %{conversation: c, snippet: Map.get(by_id, c.id).snippet}
              end)
          }
        end

      {:error, :not_configured} ->
        %{
          state: :not_configured,
          hits: [],
          configuration_hint: Samen.AI.configuration_hint()
        }

      {:error, _} ->
        %{state: :error, hits: []}
    end
  end

  @doc """
  Per-assistant usage roll-up (P3 counter roll-up, no new table).

  Sums `AssistantConversation` counters (`message_count`, `total_tokens`) for one
  assistant in the org and derives an honest cost estimate via
  `Samen.Scopes.Ai.Analytics.estimate_cost/2` — no new table, no fabricated cost
  (zero tokens ⇒ zero cost). The Live header renders this; it is also the budget
  denominator for the thread caps below.
  """
  @spec assistant_usage(Mount.t(), String.t() | nil, String.t() | nil) :: map()
  def assistant_usage(_mount, nil, _assistant_id),
    do: %{conversation_count: 0, message_count: 0, total_tokens: 0, estimated_cost: 0.0}

  def assistant_usage(_mount, _org_id, nil),
    do: %{conversation_count: 0, message_count: 0, total_tokens: 0, estimated_cost: 0.0}

  def assistant_usage(_mount, org_id, assistant_id)
      when is_binary(org_id) and is_binary(assistant_id) do
    rows =
      AssistantConversation
      |> Ash.Query.filter(org_id == ^org_id and assistant_id == ^assistant_id)
      |> Ash.read(authorize?: false)
      |> case do
        {:ok, rows} -> rows
        _ -> []
      end

    conversation_count = length(rows)

    message_count =
      Enum.reduce(rows, 0, fn r, acc -> acc + (Map.get(r, :message_count) || 0) end)

    total_tokens =
      Enum.reduce(rows, 0, fn r, acc -> acc + (Map.get(r, :total_tokens) || 0) end)

    estimated_cost = Samen.Scopes.Ai.Analytics.estimate_cost(total_tokens, 0)

    %{
      conversation_count: conversation_count,
      message_count: message_count,
      total_tokens: total_tokens,
      estimated_cost: estimated_cost
    }
  rescue
    _ -> %{conversation_count: 0, message_count: 0, total_tokens: 0, estimated_cost: 0.0}
  end

  @doc """
  The P1 chat seam: append a user turn, call the model through the chokepoint,
  and persist the assistant turn — every provider byte routes through
  `Samen.AI.Chokepoint` by construction (INV-7).

  * Reads the assistant + conversation org-scoped (both must be in `org_id`).
  * Builds history from the vault-resolved transcript (bounded to last 20 turns,
    re-scrubbed per §3.2a).
  * Calls `Samen.AI.complete/4` with `provider: {HuggingFace, %{org_id: org_id, model_id: ...}}`
    — the BYOK key is resolved inside the provider via `Samen.Scopes.Ai.ApiKey` +
    `Crypto.decrypt/2`; if unwired → `{:error, :not_configured}` verbatim (fail-honest).
  * Persists both turns to the vault `transcript` JSON (`append_turn`), bumps
    `message_count`/`total_tokens`/`last_message_at`, and auto-titles a blank
    conversation via `Samen.AI.Verbs` (best-effort, never a failure).
  * Returns `{:ok, %{completion: completion, conversation: updated}}` or an error.

  `input` is free text (user keystrokes, §3.2 step 2). Optional `opts[:grounding]`
  (allowlisted catalog fields + file context chips) threads through to the chokepoint.
  Never touches `%MaskedPayload{}` or `Provider` directly.
  """
  @spec assistant_run(Mount.t(), String.t() | nil, String.t(), String.t(), String.t(), keyword()) ::
          {:ok, %{completion: Samen.AI.Completion.t(), conversation: struct()}}
          | {:error, term()}
  def assistant_run(mount, org_id, assistant_id, conv_id, input, opts \\ [])
  def assistant_run(_mount, nil, _assistant_id, _conv_id, _input, _opts), do: {:error, :no_org}

  def assistant_run(mount, org_id, assistant_id, conv_id, input, opts)
      when is_binary(org_id) and is_binary(assistant_id) and is_binary(conv_id) and
             is_binary(input) do
    trimmed = String.trim(input)

    if trimmed == "" do
      {:error, :empty_input}
    else
      do_assistant_run(mount, org_id, assistant_id, conv_id, trimmed, opts)
    end
  end

  defp do_assistant_run(mount, org_id, assistant_id, conv_id, input, opts) do
    scope = scope(mount, org_id)

    with {:ok, assistant} <- get_assistant(mount, org_id, assistant_id),
         {:ok, %{conversation: conv, turns: prior_turns}} <- get_conversation(mount, org_id, conv_id),
         :ok <- ensure_same_assistant(conv, assistant_id),
         :ok <- check_conversation_budget(conv) do
      if tool_aware?(assistant) do
        do_tool_aware_run(mount, org_id, scope, assistant, conv, prior_turns, input, opts)
      else
        with {:ok, completion} <- complete_for_assistant(scope, assistant, prior_turns, input, opts),
             {:ok, updated} <- persist_turns(conv, prior_turns, input, completion, scope) do
          _ = maybe_autotitle(conv, updated, scope, input)
          {:ok, %{completion: completion, conversation: updated}}
        end
      end
    end
  end

  defp tool_aware?(assistant) do
    case Map.get(assistant, :tools) do
      tools when is_list(tools) and tools != [] -> true
      _ -> false
    end
  end

  defp do_tool_aware_run(_mount, org_id, scope, assistant, conv, prior_turns, input, opts) do
    system_prompt = Map.get(assistant, :system_prompt) || ""
    history = history_segments(prior_turns)
    goal = build_agent_goal(system_prompt, history, input)
    model_id = Map.get(assistant, :model_id) || @default_hf_model
    base_provider = {Samen.AI.Provider.HuggingFace, %{org_id: org_id, model_id: model_id}}
    provider = Keyword.get(opts, :provider, base_provider)
    grounding = Keyword.get(opts, :grounding, [])

    with :ok <- validate_assistant_tools_subset(assistant) do
      origin = "assistant:#{assistant.id}"
      caller_opts = Keyword.take(opts, [:meta, :env_reader, :hooks])

      # Per-assistant narrowing (P2): AssistantAgent declares the maximal :tenant
      # surface — the row declares a SUBSET. Without this hook the model would be
      # OFFERED the superset. The hook rides this process (run/4 is synchronous),
      # so the allowlist in the dict is per-run; nil/missing defers (non-assistant
      # runs unaffected).
      per_run_hooks =
        (Keyword.get(caller_opts, :hooks, []) |> List.wrap()) ++ [Samen.AI.AssistantToolFilter]

      agent_opts =
        caller_opts
        |> Keyword.put(:provider, provider)
        |> Keyword.put(:grounding, grounding)
        |> Keyword.put(:origin, origin)
        |> Keyword.put(:hooks, per_run_hooks)

      Process.put(:assistant_allowed_tools, assistant.tools || [])

      result =
        try do
          Samen.AI.Agent.run(@assistant_agent, scope, goal, agent_opts)
        after
          Process.delete(:assistant_allowed_tools)
        end

      handle_agent_result(result, conv, prior_turns, input, scope)
    end
  end

  defp build_agent_goal(system_prompt, history, input) do
    history_block =
      case history do
        [] -> ""
        lines -> "Conversation history (last #{length(lines)} turn(s)):\n" <> Enum.join(lines, "\n") <> "\n\n"
      end

    system_block =
      case String.trim(system_prompt) do
        "" -> ""
        prompt -> prompt <> "\n\n"
      end

    system_block <> history_block <> "User: #{input}"
  end

  defp validate_assistant_tools_subset(assistant) do
    allowed = MapSet.new(@assistant_agent.definition().tools)
    declared = MapSet.new(assistant.tools || [])

    if MapSet.subset?(declared, allowed) do
      :ok
    else
      bad = declared |> MapSet.difference(allowed) |> MapSet.to_list() |> Enum.sort()
      {:error, {:invalid_tools, bad}}
    end
  end

  defp handle_agent_result(result, conv, prior_turns, input, scope) do
    case result do
      {:ok, %{answer: answer, run: run}} when is_binary(answer) ->
        completion = %Samen.AI.Completion{
          text: answer,
          provider: :assistant,
          simulated: simulated_from_run(run),
          usage: %{},
          meta: %{agent_run_id: run.id}
        }

        with {:ok, updated} <- persist_turns(conv, prior_turns, input, completion, scope) do
          {:ok, %{completion: completion, conversation: updated, run: run}}
        end

      {:awaiting_approval, %Samen.AI.Agent.Run{} = run} ->
        placeholder = %Samen.AI.Completion{
          text: "Proposal pending approval — see Agent runs for decision (run #{run.id}).",
          provider: :assistant,
          simulated: true,
          usage: %{},
          meta: %{agent_run_id: run.id, awaiting_approval: true}
        }

        with {:ok, updated} <- persist_turns(conv, prior_turns, input, placeholder, scope) do
          {:ok,
           %{
             completion: placeholder,
             conversation: updated,
             run: run,
             awaiting_approval: true
           }}
        end

      {:awaiting_approval, run} ->
        {:ok, %{run: run, awaiting_approval: true, conversation: conv}}

      {:error, :budget_exhausted, run} ->
        {:error, {:budget_exhausted, run}}

      {:error, reason, run} when not is_nil(run) ->
        {:error, {reason, run}}

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:unexpected_agent_result, other}}
    end
  end

  defp simulated_from_run(%{id: _} = _run), do: true
  defp simulated_from_run(_), do: false

  # --- completion (the chokepoint caller — the only provider path) ----------------------

  defp complete_for_assistant(scope, assistant, prior_turns, input, opts) do
    system_prompt = Map.get(assistant, :system_prompt) || ""
    history = history_segments(prior_turns)
    model_id = Map.get(assistant, :model_id) || @default_hf_model
    org_id = scope_org_id(scope)

    prompt_ref = if system_prompt != "", do: [system_prompt, input], else: [input]

    provider = {Samen.AI.Provider.HuggingFace, %{org_id: org_id, model_id: model_id}}

    complete_opts =
      opts
      |> Keyword.take([:grounding, :meta])
      |> Keyword.put(:provider, provider)
      |> Keyword.put(:history, history)

    Samen.AI.complete(scope, prompt_ref, %{}, complete_opts)
  end

  defp history_segments(turns) when is_list(turns) do
    turns
    |> Enum.take(-@max_history_turns)
    |> Enum.map(fn turn ->
      content = Map.get(turn, "content") || Map.get(turn, :content) || ""
      to_string(content)
    end)
    |> Enum.reject(&(&1 == ""))
  end

  defp history_segments(_), do: []

  defp scope_org_id(%Samen.Scope{actor: %{org_id: org_id}}) when is_binary(org_id), do: org_id
  defp scope_org_id(%{actor: %{org_id: org_id}}) when is_binary(org_id), do: org_id
  defp scope_org_id(%{org_id: org_id}) when is_binary(org_id), do: org_id
  defp scope_org_id(_), do: nil

  # --- persistence (vault transcript is the ONE text artifact) --------------------------

  defp persist_turns(conv, prior_turns, input, %Samen.AI.Completion{} = completion, scope) do
    prior = prior_turns |> Enum.filter(&is_map/1)
    now = DateTime.utc_now()

    new_turns =
      prior ++
        [%{"role" => "user", "content" => input, "at" => DateTime.to_iso8601(now)}] ++
        [%{"role" => "assistant", "content" => completion.text, "at" => DateTime.to_iso8601(now)}]

    transcript = Jason.encode!(%{"turns" => new_turns})
    usage_tokens = estimate_tokens(completion)

    result =
      conv
      |> Ash.Changeset.for_update(:append_turn, %{
        transcript: transcript,
        message_count: length(new_turns),
        total_tokens: (Map.get(conv, :total_tokens) || 0) + usage_tokens,
        last_message_at: now
      })
      |> Ash.update(scope: scope)

    case result do
      {:ok, updated} ->
        _ = reindex_conversation(scope, updated)
        {:ok, updated}

      other ->
        other
    end
  end

  defp estimate_tokens(%Samen.AI.Completion{text: text, usage: usage}) do
    cond do
      is_map(usage) and is_integer(Map.get(usage, :total_tokens)) -> Map.get(usage, :total_tokens)
      is_map(usage) and is_integer(Map.get(usage, :output_tokens)) -> Map.get(usage, :output_tokens)
      is_binary(text) -> div(String.length(text), 4) + 1
      true -> 1
    end
  end

  defp ensure_same_assistant(conv, assistant_id) do
    if Map.get(conv, :assistant_id) == assistant_id, do: :ok, else: {:error, :assistant_mismatch}
  end

  defp check_assistant_cap(org_id) do
    count =
      Assistant
      |> Ash.Query.filter(org_id == ^org_id)
      |> Ash.read(authorize?: false)
      |> case do
        {:ok, rows} -> length(rows)
        _ -> 0
      end

    if count >= @assistant_cap, do: {:error, :assistant_cap_exceeded}, else: :ok
  rescue
    _ -> :ok
  end

  defp maybe_autotitle(conv, updated, scope, input) do
    title = Map.get(conv, :title) || ""
    blank? = title == "" or title == "New conversation"
    first_turn? = (Map.get(conv, :message_count) || 0) == 0

    if blank? and first_turn? do
      case Samen.AI.Verbs.run(:generate, scope, "Generate a 3-5 word title for this conversation: #{input}. Respond with title only.") do
        {:ok, %Samen.AI.Completion{text: text}} when is_binary(text) and text != "" ->
          short = text |> String.trim() |> String.slice(0, 60) |> String.trim()

          if short != "" do
            case updated
                 |> Ash.Changeset.for_update(:rename, %{title: short})
                 |> Ash.update(scope: scope) do
              {:ok, renamed} ->
                _ = reindex_conversation(scope, renamed)
                :ok

              _ ->
                :ok
            end
          else
            :ok
          end

        _ ->
          :ok
      end
    else
      :ok
    end
  rescue
    _ -> :ok
  end

  # --- P3 helpers: recall re-verify + budgets + best-effort reindex --------------------

  defp simulated_or_false({:ok, bool}) when is_boolean(bool), do: {:ok, bool}
  defp simulated_or_false(_), do: {:ok, false}

  defp reverify_conversations(org_id, assistant_id, hit_ids) when is_list(hit_ids) do
    query =
      case assistant_id do
        id when is_binary(id) and id != "" ->
          AssistantConversation
          |> Ash.Query.filter(org_id == ^org_id and assistant_id == ^id and id in ^hit_ids)

        _ ->
          AssistantConversation
          |> Ash.Query.filter(org_id == ^org_id and id in ^hit_ids)
      end

    case Ash.read(query, authorize?: false) do
      {:ok, rows} -> {:ok, rows}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, e}
  end

  defp check_conversation_budget(conv) do
    message_count = Map.get(conv, :message_count) || 0
    total_tokens = Map.get(conv, :total_tokens) || 0

    cond do
      message_count >= @assistant_max_messages ->
        {:error, :budget_exhausted}

      total_tokens >= @assistant_max_tokens ->
        {:error, :budget_exhausted}

      true ->
        :ok
    end
  end

  # Best-effort title reindex (P3) — never blocks a write on embedding availability.
  # Mirrors KbReads.reindex/2: :not_configured / any error is swallowed (honest
  # degradation — the conversation still saved, simply not yet semantically searchable).
  defp reindex_conversation(scope, %{__struct__: resource} = conv) when resource == AssistantConversation do
    # Only the allowlisted non-PII :title is embedded (vault :transcript never is,
    # §7.2 — Embeddings.assert_embeddable/2 + ai_prompt_masking verifier).
    Embeddings.embed_record(scope, conv, resource, [])
    :ok
  rescue
    _ -> :ok
  end

  defp reindex_conversation(_scope, _conv), do: :ok

  # --- shared helpers ----------------------------------------------------------------------

  @doc "The `%Samen.Scope{}` for the mount's plane over `org_id` (the framework read seam)."
  @spec scope(Mount.t(), String.t() | nil) :: Samen.Scope.t()
  def scope(%Mount{} = mount, org_id), do: Mount.scope(mount, org_id)

  defp actor_of(%Samen.Scope{actor: actor}), do: actor
  defp actor_of(other), do: other

  defp ensure_public_selected(query, resource) do
    case public_field_names(resource) do
      [] -> query
      fields -> Ash.Query.ensure_selected(query, fields)
    end
  end

  defp preview_fields(record, resource) do
    resource
    |> public_field_names()
    |> Map.new(fn f -> {f, Map.get(record, f)} end)
    |> Map.put(:__id__, Map.get(record, :id))
  end

  defp public_field_names(resource) do
    resource |> Ash.Resource.Info.public_attributes() |> Enum.map(& &1.name)
  rescue
    _ -> []
  end
end
