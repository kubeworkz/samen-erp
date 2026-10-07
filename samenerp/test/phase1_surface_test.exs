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

  test "the byte-serve route arrives with its mount and refuses a fresh upload at the quarantine gate" do
    tenant = create_org!("Phase1 Bytes QA")

    root =
      Path.join(System.tmp_dir!(), "phase1_bytes_#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(root) end)

    {:ok, file} =
      Samen.Files.upload(
        %{org_id: tenant.id},
        %{filename: "quarantined-report.pdf", content_type: "application/pdf", binary: "x"},
        file_module: Samenerp.Primitives.File,
        repo: Samenerp.Repo,
        storage_config: %{root: root},
        allowed_content_types: ~w(application/pdf)
      )

    conn = get(build_conn(), "/files/#{file.id}/bytes?org=#{tenant.id}")

    # The load-bearing part of this assertion is that the controller GOT its
    # mount: `samen_files_routes/3` used to emit this route bare, so
    # `conn.assigns[:samen_mount]` was nil and EVERY real byte download 503'd
    # ("no mount"). With the mount riding the route assigns, the fail-closed
    # quarantine gate is what answers for a fresh upload — 403 + "quarantined",
    # never bytes.
    assert conn.status == 403,
           "expected the quarantine gate to refuse a fresh upload (status=#{conn.status} body=#{inspect(conn.resp_body)})"

    assert conn.resp_body =~ "quarantined",
           "the byte-serve route must answer with the honest quarantine refusal"
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
