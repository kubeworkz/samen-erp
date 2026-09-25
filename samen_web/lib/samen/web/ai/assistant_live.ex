defmodule Samen.Web.AI.AssistantLive do
  @moduledoc """
  Surface 7/7 of the tenant-plane AI UI kit — the ASSISTANT CHAT (OpenClaw-lite P1 → P2 tool-aware,
  ADR-043 §5.3 outside the verbs/agent overlap): named assistants + conversation threads
  over a vault-routed transcript, file-drop grounding, model picker, streaming, and
  honest empty states.

  ## Every assistant message routes through the chokepoint

  `Samen.Web.AI.Server.assistant_run/6` is the ONLY path a user message travels on:
  it re-resolves the assistant + conversation org-scoped from the TRUSTED mount scope,
  builds bounded history, and calls `Samen.AI.complete/4` with
  `provider: {Samen.AI.Provider.HuggingFace, %{org_id: org_id, model_id: ...}}` — the
  `Samen.AI.Chokepoint` masks vault-routed fields per §3.2, the adapter decrypts the
  tenant BYOK key in-memory (`Samen.Scopes.Ai.ApiKey` + `Crypto.decrypt/2`), and the
  response is carved as vault-routed `AssistantConversation.transcript` JSON. This module
  never touches `%Samen.AI.MaskedPayload{}` or any `Provider` callback directly, so the
  `ChokepointAntiBypassProbeTest` scan covers it exactly like any other `samen_web/lib`
  module (RP-AI-1).

  ## The vault transcript

  `Samen.AI.AssistantConversation.transcript` (`pii_asc_transcript` at the DB) is the
  run's chat history inside the DEK envelope keyed on the conversation's own id. It is
  the ONE 🔒 field this surface touches, so the three-proof MaskingCase applies:
  tenant plane CLEAR, operator-without-grant `••••` with no `vt_*` in the DOM, and a
  refutable sabotage twin. Read resolution is `Samen.Api.PiiResolution` on the actor's
  plane in `Samen.Web.AI.AssistantReads.get_conversation/3` — this module never
  hand-masks and never branches on plane (ADR-042).

  ## Auth / org-scope

  Every read is org-scoped from the TRUSTED scope (`Samen.Web.CurrentOrg.resolve/3`);
  `AssistantReads` after `handle_params` re-selects via `Samen.Web.CurrentOrg.reresolve/2`
  so a client `?org=` can only SELECT among the authenticated principal's authorized
  orgs (`TenantAuthz`'s pinned `:samen_authorized_orgs`, B-SEC/S1). A foreign org's
  thread does not exist (`:not_found`, no existence oracle, RP-AG-10).

  ## Honesty + streaming (ADR-014)

  A terminal `{:error, :not_configured}` renders `configuration_hint/0` VERBATIM via
  `ai_result/1` and links to `/settings/huggingface`. `{:ok, %Completion{simulated: true}}`
  renders the loud \"SIMULATED — not a real model\" badge from `%Completion{}.simulated`
  stamped at the ONE provider site (`Chokepoint`), never parsed from text. Streaming is
  the `{:hf_stream_chunk, text}` → `push_event(\"assistant:chunk\", …)` hook path the
  `Samen.Scopes.Ai.Streamer` already ships, debounced by model chunk cadence; a missed
  stream is not fabricated, and every paragraph enumerates the non-fabrication anyway.

  ADR-042 Class B: list/detail/turns/grounding render from `mount`/`load` with no socket;
  sends, creates, and renames are `phx-click`/`phx-submit` writes.
  """
  use Phoenix.LiveView

  import Samen.UI
  import Samen.Web.Live, only: [assign_mount: 2]
  import Samen.Web.CurrentOrg, only: [acting_as_banner: 1, no_org_card: 1, name: 2]
  import Samen.Web.AI.Components

  alias Samen.Web.AI.AgentReads
  alias Samen.Web.AI.AssistantReads
  alias Samen.Web.AI.Server
  alias Samen.Web.Mount

  @default_title "New conversation"

  @impl true
  def mount(params, session, socket) do
    socket = assign_mount(socket, session)
    mount = socket.assigns[:samen_mount]
    org_id = Samen.Web.CurrentOrg.resolve(mount, params, session)
    {:ok, load(socket, org_id, assistant_id: params["assistant_id"], conversation_id: params["id"] || params["conv_id"])}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    org_id = Samen.Web.CurrentOrg.reresolve(socket, params)
    {:noreply, load(socket, org_id, assistant_id: params["assistant_id"], conversation_id: params["id"] || params["conv_id"])}
  end

  @doc "The framework page-load seam (also the test entry point — no socket required)."
  def load(socket, org_id, opts \\ []) do
    mount = socket.assigns[:samen_mount]
    assistant_id = Keyword.get(opts, :assistant_id) || Keyword.get(opts, :assistant_id_param)
    conv_id = Keyword.get(opts, :conversation_id) || Keyword.get(opts, :conv_id)

    # Resolve which assistant is in view: explicit param wins; otherwise first.
    assistants = if org_id, do: Server.list_assistants(mount, org_id), else: []
    resolved_assistant_id = resolve_assistant_id(assistant_id, assistants)

    # The assistant row for the header / model badge / system-prompt label.
    assistant =
      case resolved_assistant_id && org_id && Server.get_assistant(mount, org_id, resolved_assistant_id) do
        {:ok, a} -> a
        _ -> nil
      end

    conversations =
      if org_id && resolved_assistant_id,
        do: AssistantReads.list_conversations(mount, org_id, resolved_assistant_id, []),
        else: []

    detail =
      case conv_id && org_id && AssistantReads.get_conversation(mount, org_id, conv_id) do
        {:ok, detail} -> detail
        _ -> nil
      end

    streaming = Keyword.get(opts, :streaming, socket.assigns[:streaming] || false)
    stream_buffer = Keyword.get(opts, :stream_buffer, socket.assigns[:stream_buffer] || "")
    # Preserve tool-aware run context across reloads (P2) — load/3 is the single
    # seam tests also drive without a socket, so these are assign-defaulted here
    # and updated only on send / approve / reject.
    pending_run = Keyword.get(opts, :assistant_run, socket.assigns[:assistant_run])
    pending_approval = Keyword.get(opts, :assistant_approval, socket.assigns[:assistant_approval])
    pending_provenance = Keyword.get(opts, :assistant_provenance, socket.assigns[:assistant_provenance])

    socket
    |> Phoenix.Component.assign(:org_id, org_id)
    |> Phoenix.Component.assign(:assistant_id, resolved_assistant_id)
    |> Phoenix.Component.assign(:conversation_id, conv_id)
    |> Phoenix.Component.assign(:assistants, assistants)
    |> Phoenix.Component.assign(:assistant, assistant)
    |> Phoenix.Component.assign(:conversations, conversations)
    |> Phoenix.Component.assign(:detail, detail)
    |> Phoenix.Component.assign(:input, Keyword.get(opts, :input, socket.assigns[:input] || ""))
    |> Phoenix.Component.assign(:streaming, streaming)
    |> Phoenix.Component.assign(:stream_buffer, stream_buffer)
    |> Phoenix.Component.assign(:outcome, Keyword.get(opts, :outcome, nil))
    |> Phoenix.Component.assign(:grounding, [])
    |> Phoenix.Component.assign(:assistant_run, pending_run)
    |> Phoenix.Component.assign(:assistant_approval, pending_approval)
    |> Phoenix.Component.assign(:assistant_provenance, pending_provenance)
    |> Phoenix.Component.assign(:available_tools, available_tools())
  end

  @impl true
  def handle_event("select-assistant", %{"assistant_id" => assistant_id}, socket) do
    _org_id = socket.assigns[:org_id]
    {:noreply, push_patch(socket, to: assistant_path(socket.assigns[:samen_mount], assistant_id, nil))}
  end

  def handle_event("select-conversation", %{"id" => conv_id}, socket) do
    assistant_id = socket.assigns[:assistant_id]
    {:noreply, push_patch(socket, to: assistant_path(socket.assigns[:samen_mount], assistant_id, conv_id))}
  end

  def handle_event("create-conversation", _params, socket) do
    mount = socket.assigns[:samen_mount]
    org_id = socket.assigns[:org_id]
    assistant_id = socket.assigns[:assistant_id]

    if is_nil(org_id) or is_nil(assistant_id) do
      {:noreply, socket}
    else
      case Server.create_conversation(mount, org_id, assistant_id, %{title: @default_title}) do
        {:ok, conv} ->
          {:noreply, push_patch(socket, to: assistant_path(mount, assistant_id, conv.id))}

        {:error, reason} ->
          {:noreply, Phoenix.Component.assign(socket, :outcome, {:error, format_error(reason)})}
      end
    end
  end

  def handle_event("create-assistant", params, socket) do
    mount = socket.assigns[:samen_mount]
    org_id = socket.assigns[:org_id]

    if is_nil(org_id) do
      {:noreply, socket}
    else
      tools = parse_tools_param(params["tools"] || params["assistant_tools"])

      attrs = %{
        name: present(params["assistant_name"]) || "assistant-#{System.unique_integer([:positive])}",
        title: present(params["assistant_title"]) || "New assistant",
        system_prompt: present(params["system_prompt"]) || "You are a helpful assistant.",
        model_id: present(params["model_id"]),
        tools: tools
      }

      case Server.create_assistant(mount, org_id, attrs) do
        {:ok, assistant} ->
          {:noreply, push_patch(socket, to: assistant_path(mount, assistant.id, nil))}

        {:error, %Ash.Error.Invalid{} = err} ->
          {:noreply, Phoenix.Component.assign(socket, :outcome, {:error, Exception.message(err)})}

        {:error, reason} ->
          {:noreply, Phoenix.Component.assign(socket, :outcome, {:error, format_error(reason)})}
      end
    end
  end

  def handle_event("send", %{"input" => input}, socket) do
    mount = socket.assigns[:samen_mount]
    org_id = socket.assigns[:org_id]
    assistant_id = socket.assigns[:assistant_id]
    conv_id = socket.assigns[:conversation_id]

    cond do
      is_nil(org_id) or is_nil(assistant_id) or is_nil(conv_id) ->
        {:noreply, Phoenix.Component.assign(socket, :outcome, {:error, "Pick a conversation first."})}

      String.trim(input) == "" ->
        {:noreply, Phoenix.Component.assign(socket, :outcome, {:error, "Type a message."})}

      true ->
        grounding = socket.assigns[:grounding] || []

        case Server.assistant_run(mount, org_id, assistant_id, conv_id, input, grounding: grounding) do
          {:ok, %{completion: completion, conversation: _updated} = ok} ->
            detail =
              case AssistantReads.get_conversation(mount, org_id, conv_id) do
                {:ok, d} -> d
                _ -> socket.assigns[:detail]
              end

            run = Map.get(ok, :run)
            awaiting? = Map.get(ok, :awaiting_approval, false)

            {pending_approval, provenance} =
              if awaiting? and not is_nil(run) do
                approval = AgentReads.pending_approval(org_id, run)
                {approval, AgentReads.provenance(approval)}
              else
                {nil, nil}
              end

            socket =
              socket
              |> Phoenix.Component.assign(:input, "")
              |> Phoenix.Component.assign(:outcome, {:ok, completion})
              |> Phoenix.Component.assign(:streaming, false)
              |> Phoenix.Component.assign(:stream_buffer, "")
              |> Phoenix.Component.assign(:detail, detail)
              |> Phoenix.Component.assign(:assistant_run, run)
              |> Phoenix.Component.assign(:assistant_approval, pending_approval)
              |> Phoenix.Component.assign(:assistant_provenance, provenance)

            socket =
              if is_binary(completion.text) and completion.text != "" do
                Phoenix.LiveView.push_event(socket, "assistant:chunk", %{text: completion.text})
              else
                socket
              end

            {:noreply, socket}

          {:error, {:budget_exhausted, %Samen.AI.Agent.Run{} = run}} ->
            {:noreply,
             socket
             |> Phoenix.Component.assign(:outcome, {:error, {:budget_exhausted, run.error_kind || "budget_exhausted"}})
             |> Phoenix.Component.assign(:assistant_run, run)
             |> Phoenix.Component.assign(:assistant_approval, nil)
             |> Phoenix.Component.assign(:assistant_provenance, nil)}

          {:error, {reason, %Samen.AI.Agent.Run{} = run}} when not is_nil(run) ->
            {:noreply,
             socket
             |> Phoenix.Component.assign(:outcome, {:error, normalize_error(reason)})
             |> Phoenix.Component.assign(:assistant_run, run)}

          {:error, {:invalid_tools, bad}} when is_list(bad) ->
            {:noreply,
             Phoenix.Component.assign(socket, :outcome, {:error, "Invalid tools: " <> Enum.join(bad, ", ") <> " — must be one of " <> Enum.join(available_tools(), ", ")})}

          {:error, reason} ->
            {:noreply, Phoenix.Component.assign(socket, :outcome, {:error, normalize_error(reason)})}
        end
    end
  end

  # P2 — the same decision card AgentLive renders, now on the assistant thread.
  # The approval id is validated against THIS run's own :proposed turn row before
  # the engine (id-discrimination, R-A5-5), and the acting principal is the
  # AUTHENTICATED human (samen_tenant_principal), never broker:<org>.
  def handle_event("approve", %{"id" => approval_id}, socket), do: decide(socket, :approve, approval_id)
  def handle_event("reject", %{"id" => approval_id}, socket), do: decide(socket, :reject, approval_id)

  defp decide(socket, action, approval_id) do
    mount = socket.assigns[:samen_mount]
    org_id = socket.assigns[:org_id]
    run = socket.assigns[:assistant_run]

    outcome =
      with %Samen.AI.Agent.Run{} <- run,
           %{id: ^approval_id} <- socket.assigns[:assistant_approval],
           {:principal, actor_id} when is_binary(actor_id) <- {:principal, principal_id(socket)} do
        classify(action, AgentReads.decide(action, approval_id, actor_id))
      else
        {:principal, _} ->
          {:error, "You must be signed in as a member of this org to decide a proposal."}

        _ ->
          # Fallback: re-read run-scoped pending (page reload where assigns were
          # not carried), still validated against the run's own pending.
          with %Samen.AI.Agent.Run{} = other_run <- run,
               %{id: ^approval_id} = _approval <- AgentReads.pending_approval(org_id, other_run),
               {:principal, actor_id} when is_binary(actor_id) <- {:principal, principal_id(socket)} do
            classify(action, AgentReads.decide(action, approval_id, actor_id))
          else
            {:principal, _} ->
              {:error, "You must be signed in as a member of this org to decide a proposal."}

            _ ->
              {:error, "That proposal is no longer pending for this run."}
          end
      end

    detail =
      case socket.assigns[:conversation_id] && org_id && AssistantReads.get_conversation(mount, org_id, socket.assigns[:conversation_id]) do
        {:ok, d} -> d
        _ -> socket.assigns[:detail]
      end

    {next_approval, next_prov} =
      case outcome do
        {:ok, _} -> {nil, nil}
        _ -> {socket.assigns[:assistant_approval], socket.assigns[:assistant_provenance]}
      end

    {:noreply,
     socket
     |> Phoenix.Component.assign(:outcome, outcome)
     |> Phoenix.Component.assign(:detail, detail)
     |> Phoenix.Component.assign(:assistant_approval, next_approval)
     |> Phoenix.Component.assign(:assistant_provenance, next_prov)}
  end

  defp principal_id(socket) do
    case socket.assigns[:samen_tenant_principal] do
      id when is_binary(id) and id != "" -> id
      _ -> stashed_principal(socket.assigns[:samen_mount])
    end
  end

  defp stashed_principal(%Mount{} = mount) do
    case Mount.label(mount, Samen.Web.TenantRole.principal_label(), nil) do
      id when is_binary(id) and id != "" -> id
      _ -> nil
    end
  end

  defp stashed_principal(_mount), do: nil

  defp classify(:approve, {:ok, _}), do: {:ok, "Approved — the write executed as you, inside the decision."}
  defp classify(:reject, {:ok, _}), do: {:ok, "Rejected — the run stopped and nothing was executed."}
  defp classify(_action, {:error, :self_approval}), do: {:error, "The requester of a proposal can never approve it."}
  defp classify(_action, {:error, :not_authorized}), do: {:error, "You are not a member of this org, so you cannot decide this proposal."}
  defp classify(_action, {:error, :approver_unresolvable}), do: {:error, "Approvals are not wired on this host — nothing was executed."}
  defp classify(_action, {:error, :not_pending}), do: {:error, "That proposal has already been decided."}
  defp classify(_action, {:error, {:tool_failed, kind}}), do: {:error, "The approved write failed (" <> to_string(kind) <> ") — the decision was rolled back and the proposal is still pending."}
  defp classify(_action, {:error, :proposal_mismatch}), do: {:error, "The proposal no longer matches what was approved — nothing was executed."}
  defp classify(_action, {:error, _}), do: {:error, "That decision could not be completed — nothing was executed."}

  # HF streamer forwards chunks as process messages while streaming is active — keep the
  # buffer in assigns so the render merges them into the last assistant bubble, and push
  # each chunk to the client hook. The hook is optional: with JS off the chat still
  # lands via the synchronous `assistant_run/6` path above, so streamed content is
  # enrichment, never the sole persistence path.
  @impl true
  def handle_info({:hf_stream_chunk, text}, socket) when is_binary(text) do
    buf = (socket.assigns[:stream_buffer] || "") <> text

    socket =
      socket
      |> Phoenix.Component.assign(:stream_buffer, buf)
      |> Phoenix.Component.assign(:streaming, true)
      |> Phoenix.LiveView.push_event("assistant:chunk", %{text: text})

    {:noreply, socket}
  end

  def handle_info({:hf_stream_done, _full}, socket) do
    {:noreply, Phoenix.Component.assign(socket, streaming: false)}
  end

  def handle_info({:hf_stream_error, reason}, socket) do
    {:noreply,
     socket
     |> Phoenix.Component.assign(:streaming, false)
     |> Phoenix.Component.assign(:outcome, {:error, reason})}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # ---------------------------------------------------------------------------
  # Routing helpers (route-table agnostic — build from ai_base label)
  # ---------------------------------------------------------------------------

  defp assistant_path(mount, assistant_id, conv_id) do
    base = ai_base(mount)

    cond do
      is_binary(conv_id) and conv_id != "" and is_binary(assistant_id) and assistant_id != "" ->
        "#{base}/assistant/#{assistant_id}/#{conv_id}"

      is_binary(assistant_id) and assistant_id != "" ->
        "#{base}/assistant/#{assistant_id}"

      true ->
        "#{base}/assistant"
    end
  end

  defp available_tools, do: Samen.AI.ToolSurface.names(:tenant)

  defp parse_tools_param(nil), do: []
  defp parse_tools_param(v) when is_list(v), do: Enum.filter(v, &is_binary/1) |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
  defp parse_tools_param(v) when is_binary(v) do
    v |> String.split([",", " "], trim: true) |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
  end
  defp parse_tools_param(_), do: []

  defp resolve_assistant_id(param_id, assistants) when is_binary(param_id) and param_id != "" do
    if Enum.any?(assistants, &(&1.id == param_id)), do: param_id, else: fallback_assistant_id(assistants)
  end

  defp resolve_assistant_id(_param, assistants), do: fallback_assistant_id(assistants)

  defp fallback_assistant_id([first | _]), do: first.id
  defp fallback_assistant_id([]), do: nil

  defp present(nil), do: nil
  defp present(""), do: nil
  defp present(v) when is_binary(v), do: String.trim(v) |> then(fn s -> if s == "", do: nil, else: s end)
  defp present(v), do: v

  defp format_error(:not_found), do: "Not found."
  defp format_error(:not_configured), do: :not_configured
  defp format_error(:no_org), do: "No org in scope."
  defp format_error(:assistant_cap_exceeded), do: "Assistant limit reached (4 per org)."
  defp format_error(:assistant_mismatch), do: "That conversation belongs to a different assistant."
  defp format_error(:empty_input), do: "Type a message."
  defp format_error(:invalid_assistant), do: "Pick an assistant first."
  defp format_error(:pii_egress_refused), do: :pii_egress_refused
  defp format_error(%Ash.Error.Invalid{} = err), do: Exception.message(err)
  defp format_error(other), do: inspect(other)

  # ---------------------------------------------------------------------------
  # Render
  # ---------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <.app_shell>
      <:sidebar>
        <.sidebar title={name(@samen_mount, @org_id)} subtitle="AI" logo={Mount.label(@samen_mount, :glyph, "AI")}>
          <.ai_sidebar_nav active={:assistant} base={ai_base(@samen_mount)} />
        </.sidebar>
      </:sidebar>

      <.topbar title="AI · Assistant" crumbs={["AI", "Assistant"]} />
      <.acting_as_banner mount={@samen_mount} org_id={@org_id} acting_as={@samen_acting_as} />
      <.ai_tabs active={:assistant} base={ai_base(@samen_mount)} />

      <%= if is_nil(@org_id) do %>
        <.no_org_card mount={@samen_mount} />
      <% else %>
        <div class="pane" id="ai-assistant" style="display:flex;gap:16px;padding:16px">
          <div class="card" id="assistant-rail" style="flex:0 0 280px;padding:12px;display:flex;flex-direction:column;gap:12px">
            <div style="display:flex;align-items:center;gap:8px">
              <b style="font-size:13px">Assistants</b>
              <span style="color:var(--muted);font-size:12px">({length(@assistants)}/4)</span>
            </div>
            <%= if @assistants == [] do %>
              <.empty_state title="No assistants yet" body="Create the first assistant for this org — or seed General." icon="✦" />
            <% else %>
              <ul id="assistant-list" style="list-style:none;margin:0;padding:0">
                <li :for={a <- @assistants} id={"assistant-#{a.id}"} class="assistant-row" data-name={a.name} style="padding:6px 4px;border-bottom:1px solid var(--line,#222)">
                  <a href={assistant_path(@samen_mount, a.id, nil)} id={"assistant-open-#{a.id}"} class={@assistant_id == a.id && "on"} style="font-size:13px">
                    {a.title} <span style="color:var(--muted)">({a.name})</span>
                  </a>
                  <span :if={a.model_id} style="margin-left:6px;color:var(--muted);font-size:11px">{a.model_id}</span>
                  <span :if={a.tools != []} style="margin-left:6px;color:var(--muted);font-size:11px" class="assistant-tools-badge" data-tools={Enum.join(a.tools, ",")} >tools: {Enum.join(a.tools, ", ")}</span>
                  <span :if={a.tools == []} style="margin-left:6px;color:var(--muted);font-size:11px" >no tools</span>
                </li>
              </ul>
            <% end %>

            <form phx-submit="create-assistant" id="assistant-create-form" class="card" style="padding:10px;display:flex;flex-direction:column;gap:6px">
              <span style="font-size:12px;font-weight:600">New assistant</span>
              <input type="text" name="assistant_name" placeholder="name (a-z0-9_.-)" style="font-size:12px" />
              <input type="text" name="assistant_title" placeholder="Title" style="font-size:12px" />
              <textarea name="system_prompt" rows="2" placeholder="System prompt" style="font-size:12px"></textarea>
              <input type="text" name="model_id" placeholder="model_id (optional)" style="font-size:12px" />
              <div style="display:flex;flex-direction:column;gap:4px">
                <span style="font-size:11px;color:var(--muted)">Tools (subset of tenant surface — leave empty for chat-only)</span>
                <div style="display:flex;flex-wrap:wrap;gap:6px">
                  <label :for={t <- @available_tools} style="font-size:12px;display:flex;gap:4px;align-items:center">
                    <input type="checkbox" name="tools[]" value={t} /> {t}
                  </label>
                </div>
                <span style="font-size:11px;color:var(--muted)">or comma-separated: </span>
                <input type="text" name="assistant_tools" placeholder="search_records, fetch_record" style="font-size:12px" />
              </div>
              <.button variant="secondary" type="submit" id="assistant-create">Create</.button>
            </form>

            <div style="display:flex;align-items:center;gap:8px">
              <b style="font-size:13px">Conversations</b>
              <.button variant="secondary" phx-click="create-conversation" id="assistant-conv-new">New</.button>
            </div>
            <%= if @assistant_id == nil do %>
              <div id="assistant-conv-empty" style="color:var(--muted);font-size:12px">Pick an assistant first.</div>
            <% else %>
              <%= if @conversations == [] do %>
                <.empty_state title="No conversations" body="Start a new thread under this assistant." icon="◷" />
              <% else %>
                <ul id="assistant-conv-list" style="list-style:none;margin:0;padding:0">
                  <li :for={c <- @conversations} id={"conv-#{c.id}"} class="conv-row" style="padding:6px 4px;border-bottom:1px solid var(--line,#222)">
                    <a href={assistant_path(@samen_mount, @assistant_id, c.id)} id={"conv-open-#{c.id}"} style="font-size:13px">{c.title}</a>
                    <span style="margin-left:6px;color:var(--muted);font-size:11px">{c.message_count} msgs</span>
                  </li>
                </ul>
              <% end %>
            <% end %>
          </div>

          <div class="card" id="assistant-main" style="flex:1;padding:12px;display:flex;flex-direction:column;gap:10px;min-width:0">
            <%= cond do %>
              <% is_nil(@assistant_id) -> %>
                <.empty_state title="Pick an assistant" body="Create one or pick an existing assistant to start a conversation." icon="✦" />
              <% is_nil(@conversation_id) -> %>
                <.empty_state title="Pick a conversation" body={"Start a new thread under #{(@assistant && @assistant.title) || "this assistant"}."} icon="◷" />
              <% is_nil(@detail) -> %>
                <.empty_state title="Conversation not found" body="That thread does not exist in this org." icon="?" />
              <% true -> %>
                <div style="display:flex;align-items:center;gap:8px;flex-wrap:wrap">
                  <.pill variant="info"><span id="assistant-conv-title">{@detail.title}</span></.pill>
                  <span :if={@assistant && @assistant.model_id} style="color:var(--muted);font-size:12px">model: {@assistant.model_id}</span>
                  <.pill :if={@assistant && @assistant.tools != []} variant="info"><span id="assistant-tools-active" data-tools={Enum.join(@assistant.tools, ",")}>tools: {Enum.join(@assistant.tools, ", ")}</span></.pill>
                  <span :if={@assistant_run} style="color:var(--muted);font-size:11px" id="assistant-run-id">run: {@assistant_run.id} · {@assistant_run.state}</span>
                  <a :if={@assistant_run} href={"/ai/agents/#{@assistant_run.id}"} style="font-size:11px">View run →</a>
                  <.pill :if={@detail.masked?} variant="warn"><span id="assistant-masked-badge">•••• masked transcript</span></.pill>
                </div>

                <div id="assistant-transcript" style="display:flex;flex-direction:column;gap:8px;min-height:180px">
                  <%= if @detail.turns == [] do %>
                    <.empty_state title="No messages yet" body="Say hello — history is re-scrubbed per turn (INV-7) and persists as a vault transcript." icon="💬" />
                  <% else %>
                    <div :for={t <- @detail.turns} class="assistant-turn" data-role={t["role"]} style="padding:8px 10px;border:1px solid var(--line,#222);border-radius:8px">
                      <span style="font-size:11px;color:var(--muted);text-transform:uppercase">{t["role"]}</span>
                      <pre class="assistant-turn-content" style="white-space:pre-wrap;margin:4px 0 0;font-size:13px">{t["content"]}</pre>
                    </div>
                  <% end %>

                  <div :if={@streaming and @stream_buffer != ""} id="assistant-stream" class="assistant-turn" data-role="assistant" style="padding:8px 10px;border:1px dashed var(--line,#444);border-radius:8px">
                    <span style="font-size:11px;color:var(--muted)">streaming…</span>
                    <pre class="assistant-turn-content" style="white-space:pre-wrap;margin:4px 0 0;font-size:13px">{@stream_buffer}</pre>
                  </div>
                </div>

                <div :if={@outcome} id="assistant-outcome" style="margin-top:4px">
                  <.ai_result result={normalize_outcome(@outcome)} id="assistant-result" />
                </div>

                <div :if={@assistant_approval} class="card" id="assistant-decision-card" data-approval={@assistant_approval.id} style="padding:14px;border-color:#F0B429">
                  <div style="display:flex;align-items:center;gap:8px">
                    <.pill variant="warn"><span id="assistant-decision-badge">Awaiting your decision</span></.pill>
                    <span style="color:var(--muted);font-size:12px">The assistant PROPOSED this write — it has not run without your approval (ADR-043 §6.2).</span>
                  </div>
                  <dl :if={@assistant_provenance} id="assistant-decision-provenance" style="margin:10px 0 0;font-size:13px">
                    <div><dt style="display:inline;color:var(--muted)">tool:</dt> <dd style="display:inline;margin:0" id="assistant-prov-tool">{@assistant_provenance.tool_kind}</dd></div>
                    <div><dt style="display:inline;color:var(--muted)">turn:</dt> <dd style="display:inline;margin:0" id="assistant-prov-turn">{@assistant_provenance.turn_index}</dd></div>
                    <div><dt style="display:inline;color:var(--muted)">arg keys:</dt> <dd style="display:inline;margin:0" id="assistant-prov-argkeys" class="mono">{Enum.join(@assistant_provenance.arg_keys, ", ")}</dd></div>
                    <div><dt style="display:inline;color:var(--muted)">args digest:</dt> <dd style="display:inline;margin:0" id="assistant-prov-digest" class="mono">{@assistant_provenance.args_digest}</dd></div>
                  </dl>
                  <p style="margin:8px 0 0;color:var(--muted);font-size:12px">
                    Only key NAMES + digest (never values — INV-1). Approving executes as you, once, inside the decision.
                    Deadline: <span id="assistant-decision-deadline">{@assistant_approval.deadline_at}</span>.
                  </p>
                  <div style="margin-top:10px;display:flex;gap:8px">
                    <.button variant="primary" phx-click="approve" phx-value-id={@assistant_approval.id} id="assistant-approve" data-confirm="Approve this write? It will execute once, as you.">Approve + execute</.button>
                    <.button variant="secondary" phx-click="reject" phx-value-id={@assistant_approval.id} id="assistant-reject">Reject</.button>
                  </div>
                </div>

                <form phx-submit="send" id="assistant-composer" class="card" style="display:flex;gap:8px;padding:10px;align-items:flex-end">
                  <textarea name="input" id="assistant-input" rows="3" placeholder="Type a message…" style="flex:1">{@input}</textarea>
                  <.button variant="primary" type="submit" id="assistant-send">Send</.button>
                </form>

                <div id="assistant-grounding" style="color:var(--muted);font-size:11px">
                  History: last {@detail.turns |> length()} turn(s) re-scrubbed per §3.2a. File-drop grounding (allowlisted catalog fields) rides the next turn as :grounding (EG1-scrubbed).
                </div>
            <% end %>
          </div>
        </div>
      <% end %>
    </.app_shell>
    """
  end

  defp normalize_outcome({:ok, %Samen.AI.Completion{} = c}), do: {:ok, c}
  defp normalize_outcome({:ok, %{completion: %Samen.AI.Completion{} = c}}), do: {:ok, c}
  defp normalize_outcome({:error, reason}) when is_atom(reason), do: {:error, reason}
  defp normalize_outcome({:error, reason}) when is_binary(reason), do: {:error, reason}
  defp normalize_outcome({:error, %Ash.Error.Invalid{} = err}), do: {:error, Exception.message(err)}
  defp normalize_outcome(other), do: other

  defp normalize_error(:not_configured), do: :not_configured
  defp normalize_error(:pii_egress_refused), do: :pii_egress_refused
  defp normalize_error(:unauthorized), do: :unauthorized
  defp normalize_error(reason) when is_atom(reason), do: format_error(reason)
  defp normalize_error(other), do: other
end
