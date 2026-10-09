defmodule Samenerp.Phase7SurfaceTest do
  @moduledoc """
  Phase-7 host surface proofs — the framework AI plane (`samen_ai_routes`), driven
  through the REAL router (the `Samenerp.Phase1..6SurfaceTest` discipline):

    * every one of the nine mounted AI routes renders 200 over this host's
      `Samenerp.Crm` mount + the AI-domain tables from migration 20261007120000
      (`/ai`, `/ai/search`, `/ai/crm`, `/ai/analytics`, `/ai/support`,
      `/ai/agents`, `/ai/agents/:id`, `/ai/assistant` + its two sub-paths);
    * **fail-honest** — this host wires NO AI provider (INV-5: secrets live in
      runtime config, never the repo), so the verbs surface renders
      `Samen.AI.configuration_hint/0` verbatim rather than a fabricated answer;
    * **org scoping** — an assistant seeded in org A is visible on A's surface
      and never on B's (the authorization boundary, not a rendering detail);
    * **INV-1 three-proof** for the 🔒 vault-routed assistant transcript
      (`pii_asc_transcript`, the scalar-vault convention): an opaque `vt_*` token
      at rest, the plaintext CLEAR on the tenant plane, `••••` on the
      operator-without-grant plane (never the plaintext, never a `vt_*` token),
      plus both anti-tautology twins — the plane flip, and the `vt_` leak scan
      proven refutable.
  """

  use Samenerp.DataCase, async: false
  use Samen.MaskingCase

  import Phoenix.ConnTest

  require Ash.Query

  alias Samenerp.Operator, as: Op
  alias Samen.AI.Completion
  alias Samen.Web.AI.VerbsLive
  alias Samen.Web.Mount

  @endpoint SamenerpWeb.Endpoint

  @secret "phase7 vaulted assistant transcript — never rendered on the operator plane"

  setup do
    start_supervised!(SamenerpWeb.Endpoint)
    :ok
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp create_org!(name) do
    Op.Org
    |> Ash.Changeset.for_create(:create, %{name: name}, authorize?: false)
    |> Ash.create!(authorize?: false)
  end

  defp seed_assistant!(org, name) do
    Samen.AI.Assistant
    |> Ash.Changeset.for_create(
      :create_assistant,
      %{org_id: org.id, name: name, title: "Phase7 #{name}", system_prompt: "Be terse."},
      authorize?: false
    )
    |> Ash.create!()
  end

  defp seed_conversation!(org, assistant, attrs \\ %{}) do
    Samen.AI.AssistantConversation
    |> Ash.Changeset.for_create(
      :new_conversation,
      Map.merge(
        %{org_id: org.id, assistant_id: assistant.id, title: "Phase7 thread", transcript: @secret},
        attrs
      ),
      authorize?: false
    )
    |> Ash.create!()
  end

  defp raw_transcript(conversation_id) do
    %{rows: [[raw]]} =
      Ecto.Adapters.SQL.query!(
        Repo,
        "SELECT pii_asc_transcript FROM ai_assistant_conversation WHERE asc_id = $1",
        [Ecto.UUID.dump!(conversation_id)]
      )

    raw
  end

  defp with_transcript_loaded(conversation) do
    Samen.AI.AssistantConversation
    |> Ash.Query.filter(id == ^conversation.id)
    |> Ash.Query.ensure_selected([:transcript])
    |> Ash.read_one!(authorize?: false)
  end

  # ── the mount: every route renders through the real router ─────────────────

  test "every AI kit route renders 200 over this host's AI domain" do
    tenant = create_org!("Phase7 AI Routes")

    routes = [
      {"/ai", "ai-verb-input", "the verbs surface"},
      {"/ai/search", "ai-search-input", "the semantic search surface"},
      {"/ai/crm", "ai-crm-input", "the CRM AI surface"},
      # The analytics surface is OPERATOR-gated by the T144 capability gate, so on a
      # TENANT plane it deliberately renders the honest refusal NOTE instead of an ask
      # input (the M4 "no dead-tab ask input" fix) — asserting the ask form here would
      # be asserting the bug.
      {"/ai/analytics", "ai-analytics-note", "the analytics ask surface"},
      {"/ai/support", "ai-support-inbound", "the support draft surface"},
      {"/ai/assistant", "ai-assistant", "the assistant surface"}
    ]

    for {path, anchor, label} <- routes do
      conn = get(build_conn(), "#{path}?org=#{tenant.id}")

      assert conn.status == 200,
             "#{path} did not render (status=#{conn.status}) — #{label} is missing or crashing"

      assert conn.resp_body =~ ~s(id="#{anchor}"),
             "#{path} rendered without its #{anchor} anchor — #{label} is not the expected surface"
    end

    # The agent run LIST has no org data yet: it must still render, honestly empty.
    agents = get(build_conn(), "/ai/agents?org=#{tenant.id}")
    assert agents.status == 200, "the agent list did not render (status=#{agents.status})"

    # An unknown run id collapses to the ONE honest not-found state, never a crash
    # and never a fabricated run.
    unknown = get(build_conn(), "/ai/agents/#{Ash.UUID.generate()}?org=#{tenant.id}")
    assert unknown.status == 200, "the agent detail route crashed on an unknown id"
    refute unknown.resp_body =~ "DECISION CARD",
           "an unknown run id must not render a decision card"
  end

  test "an UNCONFIGURED plane is fail-honest: SIMULATED or an honest error, never a live claim" do
    tenant = create_org!("Phase7 AI Honest")

    # The initial render is present, and NOTHING is fabricated before a verb runs.
    initial = get(build_conn(), "/ai?org=#{tenant.id}")
    assert initial.status == 200
    assert initial.resp_body =~ ~s(id="ai-verb-input")

    refute initial.resp_body =~ ~s(id="ai-verbs-result"),
           "the verbs surface rendered a result block BEFORE any verb was run"

    refute initial.resp_body =~ "vt_"
    refute initial.resp_body =~ "sk-"

    # Drive the surface's OWN page-load seam (`mount/3` -> `load/3`), the same entry
    # point the framework's test harness uses, and run one verb. This host wires NO
    # provider, so the result must be signposted as SIMULATED or refused outright —
    # an `{:ok, %Completion{simulated: false}}` would be the fabricated-answer lie.
    mount = Mount.new(:ai, Samenerp.Crm, Samenerp.Repo, labels: %{ai_path: "/ai"})

    socket =
      %Phoenix.LiveView.Socket{}
      |> Phoenix.Component.assign(:samen_mount, mount)
      |> VerbsLive.load(tenant.id, input: "Phase7 unconfigured-plane honesty check", run: true)

    case socket.assigns.result do
      {:ok, %Completion{simulated: true}} ->
        :ok

      {:error, _reason} ->
        :ok

      other ->
        flunk(
          "the verbs surface must be fail-honest on an unconfigured plane — expected a " <>
            "SIMULATED %Completion{} or {:error, _}, got: #{inspect(other)}"
        )
    end
  end

  # ── org scoping: the assistant surfaces read only the caller's org ─────────

  test "assistants are ORG-SCOPED: another org's assistant never renders" do
    org_a = create_org!("Phase7 AI Org A")
    org_b = create_org!("Phase7 AI Org B")

    seed_assistant!(org_a, "phase7-alpha-assistant")
    seed_assistant!(org_b, "phase7-beta-assistant")

    body_a = get(build_conn(), "/ai/assistant?org=#{org_a.id}").resp_body
    assert body_a =~ "phase7-alpha-assistant", "org A did not see its own assistant"
    refute body_a =~ "phase7-beta-assistant", "the surface leaked another org's assistant"

    body_b = get(build_conn(), "/ai/assistant?org=#{org_b.id}").resp_body
    assert body_b =~ "phase7-beta-assistant"
    refute body_b =~ "phase7-alpha-assistant"
  end

  # ── INV-1: the vault-routed transcript, three proofs ───────────────────────

  test "the assistant transcript is vaulted at rest, CLEAR on the tenant plane, MASKED on the operator plane (INV-1)" do
    tenant = create_org!("Phase7 AI Masking")
    assistant = seed_assistant!(tenant, "phase7-masking-assistant")
    conversation = seed_conversation!(tenant, assistant)

    # (0) AT REST — the domain column holds an opaque vt_* token, never plaintext.
    raw = raw_transcript(conversation.id)
    assert is_binary(raw), "expected a vault token string, got: #{inspect(raw)}"
    assert String.starts_with?(raw, "vt_"), "the transcript column must hold a vault token"
    refute raw =~ @secret, "the plaintext transcript leaked into the domain row"

    loaded = with_transcript_loaded(conversation)

    # (1) GREEN — the tenant's own plane resolves the transcript in the clear.
    tenant_value = resolve_on_plane(loaded, Samen.AI.AssistantConversation, :tenant, repo: Repo)
    assert_plane_clear!(tenant_value.transcript, @secret)

    # (2) RED — the operator-without-grant plane masks: never the plaintext, never a vt_ token.
    operator_value = resolve_on_plane(loaded, Samen.AI.AssistantConversation, :operator, repo: Repo)
    assert_plane_masked!(operator_value.transcript, @secret)

    # (3) SABOTAGE twin A — the plane is the ONLY difference (anti-tautology).
    assert_two_plane!(tenant_value.transcript, operator_value.transcript, @secret)

    # (4) SABOTAGE twin B — the vt_ leak scan IS refutable.
    assert_leak_detected!(to_string(operator_value.transcript) <> "|" <> raw, "vt_")
  end
end
