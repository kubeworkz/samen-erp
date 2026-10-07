defmodule Samenerp.Phase3SurfaceTest do
  @moduledoc """
  Phase-3 host surface proofs — Search & Discovery, driven through the REAL
  router (no mount constructed here; the `Samenerp.Phase1SurfaceTest` /
  `Samenerp.Phase2SurfaceTest` discipline):

    * `GET /search` — the `samen_search_routes(:search, Samenerp.Primitives, …)`
      one-liner surfaces the framework ⌘K palette (200 + the input), an
      unmatched term renders the honest "No matches." posture, and a SEEDED
      hit proves the KERNEL engine end-to-end on this host: a registered
      non-PII column + a real upload → the ranked result renders in the palette
      on the TENANT plane, while the SAME query from another org never sees it
      (registry + reads both org-scoped by the kernel, not by this router).
      No tsvector trigger is required for correctness — the engine builds its
      tsvector at QUERY TIME from the registered columns (the pawchart posture;
      driftwood additionally ships an E4 materialization trigger as hardening).
    * `GET /csv/import/company` + `GET /csv/export/company` — the
      `samen_csv_routes(:csv, Samenerp.Crm, …)` adoption (driftwood/pawchart
      shape): the import LiveView renders, the export download serves RFC-4180
      bytes (text/csv, `filename="company.csv"`) carrying a SEEDED row, and a
      name outside the domain resolves DENY-BY-DEFAULT to 404 — no module
      minting, no existence oracle.
    * `GET /analytics` — the `samen_tenant_analytics_routes(…)` P17 own-org
      funnel: an org with no rollup rows renders the honest empty state, and a
      seeded >= k funnel renders floored counts for the CALLER's org only — the
      foreign org's sentinel count never appears (org bound from the resolved
      scope, never from `?org=` beyond selecting among authorized orgs).

  The `paf_product_event_rollup` table this phase reads comes from migration
  20261006140000 — samenerp had NO rollup tables before Phase 3 (the mounted
  `/operator/analytics` + `/operator/revenue` read them by name, so that
  migration closed those latent holes too). NON-PII throughout: search display
  is the registered non-PII allowlist, CSV cells resolve through PiiResolution
  on the acting plane, analytics is token-blind (counts + stage labels only).
  """

  use Samenerp.DataCase, async: false

  import Phoenix.ConnTest

  alias Samenerp.Crm.Company
  alias Samenerp.Operator, as: Op
  alias Samenerp.Primitives.SearchIndex

  @endpoint SamenerpWeb.Endpoint

  @hit_filename "quarterly invoice report.pdf"
  @foreign_filename "invoice for another org.pdf"

  setup do
    start_supervised!(SamenerpWeb.Endpoint)
    :ok
  end

  defp create_org!(name) do
    Op.Org
    |> Ash.Changeset.for_create(:create, %{name: name}, authorize?: false)
    |> Ash.create!(authorize?: false)
  end

  # Register the ONE non-PII File column the engine may search for this org —
  # the driftwood gate_e4 shape (the SearchIndexGuard refuses vault-routed
  # columns at register time; `filename` is plain).
  defp register_search!(org_id) do
    SearchIndex
    |> Ash.Changeset.for_create(
      :create,
      %{
        resource_name: inspect(Samenerp.Primitives.File),
        field_name: "filename",
        vector_column: "efl_search_vector",
        enabled: true,
        ts_config: "english",
        org_id: org_id
      },
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end

  # A real upload through the ONE storage_key-minting chokepoint (fresh files
  # are quarantined — irrelevant to search, which reads the filename column).
  defp upload!(org_id, filename) do
    root = Path.join(System.tmp_dir!(), "phase3_search_#{System.unique_integer([:positive])}")
    on_exit(fn -> Elixir.File.rm_rf!(root) end)

    {:ok, file} =
      Samen.Files.upload(
        %{org_id: org_id},
        %{filename: filename, content_type: "application/pdf", binary: "x"},
        file_module: Samenerp.Primitives.File,
        repo: Samenerp.Repo,
        storage_config: %{root: root},
        allowed_content_types: ~w(application/pdf)
      )

    file
  end

  # The raw funnel rollup rows (host-invariant table, no Ash resource — the
  # samen_web tenant_analytics e2e insert shape). Counts sit at/above the k=5
  # floor so they RELEASE; the foreign sentinel is unmistakable if it ever
  # leaks into the caller's DOM.
  defp insert_paf!(org_id, stage, actor_count) do
    Ecto.Adapters.SQL.query!(
      Samenerp.Repo,
      """
      INSERT INTO paf_product_event_rollup (paf_org_id, paf_kind, paf_stage, paf_actor_count)
      VALUES ($1, 'funnel', $2, $3)
      """,
      [Ecto.UUID.dump!(org_id), stage, actor_count]
    )
  end

  # ==========================================================================
  # Search
  # ==========================================================================

  test "the search surface renders with its palette and the honest no-match posture" do
    tenant = create_org!("Phase3 Search Empty")

    conn = get(build_conn(), "/search?org=#{tenant.id}")

    assert conn.status == 200,
           "the /search page did not render — the samen_search_routes mount is missing or crashing"

    body = conn.resp_body
    assert body =~ ~s(id="cmdk"), "the command palette did not render"
    assert body =~ "Search everything…", "the search input did not render"

    miss = get(build_conn(), "/search?org=#{tenant.id}&q=zzz-no-such-thing")
    assert miss.status == 200
    assert miss.resp_body =~ "No matches.", "the honest no-match posture did not render"
  end

  test "a registered + uploaded file ranks in the palette for its org, never for another" do
    org_a = create_org!("Phase3 Search Org A")
    org_b = create_org!("Phase3 Search Org B")

    register_search!(org_a.id)
    register_search!(org_b.id)

    upload!(org_a.id, @hit_filename)
    upload!(org_a.id, "unrelated meeting notes.pdf")
    upload!(org_b.id, @foreign_filename)

    hit = get(build_conn(), "/search?org=#{org_a.id}&q=invoice")

    assert hit.status == 200,
           "the seeded search did not render — the kernel engine path is unreachable on this host"

    body = hit.resp_body
    assert body =~ "cmdk-hit", "the ranked result row did not render"
    assert body =~ @hit_filename, "the org-scoped match did not render in the palette"
    refute body =~ @foreign_filename,
           "another org's row leaked into this org's search results"
  end

  # ==========================================================================
  # CSV
  # ==========================================================================

  test "the CSV import surface renders for a domain resource" do
    tenant = create_org!("Phase3 CSV Import")

    conn = get(build_conn(), "/csv/import/company?org=#{tenant.id}")

    assert conn.status == 200,
           "the /csv/import/company page did not render — the samen_csv_routes mount is missing or crashing"

    body = conn.resp_body
    assert body =~ ~s(id="csv-import-panel"), "the import panel did not render"
    assert body =~ "Import company rows", "the resource heading did not render"
    assert body =~ "governed create", "the governed-chokepoint posture copy did not render"
  end

  test "CSV export serves a seeded row as text/csv; unknown resources 404 deny-by-default" do
    tenant = create_org!("Phase3 CSV Export")
    company_name = "Phase3 Export Vault Co"

    Company
    |> Ash.Changeset.for_create(
      :create,
      %{org_id: tenant.id, name: company_name, website: "https://phase3.example"},
      authorize?: false
    )
    |> Ash.create!(authorize?: false)

    conn = get(build_conn(), "/csv/export/company?org=#{tenant.id}")

    assert conn.status == 200,
           "the CSV export download did not serve (status=#{conn.status} body=#{inspect(conn.resp_body)}) — " <>
             "the /csv/export/:resource route is missing or refusing"

    assert Enum.join(Plug.Conn.get_resp_header(conn, "content-type"), "; ") =~ "text/csv",
           "the export must be delivered as text/csv, got " <>
             inspect(Plug.Conn.get_resp_header(conn, "content-type"))

    assert Plug.Conn.get_resp_header(conn, "content-disposition") == [
             ~s(attachment; filename="company.csv")
           ],
           "the export must download as company.csv"

    assert conn.resp_body =~ company_name,
           "the seeded row did not round-trip through the export bytes"

    deny = get(build_conn(), "/csv/export/does_not_exist?org=#{tenant.id}")
    assert deny.status == 404,
           "a resource outside the mounted domain must 404 — resolve_resource/2 is deny-by-default"
  end

  # ==========================================================================
  # Tenant analytics (P17)
  # ==========================================================================

  test "own-org analytics renders the honest empty state with no rollup rows" do
    tenant = create_org!("Phase3 Analytics Empty")

    conn = get(build_conn(), "/analytics?org=#{tenant.id}")

    assert conn.status == 200,
           "the /analytics page did not render — the samen_tenant_analytics_routes mount is missing or crashing"

    body = conn.resp_body
    assert body =~ "Your organization", "the P17 surface did not render"
    assert body =~ ~s(id="analytics-empty"), "the honest empty state did not render"
    assert body =~ "No own-org activation data yet",
           "the empty-state copy did not render"
  end

  test "the seeded funnel renders floored counts for the caller's org only" do
    org_a = create_org!("Phase3 Analytics Org A")
    org_b = create_org!("Phase3 Analytics Org B")

    # Own org: every stage >= k (=5) so counts RELEASE (distinctive values).
    insert_paf!(org_a.id, "signup", 61)
    insert_paf!(org_a.id, "first_run", 55)
    insert_paf!(org_a.id, "first_record", 50)

    # Foreign org: an unmistakable sentinel the forge must NEVER render.
    insert_paf!(org_b.id, "signup", 987_654)

    conn = get(build_conn(), "/analytics?org=#{org_a.id}")

    assert conn.status == 200

    body = conn.resp_body
    assert body =~ ~s(id="funnel-table"), "the funnel table did not render"
    assert body =~ ">61<",
           "the caller's OWN org's floored signup count did not render"
    refute body =~ "987654",
           "a foreign org's count leaked into this org's analytics"
  end
end
