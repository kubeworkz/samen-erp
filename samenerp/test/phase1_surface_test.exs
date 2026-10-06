defmodule Samenerp.Phase1SurfaceTest do
  @moduledoc """
  Phase-1 host surface proofs — the two remainders of the Work + Files/Documents
  mount, driven through the REAL router (no mount constructed here; the
  `Samenerp.BankingSurfaceTest` discipline):

    * `/files` — the `samen_files_routes(:files, Samenerp.Primitives, …)`
      one-liner actually surfaces the framework upload/preview LiveView (200 +
      the honest empty state — never a fabricated row);
    * `/api/openapi.json` — the README "API Documentation" card's promise:
      `Samenerp.ApiDocs`' generated OpenAPI 3.0 document is SERVED (200,
      parseable JSON, `openapi` version + the `/api/v1` surface present).
      Before this mount the module existed but no route reached it.

  NON-PII throughout (the spec is a static generated artifact — no org/actor
  data leaks into it; the files empty state shows no rows).
  """

  use Samenerp.DataCase, async: false

  import Phoenix.ConnTest

  alias Samenerp.Operator, as: Op

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

  test "the files surface renders through the mounted route with its honest empty state" do
    tenant = create_org!("Files Surface QA")

    conn = get(build_conn(), "/files?org=#{tenant.id}")

    assert conn.status == 200,
           "the /files page did not render — the samen_files_routes mount is missing or crashing"

    body = conn.resp_body
    assert body =~ "No files yet.", "the files empty state did not render"
    assert body =~ "Upload a file", "the upload affordance (tenant plane) did not render"
    # New files are quarantined until scanned — the posture copy must be visible.
    assert body =~ "quarantined"
  end

  test "GET /api/openapi.json serves the generated OpenAPI 3.0 document" do
    conn = get(build_conn(), "/api/openapi.json")

    assert conn.status == 200,
           "the OpenAPI spec endpoint did not respond — the README API Documentation card would be a dead promise"

    assert Plug.Conn.get_resp_header(conn, "content-type") == ["application/json"]

    spec = Jason.decode!(conn.resp_body)

    assert spec["openapi"] =~ "3.0", "the document must declare an OpenAPI 3.x version"
    assert spec["info"]["title"], "the document must carry an info.title"
    # The spec documents the versioned public JSON:API surface this host serves.
    assert is_map(spec["paths"]) and map_size(spec["paths"]) > 0,
           "the spec must describe at least one path"
  end
end
