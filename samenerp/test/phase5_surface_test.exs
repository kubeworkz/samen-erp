defmodule Samenerp.Phase5SurfaceTest do
  @moduledoc """
  Phase-5 host surface proofs — the Knowledge Base + CSAT module groups, driven
  through the REAL router (the `Samenerp.Phase1/2/3/4SurfaceTest` discipline):

    * `GET /portal/:org` — the `samen_module_routes(:kb, Samenerp.Cms, …)`
      one-liner surfaces the framework help center over this host's CMS mount
      (200 + the honest empty state), and a SEEDED `sct_post` renders — but ONLY
      the `status: :published, visibility: :public` one. An INTERNAL post is
      invisible to the portal: `Post.read_public`'s own baked-in filter is the
      entire authorization surface for an anonymous visitor, so that assertion
      is the authorization boundary, not a rendering detail.
    * `GET /support/kb` — the agent-facing KB, which lives on the SUPPORT mount
      and reaches the CMS namespace through the `:kb_namespace` sibling-mount
      label this phase wires. Without that label the page renders the honest
      \"KB not set up\" empty state; with it, an internal article is readable by
      an org-scoped agent.
    * `GET /support/csat/:token` — the tokenized, UNAUTHENTICATED survey response
      route over the `Samenerp.Support` mount (the zct/zca tables already existed
      from the 20260922020000 support-scope mount, so this mount needed no
      migration). A garbage token renders the ONE generic \"no longer valid\"
      state (never an oracle distinguishing expired vs consumed vs unknown), and
      a genuinely minted single-use token renders the score form, RECORDS the
      response through the real socket, and is honestly invalid on replay.

  Non-PII throughout: every CMS field here is authored product copy, and the CSAT
  score/comments are the blueprint's non-vaulted free-text residue.
  """

  use Samenerp.DataCase, async: false

  import Phoenix.ConnTest

  alias Samenerp.Operator, as: Op
  alias Samen.Web.Mount
  alias Samen.Web.Support.CsatRespondLive

  @endpoint SamenerpWeb.Endpoint

  setup do
    start_supervised!(SamenerpWeb.Endpoint)
    :ok
  end

  defp create_org!(name) do
    Op.Org
    |> Ash.Changeset.for_create(:create, %{name: name}, authorize?: false)
    |> Ash.create!(authorize?: false)
  end

  defp seed_post!(org, attrs) do
    attrs =
      Map.merge(
        %{org_id: org.id, body: "Body copy for the Phase-5 proof.", slug: "phase5-#{:rand.uniform(999_999)}"},
        attrs
      )

    Samenerp.Cms.Post
    |> Ash.Changeset.for_create(:create, attrs, authorize?: false)
    |> Ash.create!(authorize?: false)
  end

  defp create_ticket!(org) do
    Samenerp.Support.Ticket
    |> Ash.Changeset.for_create(:create, %{org_id: org.id, subject: "Phase5 CSAT proof"},
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end

  # Mint a single-use survey token the SAME way `Samen.Scopes.Support.CsatSurvey.
  # send_survey/3` does (every `CsatSurveyToken` attribute is `public?: false`, so
  # the private columns are force-set — the framework's own precedent for this
  # resource). Minting this way keeps the proof hermetic: no delivery adapter and
  # no resolved-ticket lifecycle is needed to exercise the response route itself.
  defp mint_token!(org, ticket) do
    raw = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    expires_at =
      DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)

    Samenerp.Support.CsatSurveyToken
    |> Ash.Changeset.for_create(:create, %{org_id: org.id}, authorize?: false)
    |> Ash.Changeset.force_change_attribute(:ticket_id, ticket.id)
    |> Ash.Changeset.force_change_attribute(:agent_id, nil)
    |> Ash.Changeset.force_change_attribute(:token_digest, Samen.Auth.TokenMint.digest(raw))
    |> Ash.Changeset.force_change_attribute(:expires_at, expires_at)
    |> Ash.create!(authorize?: false)

    raw
  end

  defp csat_count(org_id) do
    %{rows: [[n]]} =
      Ecto.Adapters.SQL.query!(
        Samenerp.Repo,
        "SELECT count(*) FROM zca_csat WHERE zca_org_id = $1",
        [Ecto.UUID.dump!(org_id)]
      )

    n
  end

  # ==========================================================================
  # Knowledge base — the public portal (`:kb`)
  # ==========================================================================

  test "the public help center renders with its honest empty state" do
    tenant = create_org!("Phase5 KB QA")

    conn = get(build_conn(), "/portal/#{tenant.id}")

    assert conn.status == 200,
           "the /portal/:org page did not render (status=#{conn.status}) — the :kb mount is missing or crashing"

    body = conn.resp_body
    assert body =~ ~s(id="portal-kb"), "the help center surface did not render"
    assert body =~ "Help center", "the help center heading did not render"
    assert body =~ "No help articles published yet.", "the honest empty state did not render"
  end

  test "the portal shows a published PUBLIC post and hides an INTERNAL one" do
    tenant = create_org!("Phase5 KB Visibility")

    seed_post!(tenant, %{title: "Phase5 public article", status: :published, visibility: :public})

    seed_post!(tenant, %{
      title: "Phase5 internal memo",
      status: :published,
      visibility: :internal
    })

    # Not yet published → also invisible, public or not.
    seed_post!(tenant, %{title: "Phase5 draft article", status: :draft, visibility: :public})

    conn = get(build_conn(), "/portal/#{tenant.id}")
    body = conn.resp_body

    assert conn.status == 200
    assert body =~ "Phase5 public article", "the published public article did not render"
    refute body =~ "Phase5 internal memo",
           "an INTERNAL article leaked to the unauthenticated portal — read_public is the authorization boundary"

    refute body =~ "Phase5 draft article",
           "an unpublished article leaked to the unauthenticated portal"
  end

  # ==========================================================================
  # Knowledge base — the agent surface (`kb_namespace` sibling-mount seam)
  # ==========================================================================

  test "the agent KB reads this host's CMS namespace through the kb_namespace label" do
    tenant = create_org!("Phase5 KB Agent")

    seed_post!(tenant, %{title: "Phase5 agent-visible article", status: :published, visibility: :internal})

    conn = get(build_conn(), "/support/kb?org=#{tenant.id}")

    assert conn.status == 200,
           "the /support/kb page did not render (status=#{conn.status})"

    body = conn.resp_body
    assert body =~ "Knowledge base", "the agent KB surface did not render"
    assert body =~ "Phase5 agent-visible article",
           "the agent KB did not read the CMS namespace — the :kb_namespace label is not wired on the support mount"

    refute body =~ "Knowledge base not set up.",
           "the honest 'not adopted' empty state rendered even though kb_namespace IS wired"
  end

  # ==========================================================================
  # CSAT — the tokenized public response route (`:csat`)
  # ==========================================================================

  test "a garbage CSAT token renders the one generic invalid state, never an oracle" do
    conn = get(build_conn(), "/support/csat/not-a-real-token")

    assert conn.status == 200,
           "the /support/csat/:token page did not render (status=#{conn.status}) — the :csat mount is missing or crashing"

    body = conn.resp_body
    assert body =~ ~s(id="csat-respond"), "the CSAT surface did not render"
    assert body =~ "This link is no longer valid.",
           "an unknown token must collapse to the ONE generic invalid message"

    refute body =~ "How did we do?", "the score form must not render for an invalid token"
  end

  test "a minted single-use token records the response, then is honestly invalid on replay" do
    tenant = create_org!("Phase5 CSAT QA")
    ticket = create_ticket!(tenant)
    token = mint_token!(tenant, ticket)

    assert csat_count(tenant.id) == 0

    # 1. Through the REAL route, unauthenticated: a pending token renders the score form.
    conn = get(build_conn(), "/support/csat/#{token}")

    assert conn.status == 200
    assert conn.resp_body =~ "How did we do?", "a pending token must render the score form"
    assert conn.resp_body =~ ~s(id="csat-score-form")

    # 2. The submission itself. Driven through the LiveView's OWN public callbacks
    #    (`mount/3` + `handle_event/3`) — the same entry points Phoenix dispatches
    #    the socket events to; `Phoenix.LiveViewTest.live/2` is not used because it
    #    requires a `lazy_html` test-only dep this host does not carry.
    mount_struct =
      Mount.new(:csat, Samenerp.Support, Samenerp.Repo, labels: %{login_path: "/login"})

    socket =
      %Phoenix.LiveView.Socket{}
      |> Phoenix.Component.assign(:samen_mount, mount_struct)
      |> Phoenix.Component.assign(:samen_acting_as, false)

    {:ok, socket} =
      CsatRespondLive.mount(
        %{"token" => token},
        %{"samen_mount" => Mount.to_session(mount_struct)},
        socket
      )

    assert socket.assigns.state == :form

    {:noreply, socket} =
      CsatRespondLive.handle_event(
        "submit_survey",
        %{"comments" => "Great support", "score" => "5"},
        socket
      )

    assert socket.assigns.state == :thanks
    assert csat_count(tenant.id) == 1, "the score submission must persist exactly one Csat row"

    # 3. Replay: the token is single-use, so a FRESH visit re-derives the consumed
    #    state via `preview/2` and shows the same generic invalid message.
    replay = get(build_conn(), "/support/csat/#{token}")

    assert replay.status == 200
    assert replay.resp_body =~ "This link is no longer valid.",
           "a consumed token must be honestly invalid on replay"

    refute replay.resp_body =~ "How did we do?"
  end
end
