defmodule Samen.Web.OrgProvisioningTest do
  @moduledoc """
  WS-Notes Phase 6, unit 1c — the framework's ORG-PROVISIONING seam
  (`Samen.Web.OrgProvisioning`): a host's per-org setup runs when a tenant org is CREATED.

  The motivating state is per-ORG REGISTRY state, not tenant content: the Pages search index is
  fail-closed without it, so an unregistered org's `/pages?q=` is indistinguishable from "nothing
  matches". Unit 1c makes creation the moment it gets written — and this file pins the seam's
  own contract, independent of any one hook:

    1. **Unwired = no-op.** A host that configures nothing is not "provisioned by accident".
    2. **Called with the org id LAST** (the house `{mod, fun, args}` shape), on the REAL creation
       path — the operator plane's New-account write, which creates a tenant org.
    3. **Every failure is collected, logged and returned** — a `{:error, reason}`, a RAISE, an
       unexpected return value, and a malformed config entry are all reported; none of them is
       read as success, and none of them is allowed to escape as an exception (the account is
       already committed, so the seam must not turn a registry hiccup into "signup failed").

  The other creation path (self-serve `POST /signup`) is proven end-to-end in the host that wires
  the hook: `samenerp/test/notes_org_provisioning_test.exs`.
  """

  use Samen.WebTest.DataCase, async: false

  import ExUnit.CaptureLog

  require Ash.Query

  alias Samen.Web.Operator.AccountsLive
  alias Samen.Web.OrgProvisioning
  alias Samen.WebTest.Operator, as: Op

  @probe :org_provisioning_probe

  defmodule Hook do
    @moduledoc """
    A test-only provisioning hook. Every variant reports the org id it was handed to the
    registered probe process FIRST, so a failure assertion can never pass by the hook not
    running at all.
    """
    @probe :org_provisioning_probe

    def record(org_id) do
      notify(org_id)
      :ok
    end

    def ok_tuple(org_id) do
      notify(org_id)
      {:ok, :provisioned}
    end

    def fail(org_id) do
      notify(org_id)
      {:error, :registry_down}
    end

    def raise_it(org_id) do
      notify(org_id)
      raise "provisioning exploded"
    end

    def stray(org_id) do
      notify(org_id)
      :not_an_outcome
    end

    defp notify(org_id) do
      if pid = Process.whereis(@probe), do: send(pid, {:provisioned, org_id})
      :ok
    end
  end

  setup do
    previous = Application.get_env(:samen_web, :org_provisioning)
    Process.register(self(), @probe)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:samen_web, :org_provisioning)
        hooks -> Application.put_env(:samen_web, :org_provisioning, hooks)
      end
    end)

    :ok
  end

  defp configure(hooks), do: Application.put_env(:samen_web, :org_provisioning, hooks)

  defp mount, do: build_operator_mount(Ash.UUID.generate())

  # ---------------------------------------------------------------------------
  # 1. unwired = no-op (and the resolution path it depends on)
  # ---------------------------------------------------------------------------

  test "an UNWIRED host provisions nothing — and the mount resolves the app the hooks would come from" do
    refute OrgProvisioning.configured?(:samen_web)
    assert OrgProvisioning.hooks(:samen_web) == []
    assert :ok = OrgProvisioning.run(mount(), Ash.UUID.generate())
    refute_received {:provisioned, _}

    # The seam reads the hook list from `Mount.otp_app/1`; a nil resolution would silently
    # no-op every host, which is the failure unit 1c exists to remove.
    assert Samen.Web.Mount.otp_app(mount()) == :samen_web
  end

  # ---------------------------------------------------------------------------
  # 2. the real creation path (operator plane)
  # ---------------------------------------------------------------------------

  test "the operator New-account write provisions the tenant org it just created" do
    configure([{Hook, :record, []}])

    op = seed_operator_org!()
    socket = mount_socket(build_operator_mount(op.id))

    socket =
      event(socket, "save_new", %{
        "form" => %{"name" => "Provisioned Freight Co", "plan" => "growth"}
      })

    refute socket.assigns.show_new

    created =
      Op.Org
      |> Ash.Query.filter(name == "Provisioned Freight Co")
      |> Ash.read_one!(authorize?: false)

    assert_received {:provisioned, org_id}

    assert org_id == created.id,
           "the seam ran, but not for the org this write created"

    # Positive control: the hook is the only reason the message exists — an INVALID submit
    # creates nothing, so it must provision nothing.
    socket = event(socket, "new_account", %{})
    socket = event(socket, "save_new", %{"form" => %{"name" => "", "plan" => "growth"}})
    assert socket.assigns.show_new
    refute_received {:provisioned, _}
  end

  # ---------------------------------------------------------------------------
  # 3. fail-honest: every failure is collected + logged, never raised
  # ---------------------------------------------------------------------------

  test "a hook returning {:error, _}, raising, or returning an unexpected value is REPORTED, not raised" do
    configure([{Hook, :fail, []}, {Hook, :raise_it, []}, {Hook, :stray, []}])
    org_id = Ash.UUID.generate()

    log =
      capture_log(fn ->
        assert {:error, failures} = OrgProvisioning.run(mount(), org_id)

        assert Enum.map(failures, fn {mod, fun, _reason} -> {mod, fun} end) == [
                 {Hook, :fail},
                 {Hook, :raise_it},
                 {Hook, :stray}
               ]

        # The unexpected return is named as such — a hook that did not return `:ok` has not
        # reported success, so it must not be counted as one.
        assert {Hook, :stray, {:unexpected_return, :not_an_outcome}} = List.last(failures)
      end)

    # ...and the loud half: every failure names the hook it came from, with the org.
    assert log =~ "OrgProvisioningTest.Hook.fail/1"
    assert log =~ "OrgProvisioningTest.Hook.raise_it/1"
    assert log =~ "OrgProvisioningTest.Hook.stray/1"
    assert log =~ org_id
    assert log =~ "registry_down"

    # All three RAN (so the failure list is not "the same one three times").
    assert_received {:provisioned, ^org_id}
    assert_received {:provisioned, ^org_id}
    assert_received {:provisioned, ^org_id}
  end

  test "`{:ok, _}` counts as success; a MALFORMED config entry is reported instead of ignored" do
    configure([{Hook, :ok_tuple, []}])
    assert :ok = OrgProvisioning.run(mount(), Ash.UUID.generate())
    assert_received {:provisioned, _}

    configure([:not_a_hook, {:nope}])

    log = capture_log(fn -> assert :ok = OrgProvisioning.run(mount(), Ash.UUID.generate()) end)

    assert log =~ "malformed hooks",
           "a config entry that can never run was dropped silently — a hook that never ran is " <>
             "not a hook that passed"
  end

  # -- harness -----------------------------------------------------------------

  defp seed_operator_org! do
    org =
      Op.Org
      |> Ash.Changeset.for_create(:create, %{name: "Samen SaaS, Inc.", plan: "operator"},
        authorize?: false
      )
      |> Ash.create!()

    org
    |> Ash.Changeset.for_update(:update, %{org_id: org.id}, authorize?: false)
    |> Ash.update!()
  end

  defp mount_socket(mount) do
    %Phoenix.LiveView.Socket{}
    |> Phoenix.Component.assign(:samen_mount, mount)
    |> Phoenix.Component.assign(:samen_acting_as, false)
    |> AccountsLive.load()
  end

  defp event(socket, name, params) do
    {:noreply, socket} = AccountsLive.handle_event(name, params, socket)
    socket
  end
end
