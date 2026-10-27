defmodule Samen.Web.Operator.ReplayLive do
  @moduledoc """
  Framework OPERATOR / per-tenant **Replay** at `/operator/replay/:org_id` — the support
  screen where an operator watches a tenant's recorded session back, step by step.

  Reached from the account drill-down's "Replay →" link, with the same org_id-keyed,
  no-separate-index shape as `DeliverabilityLive` / `AutomationHealthLive` / `ActivityLive`,
  and the same T150 deny-on-read gate: reading one tenant's session is a per-tenant drill-in,
  so it requires a reason-required, short-TTL `Samen.Impersonation` session that lands in the
  tenant's ledger. The ONE `phx-submit` on the page is that open-session affordance, rendered
  exclusively on the deny state.

  ## What is being replayed (stated ON the page, not just in this comment)

  The timeline is the `nav.visited` / product-event ledger (`Samen.Web.Operator.ReplayReads` over
  `Samen.Analytics.Replay`'s captures): WHICH surface a session opened, when, and which
  registered product events fired in between. It is deliberately NOT a screen recording —
  no DOM, no keystrokes, no form values, no screenshots, no URL. An operator reading this page
  is told that in the `#replay-scope-note` block, so nobody mistakes a step list for a video.

  ## Token-blind by construction (INV-1)

  Every value this page renders comes from a column whose capture path refuses PII outright
  (ADR-021 §5): a bounded org id, a registered event-name enum, a bounded surface token, an
  opaque entity ref, a per-subject HMAC pseudonym, a timestamp, and reader-composed labels
  (`"Opened Broker"`). There is no vault-routed field on this surface, so there is no
  `%Masked{}` branch and no reveal path to get wrong — proven by the no-plaintext DOM probe
  plus its refutable sabotage twin in `operator_replay_test.exs` (the ADR-038 §5.5 discipline
  for a fully token-blind store, in place of the `Samen.MaskingCase` three-proof that a 🔒
  field would require).

  ## The player

  A replay is played with a **playhead**: the operator selects a session, then plays, pauses,
  steps, seeks, or changes speed. The playhead advances on a `Process.send_after/3` tick while
  `playing` is true — pure server state, no client JS, so the whole player works on a Class B
  render and is driven in tests by `render_click` + a synthetic `:tick`.

  ## Fail-honest

  `ReplayReads.replay/3` distinguishes "this org's ledger answered: no sessions" from "the
  ledger could not be read at all" (`:not_configured` / `:read_failed` / `:no_org`), and this
  page renders the second as `<.unread_state>` — "no sessions recorded" is a claim about the
  DATA, and a read that raised never observed it (ADR-014/024/026).
  """

  use Phoenix.LiveView

  import Samen.UI
  import Samen.Web.Operator.Live

  alias Samen.Web.Crumbs
  alias Samen.Web.Operator
  alias Samen.Web.Operator.Impersonation
  alias Samen.Web.Operator.ReplayReads

  @tick_ms %{slow: 1_200, normal: 700, fast: 300}

  @impl true
  def mount(params, session, socket) do
    socket =
      socket
      |> assign_mount(session)
      |> Impersonation.assign_identity(session, params)

    {:ok, load(socket, Map.get(params, "org_id"), window_hours_param(params), selected: Map.get(params, "session"))}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    org_id = Map.get(params, "org_id") || socket.assigns[:org_id]

    {:noreply,
     load(socket, org_id, window_hours_param(params),
       selected: Map.get(params, "session"),
       playhead: socket.assigns[:playhead]
     )}
  end

  @impl true
  def handle_event("select", %{"ref" => ref}, socket) do
    {:noreply, assign(socket, selected_ref: ref, playhead: 0, playing: false)}
  end

  def handle_event("play", _params, socket) do
    socket = if playing?(socket), do: socket, else: schedule_tick(assign(socket, playing: true))
    {:noreply, socket}
  end

  def handle_event("pause", _params, socket) do
    {:noreply, assign(socket, playing: false)}
  end

  def handle_event("seek", %{"index" => index}, socket) do
    {:noreply, assign(socket, playhead: clamp(index, socket))}
  end

  def handle_event("step", %{"dir" => dir}, socket) do
    {:noreply, assign(socket, playing: false, playhead: move(dir, socket))}
  end

  def handle_event("speed", %{"speed" => speed}, socket) do
    {:noreply, assign(socket, speed: speed_of(speed))}
  end

  def handle_event("open_session", %{"reason" => reason}, socket) do
    org_id = socket.assigns[:org_id]

    case Impersonation.open_from_socket(socket, org_id, reason) do
      {:ok, _session} ->
        {:noreply,
         load(socket, org_id, socket.assigns[:window_hours_param], playhead: socket.assigns[:playhead])}

      {:error, reason} ->
        {:noreply, assign(socket, open_error: open_error_copy(reason))}
    end
  end

  @impl true
  def handle_info(:tick, socket) do
    socket =
      if playing?(socket) do
        # `move/2` CLAMPS at the last step, so "the next index equals the current one" IS the
        # end of the session — the tick then stops the player instead of rescheduling forever.
        next = move("next", socket)

        if next == (socket.assigns[:playhead] || 0) do
          assign(socket, playing: false)
        else
          socket |> assign(playhead: next) |> schedule_tick()
        end
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  # -- state ------------------------------------------------------------------

  defp playing?(socket), do: socket.assigns[:playing] == true

  # The last index the playhead may occupy for the selected session (0 for a one-step session).
  defp last_index(socket), do: max(length(socket.assigns[:steps] || []) - 1, 0)

  defp clamp(index, socket) when is_integer(index), do: index |> max(0) |> min(last_index(socket))

  defp clamp(index, socket) when is_binary(index) do
    case Integer.parse(index) do
      {index, _} -> clamp(index, socket)
      :error -> socket.assigns[:playhead] || 0
    end
  end

  defp clamp(_index, socket), do: socket.assigns[:playhead] || 0

  defp move("prev", socket), do: max((socket.assigns[:playhead] || 0) - 1, 0)

  defp move(_dir, socket) do
    playhead = socket.assigns[:playhead] || 0
    min(playhead + 1, last_index(socket))
  end

  defp schedule_tick(socket) do
    Process.send_after(self(), :tick, Map.get(@tick_ms, socket.assigns[:speed] || :normal))
    socket
  end

  defp speed_of("slow"), do: :slow
  defp speed_of("fast"), do: :fast
  defp speed_of(_), do: :normal

  defp window_hours_param(params), do: Map.get(params, "window_hours")

  defp open_error_copy(:reason_required), do: "A reason for access is required."
  defp open_error_copy(:not_authorized), do: "Your operator role may not open an impersonation session."
  defp open_error_copy({:pii_shaped_reason, _}), do: "The reason must name the ticket, not the person."
  defp open_error_copy(_), do: "The impersonation session could not be opened."

  @doc false
  # The single load path for `mount/3`, `handle_params/3` and the open-session handler.
  #
  # `opts` carries the sanctioned clock-free injection seam `:replay` — a manufactured
  # `ReplayReads.replay/3` payload — used ONLY by the masking sabotage twin to prove the page's
  # DOM scan is refutable without standing up a live ledger fixture. Production mount /
  # handle_params never pass it, so the REAL read decides.
  def load(socket, org_id, window_hours, opts \\ []) do
    mount = socket.assigns[:samen_mount]

    # ONE lookup serves BOTH the "← Account" back-link and the breadcrumb's tenant name, and it
    # is assigned up front so every branch below (deny / out-of-scope / active / the test seam)
    # renders the same crumb — a deny state must still say WHICH tenant you asked for.
    account = account_for(socket, org_id)

    socket =
      assign(socket,
        account_link_id: account && account.id,
        tenant_name: account && account.name
      )

    case Keyword.fetch(opts, :replay) do
      {:ok, override} ->
        select_session(socket, override, org_id, window_hours, opts)

      :error ->
        cond do
          is_nil(mount) or is_nil(org_id) ->
            socket
            |> assign(
              org_id: org_id,
              window_hours_param: window_hours,
              replay: nil,
              impersonation: :none,
              open_error: nil,
              steps: [],
              playhead: 0,
              playing: false,
              speed: :normal,
              selected_ref: nil
            )

          true ->
            case Impersonation.gate_socket(socket, socket.assigns[:samen_operator_id], org_id) do
              :out_of_scope ->
                deny(socket, org_id, window_hours, :out_of_scope)

              :denied ->
                deny(socket, org_id, window_hours, :denied)

              {:ok, _actor, _info} ->
                replay =
                  ReplayReads.replay(mount, org_id, window_hours: window_hours, now: DateTime.utc_now())

                select_session(socket, replay, org_id, window_hours, opts)
            end
        end
    end
  end

  defp deny(socket, org_id, window_hours, posture) do
    assign(socket,
      org_id: org_id,
      window_hours_param: window_hours,
      replay: nil,
      impersonation: posture,
      open_error: nil,
      steps: [],
      playhead: 0,
      playing: false,
      speed: :normal,
      selected_ref: nil
    )
  end

  defp select_session(socket, replay, org_id, window_hours, opts) do
    sessions = Map.get(replay, :sessions) || []

    wanted = Keyword.get(opts, :selected) || socket.assigns[:selected_ref]
    selected = Enum.find(sessions, &(&1.ref == wanted)) || List.first(sessions)
    steps = (selected && selected.steps) || []

    playhead =
      case Keyword.get(opts, :playhead) do
        index when is_integer(index) -> index |> max(0) |> min(max(length(steps) - 1, 0))
        _ -> 0
      end

    assign(socket,
      org_id: org_id,
      window_hours_param: window_hours,
      replay: replay,
      impersonation: :active,
      open_error: nil,
      selected_ref: selected && selected.ref,
      steps: steps,
      playhead: playhead,
      playing: false,
      speed: socket.assigns[:speed] || :normal
    )
  end

  # The account page keys on the account Org ROW's id, while this page (like every per-tenant
  # drill-in) keys on `tenant_org_id`. That lookup is the ONLY reason this page reads beyond the
  # ledger, it is `limit(1)`, and it grants nothing — `nil` renders no back-link (and a raw
  # drill-in id in the crumb) rather than a dead link or an invented tenant name.
  defp account_for(socket, org_id) do
    mount = socket.assigns[:samen_mount]

    with %Samen.Web.Mount{} <- mount,
         operator_org_id when is_binary(operator_org_id) <- Operator.org_id(mount),
         true <- is_binary(org_id) do
      Samen.Web.Operator.Reads.account_for_tenant(mount, operator_org_id, org_id)
    else
      _ -> nil
    end
  end

  # -- render -----------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div id="operator-replay">
      <.app_shell>
        <:sidebar>
          <.operator_sidebar mount={@samen_mount} active={:replay} operator_role={assigns[:samen_operator_role]} />
        </:sidebar>

        <%!-- The plane marker every operator page leads with, and a LIVE one: `Crumbs.operator/0`
              links it at the plane's entry (Accounts), which is exactly the way this drill-in was
              reached — so "back to the accounts list" is one click from the trail, not only from
              the `← Accounts` action above. The tenant is NAMED (Org.name, non-PII) instead of a
              raw UUID, falling back to the drill-in id when no account row resolves — never to a
              guessed name. --%>
        <.topbar
          title="Replay"
          crumbs={[
            Crumbs.operator(),
            @tenant_name || @org_id || "—",
            "Replay"
          ]}
        >
          <:actions>
            <a :if={@account_link_id} href={"/operator/accounts/#{@account_link_id}"} id="back-to-account" style="font-size:12px;color:#3B4CCA;margin-right:14px">← Account</a>
            <a href="/operator/accounts" id="back-to-accounts" style="font-size:12px;color:#3B4CCA">← Accounts</a>
          </:actions>
        </.topbar>

        <%= cond do %>
          <% @impersonation == :out_of_scope -> %>
            <div class="wrap">
              <div class="card" id="out-of-scope" style="padding:22px 20px">
                <div style="color:var(--red);font-weight:600" id="not-in-scope">
                  This account is not in your scope.
                </div>
                <p style="color:var(--muted);margin:10px 0 0;font-size:13px">
                  Your operator assignment does not cover this tenant, so its recorded sessions are
                  not available to you and no impersonation session can be opened for it.
                </p>
              </div>
            </div>
          <% @impersonation == :denied -> %>
            <div class="wrap">
              <div class="card" id="impersonation-required" style="padding:22px 20px">
                <div style="color:var(--red);font-weight:600" id="no-session">
                  Access denied — no active impersonation session for this tenant.
                </div>
                <p style="color:var(--muted);margin:10px 0 14px;font-size:13px">
                  Watching one tenant's recorded session is a per-tenant drill-in: it requires a
                  short-TTL, reason-required impersonation session, recorded in the tenant's ledger.
                </p>
                <div :if={@open_error} id="open-error" style="color:#B42318;font-size:12px;margin-bottom:8px">
                  {@open_error}
                </div>
                <.role_help_note
                  :if={drill_in_role_denied?(assigns[:samen_operator_role])}
                  id="drill-in-role-denied"
                  focus={:tenant_drill_in}
                  operator_role={assigns[:samen_operator_role]}
                >
                  Opening a per-account drill-in session requires an operator role that may
                  impersonate; this session's role may not.
                </.role_help_note>
                <form phx-submit="open_session" id="open-session-form" style="display:flex;gap:8px;align-items:flex-start">
                  <input type="text" name="reason" id="session-reason-input"
                    placeholder="Reason (e.g. ticket #1234: reproduce what they saw)"
                    style="flex:1;padding:8px 10px;border:1px solid #D0D5DD;border-radius:8px;font-size:13px" />
                  <button type="submit" id="start-session-btn" style="padding:8px 14px;border-radius:8px;background:#3B4CCA;color:#fff;font-size:13px">
                    Start session
                  </button>
                </form>
              </div>
            </div>
          <% is_nil(@org_id) or is_nil(@replay) -> %>
            <div class="wrap">
              <div class="card" id="no-org" style="padding:22px 20px;color:var(--muted)">
                No tenant org resolved.
              </div>
            </div>
          <% true -> %>
            <div class="wrap">
              <.token_blind_bar chip="surface tokens + registered events only · no DOM, no keystrokes, no PII">
                <b>What happened in this session?</b>
                Each step is a surface this tenant opened or a registered product event they
                produced, in order — never a keystroke, a form value, a screenshot, or a URL.
              </.token_blind_bar>

              <%!--
                The scope note is RENDERED, not just documented: an operator must not mistake a
                step list for a screen recording. It names what IS replayed and what is not, and
                states the reader's bounds (window / caps / idle gap) so a short-looking session
                is never read as a short visit.
              --%>
              <div id="replay-scope-note" class="card" style="margin-top:10px;padding:10px 14px;font-size:12px;line-height:1.5;color:var(--muted);border-color:#E5E7EB">
                <b style="color:inherit">Scope.</b>
                Replays the surfaces and product events recorded in this tenant's analytics ledger.
                <b style="color:inherit">Does not</b> capture the screen, keystrokes, form values,
                query strings or URLs. Window: last {@replay.window_hours}h · a new session after
                {gap_minutes(@replay.gap_seconds)} min idle · newest {@replay.limits.events} events,
                {@replay.limits.sessions} sessions, {@replay.limits.steps} steps per session.
              </div>

              <div id="window-picker" style="margin-top:12px;font-size:12px;color:var(--muted)">
                Window:
                <a
                  :for={{label, hours} <- [{"24h", 24}, {"7d", 168}, {"30d", 720}]}
                  href={"/operator/replay/#{@org_id}?window_hours=#{hours}"}
                  id={"window-#{hours}"}
                  style={"margin-left:8px;#{if @replay.window_hours == hours, do: "font-weight:700;color:#3B4CCA", else: "color:#3B4CCA"}"}
                >
                  {label}
                </a>
              </div>

              <%!-- FAIL-HONEST: an empty session list is a claim about the ledger, and a read
                    that raised never observed it. The unread state is rendered INSTEAD of the
                    empty one, so "no sessions recorded" is never asserted over a failed read. --%>
              <.unread_state
                :if={@replay.sessions == [] and Map.get(@replay, :unread)}
                class="replay-unread"
                reason={Map.get(@replay, :unread)}
                title="The replay ledger could not be read."
                body="This host's product-event ledger did not answer, so this page cannot tell you whether this tenant has recorded sessions. Enabling it is a host wiring step (config :samen_core, Samen.Analytics, product_event_resource: …); until then nothing is recorded. That is not the same as an empty ledger."
              />

              <.empty_state
                :if={@replay.sessions == [] and is_nil(Map.get(@replay, :unread))}
                class="replay-empty"
                icon="🎬"
                title="No sessions recorded in this window."
                body="This tenant's ledger answered and carries no recorded page views in the selected window — try a wider window above."
              />

              <%!-- `flex-wrap` so a narrow pane (a split editor, a phone) drops the player BELOW the
                    session list instead of forcing both past the viewport edge. --%>
              <div :if={@replay.sessions != []} id="replay-body" style="margin-top:14px;display:flex;gap:16px;align-items:flex-start;flex-wrap:wrap">
                <div id="replay-sessions" class="card" style="flex:1 1 260px;max-width:320px;min-width:0;padding:10px 12px">
                  <div class="gtitle">
                    <h3>Sessions</h3>
                    <span class="n">{length(@replay.sessions)}</span>
                  </div>
                  <div id="replay-truncated" :if={@replay.truncated?} style="font-size:11px;color:var(--muted);margin:6px 0">
                    Showing the most recent sessions only — this window holds more than the render caps.
                  </div>
                  <div
                    :for={session <- @replay.sessions}
                    id={"replay-session-#{session.ref}"}
                    phx-click="select"
                    phx-value-ref={session.ref}
                    data-steps={session.step_count}
                    data-selected={to_string(session.ref == @selected_ref)}
                    style={"padding:8px 10px;border-radius:8px;cursor:pointer;margin-bottom:6px;border:1px solid #{if session.ref == @selected_ref, do: "#3B4CCA", else: "#E5E7EB"}"}
                  >
                    <div style="font-size:12px;font-weight:600">{session.label}</div>
                    <div style="font-size:11px;color:var(--muted)">
                      {session.step_count} steps · {duration_label(session.duration_seconds)}
                      <%= if session.truncated? do %>· truncated<% end %>
                    </div>
                    <a href={"/operator/replay/#{@org_id}?window_hours=#{@replay.window_hours}&session=#{session.ref}"}
                       id={"replay-session-link-#{session.ref}"}
                       style="font-size:11px;color:#3B4CCA">Open</a>
                  </div>
                </div>

                <div id="replay-player" class="card" style="flex:1 1 340px;min-width:0;padding:14px 16px"
                     data-playing={to_string(@playing)}
                     data-playhead={@playhead}
                     data-steps={length(@steps)}
                     data-speed={@speed}>
                  <div class="gtitle">
                    <h3>Replay</h3>
                    <span class="lane">step {@playhead + 1} of {max(length(@steps), 1)}</span>
                  </div>

                  <div
                    :if={@steps == []}
                    id="replay-no-steps"
                    style="color:var(--muted);font-size:13px;padding:16px 0"
                  >
                    This session has no steps in the ledger.
                  </div>

                  <div :if={@steps != []} id="replay-now" data-step-label={current_step(@steps, @playhead).label}
                       style="padding:12px 14px;border-radius:10px;background:#F4F6FF;border:1px solid #DDE2F5">
                    <div style="font-size:15px;font-weight:600">{current_step(@steps, @playhead).label}</div>
                    <div style="font-size:11px;color:var(--muted);margin-top:4px">
                      {kind_label(current_step(@steps, @playhead).kind)}
                      · +{offset_label(current_step(@steps, @playhead).offset_seconds)}
                      · {stamp(current_step(@steps, @playhead).at)}
                      <%= if current_step(@steps, @playhead).entity_ref do %>
                        · ref {current_step(@steps, @playhead).entity_ref}
                      <% end %>
                    </div>
                  </div>

                  <div id="replay-progress-track" style="height:6px;border-radius:3px;background:#E5E7EB;margin:12px 0 8px">
                    <div id="replay-progress" data-percent={progress_percent(@steps, @playhead)}
                         style={"height:6px;border-radius:3px;background:#3B4CCA;width:#{progress_percent(@steps, @playhead)}%"}></div>
                  </div>

                  <div :if={@steps != []} id="replay-controls" style="display:flex;gap:8px;align-items:center;flex-wrap:wrap">
                    <button id="replay-prev" phx-click="step" phx-value-dir="prev" style="padding:6px 10px;border-radius:8px;border:1px solid #D0D5DD;font-size:12px">⏮ Prev</button>
                    <button id="replay-play" phx-click="play" style="padding:6px 12px;border-radius:8px;background:#3B4CCA;color:#fff;font-size:12px">▶ Play</button>
                    <button id="replay-pause" phx-click="pause" style="padding:6px 12px;border-radius:8px;border:1px solid #D0D5DD;font-size:12px">⏸ Pause</button>
                    <button id="replay-next" phx-click="step" phx-value-dir="next" style="padding:6px 10px;border-radius:8px;border:1px solid #D0D5DD;font-size:12px">Next ⏭</button>
                    <span style="font-size:11px;color:var(--muted);margin-left:6px">Speed</span>
                    <button :for={{label, speed} <- [{"0.5×", "slow"}, {"1×", "normal"}, {"2×", "fast"}]}
                            id={"replay-speed-#{speed}"}
                            phx-click="speed"
                            phx-value-speed={speed}
                            data-active={to_string(to_string(@speed) == speed)}
                            style={"padding:4px 8px;border-radius:6px;font-size:11px;border:1px solid #{if to_string(@speed) == speed, do: "#3B4CCA", else: "#D0D5DD"}"}>
                      {label}
                    </button>
                  </div>

                  <div :if={@steps != []} id="replay-steps" style="margin-top:14px">
                    <div
                      :for={step <- @steps}
                      id={"replay-step-#{step.index}"}
                      phx-click="seek"
                      phx-value-index={step.index}
                      data-current={to_string(step.index == @playhead)}
                      data-kind={step.kind}
                      data-surface={step.surface}
                      style={"display:flex;gap:10px;align-items:baseline;padding:6px 8px;border-radius:6px;font-size:12px;#{if step.index == @playhead, do: "background:#EEF1FF;font-weight:600", else: ""}"}
                    >
                      <span style="color:var(--muted);font-size:11px;min-width:46px">+{offset_label(step.offset_seconds)}</span>
                      <span style="min-width:56px;color:var(--muted);font-size:11px">{kind_label(step.kind)}</span>
                      <span>{step.label}</span>
                    </div>
                  </div>
                </div>
              </div>
            </div>
        <% end %>
      </.app_shell>
    </div>
    """
  end

  # -- render helpers ---------------------------------------------------------

  # Only ever called with a non-empty step list (the template gates on it); the fallback keeps
  # a clamped-out index from rendering `nil` if a future caller relaxes that gate.
  defp current_step(steps, playhead) do
    Enum.at(steps, playhead) ||
      %{label: "—", kind: :event, offset_seconds: 0, at: nil, entity_ref: nil}
  end

  defp progress_percent([], _playhead), do: 0

  defp progress_percent(steps, playhead) do
    last = max(length(steps) - 1, 1)
    round(playhead / last * 100)
  end

  defp kind_label(:nav), do: "surface"

  defp kind_label(_), do: "event"

  defp offset_label(seconds) when is_integer(seconds) and seconds >= 0 do
    minutes = div(seconds, 60)
    rest = rem(seconds, 60)

    if minutes > 0 do
      "#{minutes}m #{String.pad_leading(to_string(rest), 2, "0")}s"
    else
      "#{rest}s"
    end
  end

  defp offset_label(_), do: "0s"

  defp gap_minutes(seconds) when is_integer(seconds) and seconds >= 60, do: div(seconds, 60)
  defp gap_minutes(_), do: 0

  defp duration_label(seconds) when is_integer(seconds) and seconds >= 60, do: "#{div(seconds, 60)}m"
  defp duration_label(seconds) when is_integer(seconds), do: "#{seconds}s"
  defp duration_label(_), do: "—"

  defp stamp(%NaiveDateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
  defp stamp(_), do: "—"
end
