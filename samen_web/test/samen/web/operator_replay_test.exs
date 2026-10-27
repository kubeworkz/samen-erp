defmodule Samen.Web.OperatorReplayTest do
  @moduledoc """
  Session replay — the tenant-plane RECORDER (`Samen.Web.Replay` riding
  `Samen.Web.TenantAuthz`'s tenant on_mount), the operator READ/sessionizer
  (`Samen.Web.Operator.ReplayReads`) and the operator SCREEN with its playhead
  (`Samen.Web.Operator.ReplayLive` at `/operator/replay/:org_id`).

  Proofs, in the order the feature actually runs:

    1. **Capture is bounded and ONE-per-visit.** The tenant hook records exactly one
       `nav.visited` step per CONNECTED mount carrying a bounded surface token derived from the
       LiveView module — and NOTHING on the dead render (which mounts too), so a visit cannot
       double-count. A path/URL/label can never become a step (the refusal matrix lives in
       `samen_core/test/analytics_replay_test.exs`).
    2. **The actor is a pseudonym.** With a session principal, the recorded `actor_ref` is an
       HMAC handle — never the raw principal id — so a shredded subject's replay is
       unlinkable.
    3. **Sessionization is real.** Steps group by actor and a 30-minute idle gap; offsets are
       ascending from each session's own base; a wider window includes older sessions; org B's
       rows never appear in org A's replay.
    4. **Fail-honest silences.** An UNWIRED ledger renders "the ledger could not be read",
       never the empty-state claim "no sessions recorded" — those are different facts.
    5. **The player advances.** `play` → `:tick` moves the playhead by one step, `pause`
       stops it, `step`/`seek` move it, and the render reflects the playhead
       (`data-playhead`, `data-current`, the progress bar).
    6. **Token-blind by construction + a refutable twin.** No `vt_` token, no email-shaped
       sentinel ever renders — and the SAME scan detects a leaked step injected through the
       sanctioned `:replay` seam, so the assertion is not vacuous.
    7. **0-LOC inheritance.** The shipped `samen_operator_routes/2` macro declares the route,
       so every operator host inherits the screen without authored LOC.
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.Web.Operator.{ReplayLive, ReplayReads}
  alias Samen.Web.TenantAuthz
  alias Samen.WebTest.Analytics.ProductEvent
  alias Samen.WebTest.Repo

  @ledger "wan_product_event"
  @gap ReplayReads.gap_seconds()

  setup do
    # The KMS adapter is what makes the actor_ref pseudonymization observable at all.
    prev_kms = Application.get_env(:samen_core, :kms_adapter)
    Application.put_env(:samen_core, :kms_adapter, Samen.Kms.FileBacked)

    prev_analytics = Application.get_env(:samen_core, Samen.Analytics)
    Application.put_env(:samen_core, Samen.Analytics, product_event_resource: ProductEvent)

    on_exit(fn ->
      case prev_kms do
        nil -> Application.delete_env(:samen_core, :kms_adapter)
        value -> Application.put_env(:samen_core, :kms_adapter, value)
      end

      case prev_analytics do
        nil -> Application.delete_env(:samen_core, Samen.Analytics)
        value -> Application.put_env(:samen_core, Samen.Analytics, value)
      end
    end)

    :ok
  end

  # -- ledger helpers (write the REAL row shape `track/1` writes) ---------------

  defp insert_step!(org_id, opts) do
    Ecto.Adapters.SQL.query!(
      Repo,
      """
      INSERT INTO #{@ledger}
        (wan_org_id, wan_actor_ref, wan_event_name, wan_event_kind, wan_entity_ref, wan_props,
         wan_occurred_at, wan_inserted_at, wan_updated_at)
      VALUES ($1::uuid, $2, $3, $4, $5, $6::json, $7, $7, $7)
      """,
      [
        Ecto.UUID.dump!(org_id),
        Keyword.get(opts, :actor, "actor-a"),
        Keyword.get(opts, :event, "nav.visited"),
        Keyword.get(opts, :kind, "session"),
        Keyword.get(opts, :entity_ref),
        # A MAP, not a pre-encoded string: Postgrex encodes a binary JSON param as a JSON
        # STRING (which would make `props ->> 'surface'` nil for every row).
        Keyword.get(opts, :props, %{"surface" => "broker"}),
        Keyword.get(opts, :at, NaiveDateTime.utc_now())
      ]
    )
  end

  defp ledger_count do
    %{rows: [[count]]} = Ecto.Adapters.SQL.query!(Repo, "SELECT count(*) FROM #{@ledger}", [])
    count
  end

  defp ledger_rows(org_id) do
    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        Repo,
        """
        SELECT wan_actor_ref, wan_event_name, wan_event_kind, wan_props
        FROM #{@ledger} WHERE wan_org_id = $1::uuid ORDER BY wan_occurred_at ASC
        """,
        [Ecto.UUID.dump!(org_id)]
      )

    rows
  end

  defp operator_socket(org_id, opts \\ []) do
    operator_id = Keyword.get(opts, :operator_id, Ash.UUID.generate())
    mount = build_operator_mount(Ash.UUID.generate())

    socket =
      %Phoenix.LiveView.Socket{}
      |> Phoenix.Component.assign(:samen_mount, mount)
      |> with_operator_identity(operator_id)

    if Keyword.get(opts, :gated, true) do
      open_impersonation!(operator_id, org_id)
      socket
    else
      socket
    end
  end

  # ===========================================================================
  # 1 + 2. The recorder — one step per connected visit, pseudonymized actor
  # ===========================================================================

  test "the tenant on_mount hook records ONE bounded step per CONNECTED visit and nothing on the dead render" do
    org_id = Ash.UUID.generate()
    mount = build_mount(:crm)
    session = mount_session(mount)
    params = %{"org" => org_id}

    connected = %Phoenix.LiveView.Socket{transport_pid: self(), view: Samen.Web.CRM.ContactsLive}
    assert {:cont, _socket} = TenantAuthz.on_mount(:require_tenant, params, session, connected)

    assert [[nil, "nav.visited", "session", props]] = ledger_rows(org_id)
    # The surface is the bounded MODULE token — not the URL, not the path params.
    assert props == %{"surface" => "contacts"}

    # The dead render mounts too. Recording there would double EVERY visit; it must not.
    dead = %Phoenix.LiveView.Socket{transport_pid: nil, view: Samen.Web.CRM.ContactsLive}
    assert {:cont, _socket} = TenantAuthz.on_mount(:require_tenant, params, session, dead)
    assert length(ledger_rows(org_id)) == 1
  end

  test "a session principal is recorded as an HMAC pseudonym, never as the raw id" do
    org_id = Ash.UUID.generate()
    subject = "credential-#{System.unique_integer([:positive])}"
    {:ok, _wrapped} = Samen.Kms.FileBacked.generate_subject_key(subject)

    socket =
      %Phoenix.LiveView.Socket{transport_pid: self(), view: Samen.Web.CRM.ContactsLive}
      |> Phoenix.Component.assign(:samen_tenant_org_id, org_id)
      |> Phoenix.Component.assign(:samen_tenant_principal, subject)

    assert ^socket = Samen.Web.Replay.record_visit(socket)

    assert [[actor_ref, "nav.visited", _, _]] = ledger_rows(org_id)
    assert is_binary(actor_ref)
    refute actor_ref == subject
    # A ONE-WAY handle, and stable for the same subject (the point of the pseudonym).
    assert {:ok, ^actor_ref} = Samen.WideEvent.for_subject(subject)
  end

  test "a subject whose key is gone records NO actor at all — never a raw id as a fallback" do
    org_id = Ash.UUID.generate()
    # No `generate_subject_key/1` for this subject: the pseudonym cannot be derived (the
    # erasure-shaped case), so the step keeps the org-scoped fact and drops the linkage.
    shredded = "credential-no-key-#{System.unique_integer([:positive])}"

    socket =
      %Phoenix.LiveView.Socket{transport_pid: self(), view: Samen.Web.CRM.ContactsLive}
      |> Phoenix.Component.assign(:samen_tenant_org_id, org_id)
      |> Phoenix.Component.assign(:samen_tenant_principal, shredded)

    Samen.Web.Replay.record_visit(socket)

    assert [[actor_ref, "nav.visited", _, _]] = ledger_rows(org_id)
    assert is_nil(actor_ref)
    refute Jason.encode!(ledger_rows(org_id)) =~ shredded
  end

  test "a mount that resolved no org records nothing at all (fail-closed, no orphan step)" do
    before = ledger_count()

    socket =
      %Phoenix.LiveView.Socket{transport_pid: self(), view: Samen.Web.CRM.ContactsLive}
      |> Phoenix.Component.assign(:samen_tenant_org_id, nil)

    assert ^socket = Samen.Web.Replay.record_visit(socket)
    assert ledger_count() == before
  end

  # ===========================================================================
  # 3. The read layer — sessionization, offsets, windows, org isolation
  # ===========================================================================

  test "steps group into sessions by actor and a 30-minute idle gap, with ascending offsets" do
    org_id = Ash.UUID.generate()
    base = NaiveDateTime.utc_now()

    # One session (same actor, 5 min apart) …
    insert_step!(org_id, actor: "actor-a", at: base, props: %{"surface" => "broker"})
    insert_step!(org_id, actor: "actor-a", at: NaiveDateTime.add(base, 300), props: %{"surface" => "contacts"})

    # … a SECOND session for the same actor after a > 30 min idle gap …
    insert_step!(org_id,
      actor: "actor-a",
      at: NaiveDateTime.add(base, @gap + 600),
      props: %{"surface" => "dashboard"}
    )

    # … and a third actor entirely, after every actor-a step (an interleaved actor SPLITS the
    # other actor's timeline — which is correct, and deliberately not what this test asserts).
    insert_step!(org_id,
      actor: "actor-b",
      at: NaiveDateTime.add(base, @gap + 1_200),
      props: %{"surface" => "flags"}
    )

    replay = ReplayReads.replay(build_operator_mount(Ash.UUID.generate()), org_id)

    assert replay.unread == nil
    assert length(replay.sessions) == 3

    # Newest first.
    assert [newest, mid, oldest] = replay.sessions
    assert newest.actor_ref == "actor-b"
    assert newest.step_count == 1
    assert mid.actor_ref == "actor-a"
    assert mid.step_count == 1
    assert oldest.step_count == 2

    # Offsets are relative to EACH session's own first step.
    assert [%{offset_seconds: 0}, %{offset_seconds: 300}] = oldest.steps
    assert oldest.duration_seconds == 300
    assert Enum.map(oldest.steps, & &1.index) == [0, 1]
    assert Enum.map(oldest.steps, & &1.label) == ["Opened Broker", "Opened Contacts"]
    assert Enum.all?(oldest.steps, &(&1.kind == :nav))
    assert Enum.all?(oldest.steps, &(&1.surface != nil))
  end

  test "the ledger's per-subject pseudonym is what identifies an actor (never a raw id)" do
    org_id = Ash.UUID.generate()
    insert_step!(org_id, actor: "hmac-actor-ref", at: NaiveDateTime.utc_now())

    replay = ReplayReads.replay(build_operator_mount(Ash.UUID.generate()), org_id)

    assert [session] = replay.sessions
    assert session.actor_ref == "hmac-actor-ref"
    # The rendered label is a SHORTENED handle, never a full actor_ref and never an id.
    assert session.label =~ "hmac-actor…"
  end

  test "a registered product event is a step too, rendered with its own label" do
    org_id = Ash.UUID.generate()
    insert_step!(org_id, actor: "actor-a", event: "record.created", kind: "record", props: %{"resource" => "crm.contact"}, at: NaiveDateTime.utc_now())

    replay = ReplayReads.replay(build_operator_mount(Ash.UUID.generate()), org_id)

    assert [session] = replay.sessions
    assert [%{kind: :event, event: "record.created", label: "Created a record"} = step] = session.steps
    # A product event carries NO surface — the reader does not invent one for it.
    assert step.surface == nil
  end

  test "INV-2: org A's replay never contains org B's sessions" do
    org_a = Ash.UUID.generate()
    org_b = Ash.UUID.generate()

    insert_step!(org_a, actor: "actor-org-a-only", at: NaiveDateTime.utc_now())
    insert_step!(org_b, actor: "actor-org-b-only", at: NaiveDateTime.utc_now())

    replay_a = ReplayReads.replay(build_operator_mount(Ash.UUID.generate()), org_a)

    assert [session] = replay_a.sessions
    assert session.actor_ref == "actor-org-a-only"
    refute Enum.any?(replay_a.sessions, &(&1.actor_ref == "actor-org-b-only"))
  end

  test "the window bounds the read: a 10-day-old session is out at the default 7d and in at 30d" do
    org_id = Ash.UUID.generate()
    now = DateTime.utc_now()
    stale = DateTime.add(now, -10 * 24 * 3600, :second) |> DateTime.to_naive()

    insert_step!(org_id, actor: "actor-stale", at: stale)
    insert_step!(org_id, actor: "actor-fresh", at: NaiveDateTime.utc_now())

    mount = build_operator_mount(Ash.UUID.generate())
    default = ReplayReads.replay(mount, org_id, now: now)
    assert Enum.map(default.sessions, & &1.actor_ref) == ["actor-fresh"]

    wider = ReplayReads.replay(mount, org_id, window_hours: 720, now: now)
    assert Enum.sort(Enum.map(wider.sessions, & &1.actor_ref)) == ["actor-fresh", "actor-stale"]
  end

  test "fail-honest: `no_org`, and an unwired ledger is `:not_configured` — never a fabricated empty timeline" do
    mount = build_operator_mount(Ash.UUID.generate())

    assert ReplayReads.replay(mount, nil).unread == :no_org
    assert ReplayReads.replay(mount, "").unread == :no_org

    Application.delete_env(:samen_core, Samen.Analytics)
    unwired = ReplayReads.replay(mount, Ash.UUID.generate())
    assert unwired.unread == :not_configured
    assert unwired.sessions == []
  end

  test "the reader derives its table + columns from the host's own resource (no hardcoded abbrev)" do
    org_id = Ash.UUID.generate()
    insert_step!(org_id, actor: "actor-derived", at: NaiveDateTime.utc_now())

    # The samen_web test host's ledger is `wan_product_event` with `wan_`-prefixed columns; a
    # reader that hardcoded `actor_ref`/`org_id` would return `:read_failed` here instead.
    replay = ReplayReads.replay(build_operator_mount(Ash.UUID.generate()), org_id)
    assert replay.unread == nil
    assert [%{actor_ref: "actor-derived"}] = replay.sessions
  end

  test "the catalog and the ledger resource's one_of gate move together (drift guard)" do
    names =
      ProductEvent
      |> Ash.Resource.Info.attribute(:event_name)
      |> Map.get(:constraints, [])
      |> Keyword.get(:one_of, [])
      |> MapSet.new()

    registered = Samen.Analytics.Catalog.name_list() |> Enum.map(&String.to_atom/1) |> MapSet.new()

    assert MapSet.subset?(registered, names),
           "the ledger's one_of is missing #{inspect(MapSet.difference(registered, names))} — " <>
             "a catalog event the ledger rejects is a capture path that lies about accepting it."

    assert :"nav.visited" in names
  end

  # ===========================================================================
  # 4. The page — drill-in gate, honest silences
  # ===========================================================================

  test "the page requires a T150 impersonation session (deny-on-read), then renders the replay" do
    org_id = Ash.UUID.generate()
    insert_step!(org_id, actor: "actor-a", at: NaiveDateTime.utc_now())

    denied = ReplayLive.load(operator_socket(org_id, gated: false), org_id, nil)
    html = render_html(ReplayLive, denied.assigns)
    assert html =~ "impersonation-required"
    assert html =~ "no active impersonation session"
    refute html =~ "Opened Broker"

    allowed = ReplayLive.load(operator_socket(org_id), org_id, nil)
    html = render_html(ReplayLive, allowed.assigns)
    refute html =~ "impersonation-required"
    assert html =~ "Opened Broker"
    assert html =~ "replay-scope-note"
    assert html =~ "Does not"

    # Place keeping through the REAL page: Replay passes `active: :replay`, and because it is a
    # per-tenant drill-in (no top-level index) the sidebar must show the operator they are still
    # inside Accounts, not a bar with nothing lit.
    assert html =~ ~r/href="\/operator\/accounts"\s+class="on"/
    refute html =~ ~r/href="\/operator\/desk"\s+class="on"/
  end

  test "no org resolved renders the honest empty state" do
    socket =
      %Phoenix.LiveView.Socket{}
      |> Phoenix.Component.assign(:samen_mount, build_operator_mount(Ash.UUID.generate()))

    html = socket |> ReplayLive.load(nil, nil) |> then(&render_html(ReplayLive, &1.assigns))
    assert html =~ "No tenant org resolved."
  end

  test "an EMPTY ledger renders the empty state; an UNREADABLE one renders the unread state instead" do
    empty_org = Ash.UUID.generate()
    empty = empty_org |> operator_socket() |> ReplayLive.load(empty_org, nil)
    empty_html = render_html(ReplayLive, empty.assigns)
    assert empty_html =~ "No sessions recorded in this window."
    refute empty_html =~ "replay-unread"

    # Unwired: the read could not answer at all — that is NOT "this tenant recorded nothing".
    Application.delete_env(:samen_core, Samen.Analytics)
    unread_org = Ash.UUID.generate()
    unread = unread_org |> operator_socket() |> ReplayLive.load(unread_org, nil)
    unread_html = render_html(ReplayLive, unread.assigns)
    assert unread_html =~ "replay-unread"
    assert unread_html =~ "could not be read"
    refute unread_html =~ "No sessions recorded in this window."
  end

  # ===========================================================================
  # 5. The player — the playhead is real server state
  # ===========================================================================

  test "play → tick advances the playhead one step; pause stops it; the render follows the playhead" do
    org_id = Ash.UUID.generate()
    base = NaiveDateTime.utc_now()

    insert_step!(org_id, actor: "actor-a", at: base, props: %{"surface" => "broker"})
    insert_step!(org_id, actor: "actor-a", at: NaiveDateTime.add(base, 60), props: %{"surface" => "contacts"})
    insert_step!(org_id, actor: "actor-a", at: NaiveDateTime.add(base, 120), props: %{"surface" => "flags"})

    socket = org_id |> operator_socket() |> ReplayLive.load(org_id, nil)
    assert socket.assigns.playhead == 0
    assert length(socket.assigns.steps) == 3

    first_html = render_html(ReplayLive, socket.assigns)
    assert first_html =~ ~s(data-playhead="0")
    assert first_html =~ ~r/id="replay-step-0"[^>]*data-current="true"/

    {:noreply, socket} = ReplayLive.handle_event("play", %{}, socket)
    assert socket.assigns.playing == true

    {:noreply, socket} = ReplayLive.handle_info(:tick, socket)
    assert socket.assigns.playhead == 1
    assert socket.assigns.playing == true

    ticked_html = render_html(ReplayLive, socket.assigns)
    assert ticked_html =~ ~s(data-playhead="1")
    assert ticked_html =~ ~r/id="replay-step-1"[^>]*data-current="true"/
    assert ticked_html =~ ~r/id="replay-step-0"[^>]*data-current="false"/

    {:noreply, socket} = ReplayLive.handle_event("pause", %{}, socket)
    assert socket.assigns.playing == false

    # A tick that arrives after a pause is inert (the player does not run on).
    {:noreply, socket} = ReplayLive.handle_info(:tick, socket)
    assert socket.assigns.playhead == 1
  end

  test "the player stops at the last step instead of ticking on forever" do
    org_id = Ash.UUID.generate()
    insert_step!(org_id, actor: "actor-a", at: NaiveDateTime.utc_now())

    socket = org_id |> operator_socket() |> ReplayLive.load(org_id, nil)
    {:noreply, socket} = ReplayLive.handle_event("play", %{}, socket)
    {:noreply, socket} = ReplayLive.handle_info(:tick, socket)

    assert socket.assigns.playhead == 0
    assert socket.assigns.playing == false
  end

  test "step / seek / speed are clamped and reflected in the render" do
    org_id = Ash.UUID.generate()
    base = NaiveDateTime.utc_now()

    insert_step!(org_id, actor: "actor-a", at: base)
    insert_step!(org_id, actor: "actor-a", at: NaiveDateTime.add(base, 30))

    socket = org_id |> operator_socket() |> ReplayLive.load(org_id, nil)

    {:noreply, socket} = ReplayLive.handle_event("step", %{"dir" => "next"}, socket)
    assert socket.assigns.playhead == 1

    # Clamped at the END …
    {:noreply, socket} = ReplayLive.handle_event("step", %{"dir" => "next"}, socket)
    assert socket.assigns.playhead == 1

    {:noreply, socket} = ReplayLive.handle_event("seek", %{"index" => "99"}, socket)
    assert socket.assigns.playhead == 1

    {:noreply, socket} = ReplayLive.handle_event("seek", %{"index" => "0"}, socket)
    assert socket.assigns.playhead == 0

    # … and at the START.
    {:noreply, socket} = ReplayLive.handle_event("step", %{"dir" => "prev"}, socket)
    assert socket.assigns.playhead == 0

    {:noreply, socket} = ReplayLive.handle_event("speed", %{"speed" => "fast"}, socket)
    assert socket.assigns.speed == :fast

    html = render_html(ReplayLive, socket.assigns)
    assert html =~ ~s(data-speed="fast")
    assert html =~ ~s(data-percent="0")
  end

  test "selecting another session re-points the player at that session's steps" do
    org_id = Ash.UUID.generate()
    base = NaiveDateTime.utc_now()

    insert_step!(org_id, actor: "actor-a", at: base, props: %{"surface" => "broker"})
    insert_step!(org_id, actor: "actor-b", at: NaiveDateTime.add(base, 60), props: %{"surface" => "flags"})

    socket = org_id |> operator_socket() |> ReplayLive.load(org_id, nil)
    assert length(socket.assigns.steps) == 1

    other = socket.assigns.replay.sessions |> Enum.find(&(&1.ref != socket.assigns.selected_ref))
    {:noreply, socket} = ReplayLive.handle_event("select", %{"ref" => other.ref}, socket)

    assert socket.assigns.selected_ref == other.ref
    assert socket.assigns.playhead == 0
    assert socket.assigns.playing == false
    assert [%{surface: "flags"}] = socket.assigns.steps

    html = render_html(ReplayLive, socket.assigns)
    assert html =~ ~s(data-selected="true")
    # The FORMERLY selected session is now marked unselected in the same render.
    assert html =~ ~s(data-selected="false")
  end

  # ===========================================================================
  # 6. Token-blind by construction + the refutable sabotage twin
  # ===========================================================================

  test "INV-1: no vault token, no email-shaped sentinel, ever renders from a realistic session" do
    org_id = Ash.UUID.generate()
    insert_step!(org_id, actor: "actor-clean", at: NaiveDateTime.utc_now())
    insert_step!(org_id, actor: "actor-clean", event: "search.used", kind: "search", props: %{"surface" => "list"}, at: NaiveDateTime.utc_now(), entity_ref: "rec-9f2c")

    html = org_id |> operator_socket() |> ReplayLive.load(org_id, nil) |> then(&render_html(ReplayLive, &1.assigns))

    refute html =~ ~r/\bvt_/
    refute html =~ ~r/[\w.+-]+@[\w-]+\.[a-z]{2,}/i
    # The rendered actor handle is the SHORTENED pseudonym (11 chars → "actor-clea…"), never
    # the full actor_ref — another reason nothing long enough to be an id can render here.
    assert html =~ "actor-clea…"
    refute html =~ "actor-clean"
  end

  test "SABOTAGE TWIN: a leaked step injected through the :replay seam IS visible to the scan (so INV-1 is refutable)" do
    org_id = Ash.UUID.generate()

    leaked = %{
      org_id: org_id,
      window_hours: 168,
      cutoff: DateTime.utc_now(),
      unread: nil,
      truncated?: false,
      limits: ReplayReads.limits(),
      gap_seconds: @gap,
      sessions: [
        %{
          ref: "leak-canary",
          actor_ref: "actor-leak-canary",
          label: "leak canary",
          started_at: NaiveDateTime.utc_now(),
          ended_at: NaiveDateTime.utc_now(),
          duration_seconds: 0,
          step_count: 1,
          truncated?: false,
          steps: [
            %{
              index: 0,
              at: NaiveDateTime.utc_now(),
              offset_seconds: 0,
              kind: :event,
              event: "search.used",
              surface: nil,
              # What a reader that forgot the capture refusal WOULD have rendered.
              label: "opened alice@example.com vt_9f2c8d1e",
              entity_ref: nil
            }
          ]
        }
      ]
    }

    socket = operator_socket(org_id)
    html = socket |> ReplayLive.load(org_id, nil, replay: leaked) |> then(&render_html(ReplayLive, &1.assigns))

    assert html =~ "alice@example.com",
           "the page must be ABLE to render a leaked value if the capture/read layer ever produced one, else the INV-1 scan above is vacuous"
  end

  test "the REAL capture path never produces what the sabotage twin modeled" do
    org_id = Ash.UUID.generate()

    # Every surface a real mount can record is a module-derived token; the ledger row this
    # produces carries no freeform text at all, so this page has nothing to mask.
    socket =
      %Phoenix.LiveView.Socket{transport_pid: self(), view: Samen.Web.CRM.ContactsLive}
      |> Phoenix.Component.assign(:samen_tenant_org_id, org_id)

    Samen.Web.Replay.record_visit(socket)

    assert [[_actor, "nav.visited", _kind, props]] = ledger_rows(org_id)
    assert props == %{"surface" => "contacts"}
    refute Jason.encode!(props) =~ "@"
    refute Jason.encode!(props) =~ "vt_"
  end

  # ===========================================================================
  # 7. 0-LOC inheritance — the shipped route macro declares the screen
  # ===========================================================================

  test "samen_operator_routes/2 declares /operator/replay/:org_id, so every operator host inherits it" do
    routes = Samen.WebTest.FleetCockpitRouter.__routes__()

    assert Enum.any?(routes, &(&1.path == "/operator/replay/:org_id")),
           "the Replay screen must be declared by the mount macro, not authored in a host router"

    # The route is a LiveView route: its `plug` is `Phoenix.LiveView.Plug`, and the SCREEN it
    # mounts is the route's own `:phoenix_live_view` metadata module.
    replay = Enum.find(routes, &(&1.path == "/operator/replay/:org_id"))
    assert replay.plug == Phoenix.LiveView.Plug
    # Phoenix stores the LiveView metadata as `{module, action, opts, extra}`.
    assert replay.metadata.phoenix_live_view |> elem(0) == ReplayLive
  end

  test "the '← Account' link resolves the account Org id from the tenant_org_id the drill-in carries" do
    seed = Samen.WebTest.Operator.Seeds.seed_all(tenants: 1)
    account = hd(seed.accounts)
    tenant = account.tenant_org_id
    account_org_id = account.account_org.id

    # Two DIFFERENT columns of the same row: the drill-in id is the ledger/impersonation key,
    # the account page id is the Org ROW id. A back-link built from the drill-in id would land
    # on "Account not found" — the bug this pins.
    assert tenant != account_org_id
    insert_step!(tenant, actor: "actor-a", at: NaiveDateTime.utc_now())

    operator_id = Ash.UUID.generate()
    open_impersonation!(operator_id, tenant)

    socket =
      %Phoenix.LiveView.Socket{}
      |> Phoenix.Component.assign(:samen_mount, build_operator_mount(seed.operator_org_id))
      |> with_operator_identity(operator_id)

    html = socket |> ReplayLive.load(tenant, nil) |> then(&render_html(ReplayLive, &1.assigns))

    assert html =~ ~s(href="/operator/accounts/#{account_org_id}")
    refute html =~ ~s(href="/operator/accounts/#{tenant}")
  end

  # The crumb is the ONLY place the operator reads "which tenant am I looking at?" — a raw
  # `tenant_org_id` UUID answers a question nobody asked. The account row is already resolved
  # for the back-link, so its non-PII `Org.name` is free to render.
  #
  # The trail's leading crumb is the plane marker EVERY operator page leads with, and it is LIVE:
  # `Crumbs.operator/0` links Accounts — the way this drill-in was reached — so the trail reads
  # "Operator plane / <tenant> / Replay" with the click still on the first step.
  test "the breadcrumb NAMES the tenant and links Accounts, instead of showing a raw drill-in id" do
    seed = Samen.WebTest.Operator.Seeds.seed_all(tenants: 1)
    account = hd(seed.accounts)
    tenant = account.tenant_org_id
    name = account.account_org.name

    assert name == "Blue Ridge Logistics 1"

    insert_step!(tenant, actor: "actor-a", at: NaiveDateTime.utc_now())

    operator_id = Ash.UUID.generate()
    open_impersonation!(operator_id, tenant)

    socket =
      %Phoenix.LiveView.Socket{}
      |> Phoenix.Component.assign(:samen_mount, build_operator_mount(seed.operator_org_id))
      |> with_operator_identity(operator_id)

    html = socket |> ReplayLive.load(tenant, nil) |> then(&render_html(ReplayLive, &1.assigns))
    crumb = crumbs(html)

    assert crumb =~ ~r/<a href="\/operator\/accounts">Operator plane<\/a>/
    assert crumb =~ name
    assert crumb =~ "Replay"
    refute crumb =~ tenant
  end

  test "with NO account row behind the drill-in, the crumb falls back to the raw id (never a guessed name)" do
    org_id = Ash.UUID.generate()
    html = org_id |> operator_socket() |> ReplayLive.load(org_id, nil) |> then(&render_html(ReplayLive, &1.assigns))

    crumb = crumbs(html)
    assert crumb =~ org_id
    assert crumb =~ "Replay"
  end

  # The topbar's `.crumb` block: the bar is rendered before every other page content, and its
  # inner markup is only spans/links, so the first `</div>` closes it.
  defp crumbs(html) do
    case Regex.run(~r/class="crumb">(.*?)<\/div>/s, html) do
      [_, crumb] -> crumb
      nil -> ""
    end
  end

  test "the replay drill-in rides the SHIPPED impersonation gate (no replay-local reimplementation)" do
    # The screen's deny state must be the SAME two-valued gate every other drill-in uses, so a
    # session review can never be easier to reach than the activity feed next to it.
    org_id = Ash.UUID.generate()
    unopened = ReplayLive.load(operator_socket(org_id, gated: false), org_id, nil)
    assert unopened.assigns.impersonation == :denied

    opened = ReplayLive.load(operator_socket(org_id), org_id, nil)
    assert opened.assigns.impersonation == :active
  end
end
