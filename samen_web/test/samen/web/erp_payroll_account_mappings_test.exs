defmodule Samen.Web.ErpPayrollAccountMappingsTest do
  @moduledoc """
  The Finance payroll account mapping admin page (`/erp/payroll-mappings`).

    * the list is bounded, org-scoped, and shows each provider code with the
      mapped host account;
    * an admin can create a mapping and change its account through the
      resource's own actions;
    * an armed member sees the mappings but gets no write affordance, and a
      crafted save is refused — the kernel's `RoleAtLeast :admin` policy is
      verified directly too;
    * a cross-org account is refused by `Samen.Policy.SameOrgFk` on both create
      and update, and nothing is persisted;
    * the literal route resolves to this page, not the generic ERP surface.
  """

  use Samen.WebTest.DataCase, async: false

  require Ash.Query

  alias Samen.Web.Finance.PayrollAccountMappings.Live
  alias Samen.Web.TenantRole

  alias Samen.WebTest.Erp.Account
  alias Samen.WebTest.Erp.PayrollAccountMapping

  @org "55555555-6666-7777-8888-999999999999"
  @path "/erp/payroll-mappings"

  # -- harness ----------------------------------------------------------------

  defp open do
    mount = build_mount(:erp)
    session = mount_session(mount)
    params = %{"org" => @org}

    {:ok, socket} = Live.mount(params, session, %Phoenix.LiveView.Socket{})

    {:noreply, socket} =
      Live.handle_params(params, "http://localhost#{@path}", socket)

    socket
  end

  defp event(socket, name, params) do
    {:noreply, socket} = Live.handle_event(name, params, socket)
    socket
  end

  defp render(socket), do: render_html(Live, socket.assigns)

  # -- seeds ------------------------------------------------------------------

  defp seed_account(org_id, code, name) do
    Account
    |> Ash.Changeset.for_create(
      :create,
      %{
        org_id: org_id,
        code: code,
        name: name,
        kind: :expense,
        normal_side: :debit
      },
      authorize?: false
    )
    |> Ash.create!()
  end

  defp seed_mapping(org_id, provider, external_code, account) do
    PayrollAccountMapping
    |> Ash.Changeset.for_create(
      :create,
      %{
        org_id: org_id,
        provider: provider,
        external_code: external_code,
        account_id: account.id
      },
      authorize?: false
    )
    |> Ash.create!()
  end

  defp mappings(org_id \\ @org) do
    PayrollAccountMapping
    |> Ash.Query.filter(org_id == ^org_id)
    |> Ash.Query.ensure_selected([:org_id, :provider, :external_code, :account_id])
    |> Ash.Query.load(:account)
    |> Ash.read!(authorize?: false)
  end

  # -- listing ----------------------------------------------------------------

  test "the literal route resolves to the page, and the list is org-scoped with the host account" do
    account = seed_account(@org, "6100", "Payroll expense")
    seed_mapping(@org, "gusto", "SALARY", account)

    other_org = Ash.UUID.generate()
    other_account = seed_account(other_org, "6199", "Other org payroll")
    seed_mapping(other_org, "other-provider", "SECRET", other_account)

    html = render(open())

    assert html =~ ~s(id="erp-payroll-mappings")
    assert html =~ ~s(href="#{@path}?org=#{@org}" class="on")
    assert html =~ "gusto"
    assert html =~ "SALARY"
    assert html =~ "6100"
    assert html =~ "Payroll expense"
    refute html =~ "other-provider"
    refute html =~ "SECRET"

    assert %{
             plug: Phoenix.LiveView.Plug,
             plug_opts: Live,
             route: @path,
             path_params: %{}
           } =
             Phoenix.Router.route_info(
               Samen.WebTest.NavLinksHost.Router,
               "GET",
               @path,
               "localhost"
             )

    # Positive control: an ordinary ERP surface still reaches the generic route.
    assert %{plug_opts: Samen.Web.Erp.SurfaceLive, route: "/erp/:surface"} =
             Phoenix.Router.route_info(
               Samen.WebTest.NavLinksHost.Router,
               "GET",
               "/erp/coa",
               "localhost"
             )
  end

  # -- create -----------------------------------------------------------------

  test "an admin can create a mapping with the org pinned server-side" do
    account = seed_account(@org, "6100", "Payroll expense")

    socket = open()
    assert render(socket) =~ ~s(id="new-payroll-mapping")

    socket = event(socket, "new_mapping", %{})
    assert render(socket) =~ ~s(id="new-payroll-mapping-modal")

    socket =
      event(socket, "save_new", %{
        "form" => %{
          "provider" => "gusto",
          "external_code" => "SALARY",
          "account_id" => account.id
        }
      })

    assert socket.assigns.save_error == nil
    assert socket.assigns.saved

    assert [mapping] = mappings()
    assert mapping.org_id == @org
    assert mapping.provider == "gusto"
    assert mapping.external_code == "SALARY"
    assert mapping.account_id == account.id

    html = render(socket)
    assert html =~ ~s(id="payroll-mappings-saved")
    assert html =~ "gusto"
    assert html =~ "SALARY"
  end

  # -- update -----------------------------------------------------------------

  test "an admin can change the mapped account and provider/code stay identifying facts" do
    first = seed_account(@org, "6100", "Payroll expense")
    second = seed_account(@org, "6110", "Contractor expense")
    mapping = seed_mapping(@org, "gusto", "CONTRACTOR", first)

    socket = open() |> event("edit_mapping", %{"id" => mapping.id})
    html = render(socket)

    assert html =~ ~s(id="edit-payroll-mapping-modal")
    assert html =~ "gusto"
    assert html =~ "CONTRACTOR"
    assert html =~ ~s(id="update-payroll-mapping")

    socket = event(socket, "save_edit", %{"form" => %{"account_id" => second.id}})

    assert socket.assigns.save_error == nil
    assert socket.assigns.saved

    [updated] = mappings()
    assert updated.id == mapping.id
    assert updated.provider == "gusto"
    assert updated.external_code == "CONTRACTOR"
    assert updated.account_id == second.id

    assert render(socket) =~ "6110"
  end

  # -- same-org enforcement ---------------------------------------------------

  test "a cross-org account is refused on create and the mapping is not persisted" do
    seed_account(@org, "6100", "Payroll expense")
    foreign_account = seed_account(Ash.UUID.generate(), "6199", "Foreign payroll")

    socket = open()
    refute render(socket) =~ foreign_account.id

    socket = event(socket, "new_mapping", %{})

    socket =
      event(socket, "save_new", %{
        "form" => %{
          "provider" => "gusto",
          "external_code" => "SALARY",
          "account_id" => foreign_account.id
        }
      })

    assert mappings() == []
    assert socket.assigns.save_error =~ "same-org"
    assert render(socket) =~ "same-org"
  end

  test "a cross-org account is refused on update, leaving the original mapping intact" do
    original_account = seed_account(@org, "6100", "Payroll expense")
    foreign_account = seed_account(Ash.UUID.generate(), "6199", "Foreign payroll")
    mapping = seed_mapping(@org, "gusto", "SALARY", original_account)

    socket = open() |> event("edit_mapping", %{"id" => mapping.id})

    socket =
      event(socket, "save_edit", %{"form" => %{"account_id" => foreign_account.id}})

    assert socket.assigns.save_error =~ "same-org"

    [unchanged] = mappings()
    assert unchanged.id == mapping.id
    assert unchanged.account_id == original_account.id
    assert render(socket) =~ "same-org"
  end

  # -- authorization ----------------------------------------------------------

  test "an armed member sees the mappings read-only; crafted writes and the kernel both refuse" do
    account = seed_account(@org, "6100", "Payroll expense")
    mapping = seed_mapping(@org, "gusto", "SALARY", account)

    # `:required` is the armed tenant gate; with no resolvable membership the
    # admin scope correctly fails closed to `:member`.
    mount = %{build_mount(:erp) | labels: %{authn: :required}}

    socket =
      %Phoenix.LiveView.Socket{}
      |> Phoenix.Component.assign(:samen_mount, mount)
      |> Phoenix.Component.assign(:samen_acting_as, false)
      |> Phoenix.Component.assign(:return_to, nil)
      |> Phoenix.Component.assign(:org_id, @org)
      |> Live.load()

    html = render(socket)

    assert html =~ "gusto"
    assert html =~ "SALARY"
    refute html =~ ~s(id="new-payroll-mapping")
    refute html =~ ~s(id="edit-payroll-mapping-#{mapping.id}")
    assert html =~ "Only an organization admin can change payroll mappings."

    socket =
      event(socket, "save_new", %{
        "form" => %{
          "provider" => "crafted",
          "external_code" => "CRAFTED",
          "account_id" => account.id
        }
      })

    assert socket.assigns.save_error == "Only an organization admin can change payroll mappings."
    assert [only] = mappings()
    assert only.id == mapping.id

    # ENFORCEMENT is the kernel's, not the page's: the same write with the
    # member scope is forbidden by the resource's RoleAtLeast(:admin) policy.
    scope = TenantRole.authenticated_scope(mount, @org)

    assert {:error, %Ash.Error.Forbidden{}} =
             PayrollAccountMapping
             |> Ash.Changeset.for_create(
               :create,
               %{
                 org_id: @org,
                 provider: "gusto",
                 external_code: "BONUS",
                 account_id: account.id
               },
               scope: scope
             )
             |> Ash.create()

    assert length(mappings()) == 1
  end

  test "the operator plane carries no write affordance" do
    account = seed_account(@org, "6100", "Payroll expense")
    seed_mapping(@org, "gusto", "SALARY", account)

    mount = build_mount(:erp, plane: :operator, target_org_id: @org)
    session = mount_session(mount)
    params = %{"org" => @org}

    {:ok, socket} = Live.mount(params, session, %Phoenix.LiveView.Socket{})

    {:noreply, socket} =
      Live.handle_params(params, "http://localhost#{@path}", socket)

    html = render(socket)

    assert html =~ "gusto"
    refute html =~ ~s(id="new-payroll-mapping")
    assert html =~ "Read-only on this plane."
  end
end
