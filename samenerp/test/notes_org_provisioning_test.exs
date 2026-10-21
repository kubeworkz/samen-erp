defmodule Samenerp.NotesOrgProvisioningTest do
  @moduledoc """
  WS-Notes Phase 6, unit 1c — a NEW tenant org is provisioned for Pages search AT CREATION.

  `Samenerp.Seeds.ensure_notes_search_index!/1` could only ever repair the org the seeder knew
  about: a tenant created afterwards had no registry rows, so its `/pages?q=` answered the
  fail-closed empty set forever — wired, and indistinguishable from "nothing matches". The fix
  is the framework's org-creation seam (`Samen.Web.OrgProvisioning`), wired in
  `config/config.exs` at exactly one line and invoked by BOTH creation paths (self-serve
  `/signup`, and the operator plane's New-account write). Proven here on THIS host:

    1. the hook is wired and resolvable from the MOUNT (not a hardcoded app name), which is how
       both call sites reach it;
    2. `POST /signup` through the REAL router yields an org that already carries exactly the two
       non-PII registry rows — with no seed call anywhere in the test;
    3. that brand-new org's `/pages?q=` answers for a block its own member typed (the point of
       the exercise: a fresh tenant is searchable, not silently empty);
    4. an org created DIRECTLY still has no registry rows — the anti-tautology control proving
       the rows above come from the creation path, not from some global default;
    5. `Seeds.backfill_notes_search_index!/0` repairs orgs that predate the wiring (the deploy
       half: `seed!/0,1` runs on every boot).

  A failing hook never unwinds a created account, and that is proven in the framework's own
  suite (`samen_web/test/samen/web/org_provisioning_test.exs`), where the seam lives.
  """

  use Samenerp.DataCase, async: false

  import Phoenix.ConnTest

  require Ash.Query

  alias Samen.Web.Mount
  alias Samen.Web.Notes.Writes
  alias Samen.Web.OrgProvisioning
  alias Samenerp.Operator
  alias Samenerp.Primitives.SearchIndex
  alias Samenerp.Seeds

  @endpoint SamenerpWeb.Endpoint
  # Satisfies `Samen.Auth.PasswordPolicy` and, deliberately, no message template could ever echo it.
  @password "Provisioning!2026x9"

  setup do
    start_supervised!(@endpoint)
    :ok
  end

  # ---------------------------------------------------------------------------
  # 1. the wiring itself
  # ---------------------------------------------------------------------------

  test "this host wires the Pages-index hook, and the seam resolves it from the MOUNT" do
    assert OrgProvisioning.hooks(:samenerp) == [{Seeds, :ensure_notes_search_index!, []}],
           "config :samenerp, :org_provisioning does not name the Pages search hook"

    assert OrgProvisioning.configured?(:samenerp)

    # Both call sites pass a MOUNT, so `Mount.otp_app/1` is what turns a request into the app
    # whose config holds the hook. If this resolved `nil` the seam would silently no-op — the
    # exact failure mode unit 1c exists to remove — so it is pinned here, not assumed.
    assert Mount.otp_app(Seeds.notes_mount()) == :samenerp
  end

  # ---------------------------------------------------------------------------
  # 2 + 3. a self-serve signup is provisioned, and is searchable
  # ---------------------------------------------------------------------------

  test "SIGNUP provisions the new org: exactly Doc.title + DocBlock.text, with no seed call" do
    org = signup!("Provisioned Signup QA")

    rows = index_rows(org.id)

    assert Enum.sort(Enum.map(rows, & &1.field_name)) == ["text", "title"],
           "a freshly signed-up org did not get its Pages registry rows at creation"

    resources = Enum.map(rows, & &1.resource_name)
    assert Enum.any?(resources, &String.ends_with?(&1, ".Doc")), "Doc.title is not registered"

    assert Enum.any?(resources, &String.ends_with?(&1, ".DocBlock")),
           "DocBlock.text is not registered"

    refute Enum.any?(rows, &String.contains?(&1.field_name, "secure")),
           "a vaulted column was registered into the search index"

    # Anti-tautology: an org created DIRECTLY (bypassing both creation paths) has nothing, so
    # the rows above are the creation path doing the work — not a default or a seed side effect.
    direct = create_org!("Provisioned Direct QA")

    assert index_rows(direct.id) == [],
           "a directly-created org already had registry rows, so this test cannot distinguish " <>
             "the creation seam from a global default"
  end

  test "a brand-new org's /pages?q= answers for its OWN block (a fresh tenant is searchable)" do
    org = signup!("Provisioned Search QA")

    doc_id =
      write_page!(org.id, "First page", "a freshly registered tenant typed these words")

    html = get_page!("/pages?org=#{org.id}&q=freshly")

    assert html =~ ~s(id="note-search-hit-),
           "the new org's plain block did not match — signup provisioned no registry rows"

    refute html =~ ~s(id="notes-search-empty")
    assert html =~ "/pages/#{doc_id}?org=#{org.id}", "the hit does not deep-link to the page"
  end

  # ---------------------------------------------------------------------------
  # 5. the backfill half (orgs that predate the wiring)
  # ---------------------------------------------------------------------------

  test "the seed BACKFILL registers an org that predates the hook" do
    org = create_org!("Provisioned Backfill QA")

    assert index_rows(org.id) == [],
           "the control org was already registered, so the backfill assertion would be vacuous"

    assert :ok = Seeds.backfill_notes_search_index!()

    assert Enum.sort(Enum.map(index_rows(org.id), & &1.field_name)) == ["text", "title"],
           "the seed backfill did not register an existing tenant org"
  end

  # ---------------------------------------------------------------------------
  # harness
  # ---------------------------------------------------------------------------

  # A REAL self-serve signup through the browser pipeline (CSRF token off the GET form, then
  # the native POST the no-JS floor uses — `Samen.Web.Auth.AccountController.register/2`).
  defp signup!(org_name) do
    form = get(build_conn(), "/signup")
    assert form.status == 200, "GET /signup did not render (status=#{form.status})"

    conn =
      form
      |> recycle()
      |> post("/signup", %{
        "registration" => %{
          "org_name" => org_name,
          "first_name" => "Pat",
          "last_name" => "Provision",
          "email" => "provision-#{System.unique_integer([:positive])}@example.test",
          "password" => @password
        },
        "_csrf_token" => csrf_token!(form.resp_body)
      })

    assert redirected_to(conn) == "/signup?registered=1",
           "the signup POST did not take the fresh-registration branch (redirect=#{inspect(conn.status)})"

    find_org!(org_name, "the signup did not create the org row")
  end

  defp create_org!(name) do
    Operator.Org
    |> Ash.Changeset.for_create(:create, %{name: name}, authorize?: false)
    |> Ash.create!(authorize?: false)
  end

  defp find_org!(name, message) do
    Operator.Org
    |> Ash.Query.filter(name == ^name)
    |> Ash.Query.limit(1)
    |> Ash.read!(authorize?: false)
    |> case do
      [org] -> org
      [] -> flunk(message)
    end
  end

  defp csrf_token!(body) do
    case Regex.run(~r/name="_csrf_token" value="([^"]+)"/, body) do
      [_, token] -> token
      _ -> flunk("the /signup form must render a _csrf_token input")
    end
  end

  defp write_page!(org_id, title, text) do
    mount = Seeds.notes_mount()
    scope = Seeds.notes_scope(org_id)

    {:ok, doc} = Writes.create_page(mount, scope, %{title: title})
    {:ok, _block} = Writes.insert_block(mount, scope, doc.id, %{type: :paragraph, text: text})

    doc.id
  end

  defp get_page!(path) do
    conn = get(build_conn(), path)
    assert conn.status == 200, "GET #{path} did not render (status=#{conn.status})"
    conn.resp_body
  end

  defp index_rows(org_id) do
    SearchIndex
    |> Ash.Query.filter(org_id == ^org_id)
    |> Ash.read!(authorize?: false)
  end
end
