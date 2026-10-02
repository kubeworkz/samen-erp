defmodule Samenerp.DirectoryTest do
  @moduledoc """
  The tenant-directory seam (`Samenerp.Directory` + the `org_directory` label on
  `@current_org_labels`):

    * `orgs/0` lists ONLY real tenant orgs — the operator seat and the
      operator-plan debris older seed runs left behind are excluded;
    * the ROUTER-wired mount resolves the REAL display name, so the topbar
      breadcrumb on a real dispatched page renders `<a …>Gridworkz QA</a>`
      instead of the "Workspace" fallback — the end-to-end proof that the
      sidebar-header/breadcrumb fix is actually mounted (a hand-built mount
      would not catch a missing router label).
  """
  use Samenerp.DataCase, async: false

  import Phoenix.ConnTest

  alias Samen.Web.CurrentOrg
  alias Samen.Web.Mount
  alias Samenerp.Directory
  alias Samenerp.Operator, as: Op

  @endpoint SamenerpWeb.Endpoint

  setup_all do
    # test_helper.exs boots the Repo directly; the web children are siblings of
    # the repo in the app supervisor, so start the endpoint the same way
    # AuthLoginRedirectTest does (plain HTTP dispatch needs no PubSub).
    case SamenerpWeb.Endpoint.start_link() do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    :ok
  end

  defp create_org!(name, attrs \\ %{}) do
    Op.Org
    |> Ash.Changeset.for_create(:create, Map.merge(%{name: name}, attrs), authorize?: false)
    |> Ash.create!(authorize?: false)
  end

  test "orgs/0 lists tenant orgs, excluding the operator seat and operator-plan debris" do
    tenant = create_org!("Gridworkz QA")

    # The operator seat (seeds posture: plan "operator", slug "samenerp", self-parented).
    _operator =
      create_org!("Samen ERP", %{
        plan: "operator",
        slug: "samenerp",
        org_id: Samenerp.Seeds.operator_org_id()
      })

    # The debris older seed runs left behind (same plan/slug, random id).
    _debris_a = create_org!("Samen ERP", %{plan: "operator", slug: "samenerp"})
    _debris_b = create_org!("Samen ERP", %{plan: "operator", slug: "samenerp"})

    orgs = Directory.orgs()

    assert {tenant.id, "Gridworkz QA"} in orgs
    refute Enum.any?(orgs, fn {_id, name} -> name == "Samen ERP" end)
    # Sorted by name (the switcher's order contract).
    assert orgs == Enum.sort_by(orgs, &elem(&1, 1))
  end

  test "orgs/0 tolerates a tenant org with no plan (blueprint nil-plan rows stay listable)" do
    tenant = create_org!("Planless Tenant", %{plan: nil})
    assert {tenant.id, "Planless Tenant"} in Directory.orgs()
  end

  test "the router-mounted CRM page resolves the org name in the breadcrumb (not 'Workspace')" do
    tenant = create_org!("Gridworkz QA")

    conn = get(build_conn(), "/crm/contacts?org=#{tenant.id}")
    assert conn.status == 200
    html = conn.resp_body

    # The topbar crumb: the org crumb is a LIVE link labeled with the RESOLVED name.
    assert html =~
             ~r/<div class="crumb">.*?<a href="\/crm\/dashboard\?org=#{Regex.escape(tenant.id)}">Gridworkz QA<\/a>/s

    # Fallback posture intact: the crumb did NOT render the static fallback label.
    refute html =~ ~r/<div class="crumb">.*?Workspace/s
  end

  test "name/2 on a router-shaped mount returns the directory display name" do
    tenant = create_org!("Gridworkz QA")

    mount =
      Mount.new(:crm, Samenerp.Crm, Samenerp.Repo,
        labels: %{
          authn: {:app_env, :samenerp, :auth_required?},
          identity_namespace: Samenerp.Operator,
          org_directory: {Samenerp.Directory, :orgs, []}
        }
      )

    assert CurrentOrg.name(mount, tenant.id) == "Gridworkz QA"
    # Unknown org still falls back — never raises.
    assert CurrentOrg.name(mount, "missing-org") == "Workspace"
  end
end
