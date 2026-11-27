defmodule Samenerp.HomepageRouteTest do
  @moduledoc """
  `/` IS THE MARKETING HOMEPAGE (2026-11-26) — the landing page used to be a
  ~330-line heredoc inside `SamenerpWeb.PageController`: a scaffolded module grid
  ("47 modules, 697 tests", "Inherited from Samen Web") that drifted from the real
  product and that nothing in the suite read. It is now a plain HTML artifact at
  `priv/homepage.html`, served byte for byte by `index/2`.

  The regression this file exists for is silent, not loud: a revert to a
  controller-owned string, a typo in the priv path, or a fallback to an empty 200
  would leave every other test green while `/` quietly stopped being the
  marketing page. So the oracle is the CHECKED-IN ARTIFACT, not a phrase: the
  response must equal the bytes of `samenerp/priv/homepage.html` read from the
  source tree, and the scaffold's own fingerprints (`47 modules`, `Inherited from
  Samen Web`) must be absent, which no future marketing copy will accidentally
  satisfy. Reading the source rather than `Application.app_dir/2` is deliberate —
  the latter is the `_build` copy Mix makes, so a stale or unbuilt artifact would
  compare stale-to-stale and pass.

  The second leg pins the neighbours that share this controller: serving a
  beautiful homepage is not a trade for a dark `/healthz`, a lying `/readyz` or a
  404'd `/api/openapi.json`. The health checks are also what the deploy gate
  probes, so a route regression here is a release regression.

  A third leg guards the LINK graph, because the artifact comparison above is
  blind to it: a copy edit that swaps `/signup` for `#`, or restores the
  production-only `https://samenerp.kubeworkz.io/docs` CTA, still serves the
  artifact byte for byte. The page must keep linking this host's `/docs`,
  `/signup` and `/login` routes, and must not reach for the production origin
  again — while the repository link stays external, since GitHub is not a route
  here.

  Refutability: replacing `index/2`'s body with the old scaffold (or emptying the
  artifact) fails the first leg by name; unmounting any neighbour route fails the
  second; pointing a signup CTA at `#`, or restoring one absolute production
  link, fails the third. Each was flipped and restored byte-exact.
  """

  use Samenerp.DataCase, async: false

  import Phoenix.ConnTest

  @endpoint SamenerpWeb.Endpoint

  # The CHECKED-IN artifact, read from THIS repo's source tree — not the path
  # `PageController.homepage!/0` serves at request time. Serving reads
  # `_build/<env>/lib/samenerp/priv`, which Mix COPIES rather than symlinks on a
  # Windows checkout, so comparing the response against app_dir would let an edit
  # that was never rebuilt pass stale-to-stale. Reading `samenerp/priv` makes a
  # stale or missing build copy fail here instead.
  @homepage Path.expand("../priv/homepage.html", __DIR__)

  setup do
    start_supervised!(@endpoint)
    :ok
  end

  defp homepage_bytes, do: File.read!(@homepage)

  # Line endings are checkout business, not content: `.gitattributes` hands this
  # Windows worktree CRLF while the blob (and the build copy Mix derives from it)
  # is LF. Normalising both sides keeps the comparison pinned to CONTENT, which is
  # what the route promises.
  defp normalize_eol(body), do: String.replace(body, "\r\n", "\n")

  # The readiness contract the route must mirror, computed the same way `readyz/2`
  # computes it — the oracle is the check, not this environment's verdict.
  defp readiness_verdict do
    case Samen.Web.Readiness.check(repo: Samenerp.Repo) do
      {:ok, _checks} -> {200, "ready"}
      {:error, _checks} -> {503, "not ready"}
    end
  end

  test "GET / serves priv/homepage.html verbatim, not the scaffolded module grid" do
    # ANTI-TAUTOLOGY: an empty or missing artifact would make the byte comparison
    # below either fail for the wrong reason or pass on nothing at all, so the
    # artifact is asserted first, on its own terms (the marketing h1 and a body
    # far larger than any placeholder).
    artifact = homepage_bytes()

    assert artifact =~ "<h1>Bend it to your business.",
           "priv/homepage.html no longer carries the marketing h1 — the route would serve " <>
             "whatever artifact replaced it and this test would still be comparing bytes"

    assert byte_size(artifact) > 10_000,
           "priv/homepage.html is #{byte_size(artifact)} bytes — too small to be the homepage, " <>
             "so a placeholder would satisfy the verbatim comparison below"

    conn = get(build_conn(), "/")

    assert conn.status == 200, "GET / answered #{conn.status} — the marketing homepage is down"

    assert normalize_eol(conn.resp_body) == normalize_eol(artifact),
           "GET / did not serve the checked-in priv/homepage.html: the response is " <>
             "#{byte_size(conn.resp_body)} bytes against the source artifact's " <>
             "#{byte_size(artifact)}. A controller-owned page (the retired scaffold) is serving " <>
             "instead, or the _build copy is stale — Mix copies priv, so an HTML edit needs a " <>
             "`mix compile` before the route can serve it"

    # The verifiable shape of the page, so a failure names what is missing rather
    # than only "bytes differ".
    assert conn.resp_body =~ "<title>SamenERP — bend it to your business. It won't break.</title>",
           "GET / served bytes but not the marketing title"

    assert conn |> Plug.Conn.get_resp_header("content-type") |> hd() =~ "text/html",
           "GET / did not answer an HTML document"

    # The two fingerprints of the scaffold this route replaced. Both are stable
    # enough that no marketing copy will reintroduce them by accident.
    refute conn.resp_body =~ "Inherited from Samen Web",
           "GET / rendered the retired scaffold's 'Inherited from Samen Web' section"

    refute conn.resp_body =~ "47 modules",
           "GET / rendered the retired scaffold's '47 modules' hero"
  end

  # The routes this host owns that the homepage must advertise. A copy edit may
  # relabel the links or add more rooms to the page; it may not stop linking the
  # pages a visitor needs to start using the product.
  @internal_routes ["/docs", "/signup", "/login"]

  test "GET / links this host's docs and account routes, never an absolute site origin" do
    conn = get(build_conn(), "/")

    hrefs =
      conn.resp_body
      |> then(&Regex.scan(~r/href="([^"]+)"/, &1, capture: :all_but_first))
      |> List.flatten()

    # ANTI-TAUTOLOGY: if the extraction ever stops matching (a switch to
    # single-quoted attributes, a templating rewrite), the three assertions below
    # would pass on an empty list and report nothing. The page carries far more
    # links than this floor.
    assert length(hrefs) > 20,
           "only #{length(hrefs)} hrefs parsed from GET / — the link scan below is vacuous"

    for route <- @internal_routes do
      assert route in hrefs,
             "GET / no longer links #{route} — the app-relative route was dropped from the " <>
               "page (hrefs: #{inspect(Enum.uniq(hrefs))})"
    end

    # The rewiring's whole point: production is not the only host this page is
    # served from (preview, self-host, a self-hoster's domain, the test endpoint),
    # so an absolute samenerp.kubeworkz.io CTA sends those readers somewhere they
    # did not ask to go.
    absolute = Enum.filter(hrefs, &String.contains?(&1, "samenerp.kubeworkz.io"))

    assert absolute == [],
           "GET / links the production origin again (#{Enum.join(absolute, ", ")}) — the " <>
             "homepage must resolve docs and auth against whatever host is serving it"

    # The inverse of the rule above: GitHub is NOT a route on this host, so the
    # repository CTA must stay absolute rather than be "fixed" into a local path
    # that would 404.
    assert Enum.any?(hrefs, &String.starts_with?(&1, "https://github.com/")),
           "GET / no longer links the repository — the external GitHub link was dropped"
  end

  test "the liveness, readiness and OpenAPI endpoints still answer beside the homepage" do
    # Sharing a controller with the homepage is exactly how a landing-page change
    # takes the deploy gate's probes down with it — these are the same three
    # endpoints `scripts/deploy-prod.sh` and the docs surface depend on.
    health = get(build_conn(), "/healthz")

    assert health.status == 200, "GET /healthz answered #{health.status} — liveness is down"
    assert health.resp_body == "ok", "GET /healthz answered #{inspect(health.resp_body)}"

    # Readiness is environment-dependent BY DESIGN: it reports whether Postgres,
    # the KMS wrapped-DEK store and Oban are actually up. In this test env Oban is
    # not started, so the honest answer is 503 — hard-coding 200 here would either
    # be a lie or push someone to fake readiness to go green. What must not change
    # is that the probe ANSWERS THE LIVE VERDICT: 200 "ready" when the check
    # passes, 503 "not ready\n…" when it does not. A 404 (route gone), a 500 or a
    # bare 200 that skips the check is the regression.
    ready = get(build_conn(), "/readyz")
    {expected_status, expected_phrase} = readiness_verdict()

    assert ready.status == expected_status,
           "GET /readyz answered #{ready.status} (body #{inspect(ready.resp_body)}) but " <>
             "Samen.Web.Readiness.check/1 returned #{expected_status} — the probe no longer " <>
             "reports the real verdict"

    assert ready.resp_body =~ expected_phrase,
           "GET /readyz answered #{ready.status} without #{inspect(expected_phrase)} in its " <>
             "body (#{inspect(ready.resp_body)})"

    spec = get(build_conn(), "/api/openapi.json")

    assert spec.status == 200, "GET /api/openapi.json answered #{spec.status} — the spec is down"

    assert spec |> Plug.Conn.get_resp_header("content-type") |> hd() =~ "application/json",
           "GET /api/openapi.json did not answer JSON"

    document = Jason.decode!(spec.resp_body)

    assert document["openapi"] =~ ~r/^3\./,
           "the served document is not OpenAPI 3.x (#{inspect(document["openapi"])})"

    assert is_map(document["paths"]) and map_size(document["paths"]) > 0,
           "the served document advertises no paths — the spec body is empty"
  end
end
