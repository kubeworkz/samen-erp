defmodule Samen.Web.ErpJournalApprovalTest do
  @moduledoc """
  The journal-approval admin settings surface (`/erp/journal-approval`) over the
  REAL `Samen.WebTest.Erp.JournalApprovalPolicy` resource:

    * the page renders the current control (enabled/disabled + threshold) inside
      the ERP shell, with its own nav item active;
    * an admin can disable the control and set a threshold (the existing row is
      UPDATED, never deleted);
    * an org with no row gets CREATE through the same form, org-pinned
      server-side;
    * a negative threshold is refused inline and persists nothing;
    * an armed, non-admin member sees the control read-only and a crafted save
      event writes nothing;
    * the operator plane carries no form at all.
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.Web.Erp.JournalApprovalLive

  @org "55555555-6666-7777-8888-999999999999"
  @approval_resource Samen.WebTest.Approvals.Approval
  @repo Samen.WebTest.Repo

  # -- harness ----------------------------------------------------------------

  defp open(params \\ %{"org" => @org}) do
    mount = build_mount(:erp)
    session = mount_session(mount)
    {:ok, socket} = JournalApprovalLive.mount(params, session, %Phoenix.LiveView.Socket{})

    {:noreply, socket} =
      JournalApprovalLive.handle_params(params, "http://localhost/erp/journal-approval", socket)

    socket
  end

  defp event(socket, name, params) do
    {:noreply, socket} = JournalApprovalLive.handle_event(name, params, socket)
    socket
  end

  defp render(socket), do: render_html(JournalApprovalLive, socket.assigns)

  # -- seeds ------------------------------------------------------------------

  defp seed_policy(attrs \\ %{}) do
    Samen.WebTest.Erp.JournalApprovalPolicy
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(%{org_id: @org, enabled: true, threshold_cents: 0}, attrs),
      authorize?: false
    )
    |> Ash.create!()
  end

  defp policies do
    Samen.WebTest.Erp.JournalApprovalPolicy
    |> Ash.Query.ensure_selected([
      :org_id,
      :enabled,
      :threshold_cents,
      :account_ids,
      :period_keys,
      :steps
    ])
    |> Ash.read!(authorize?: false)
  end

  defp only_policy, do: policies() |> List.first()

  defp approve_policy_change!(socket, approver \\ "policy-approver:#{@org}") do
    kind = Atom.to_string(Samen.WebTest.Erp.JournalApprovalPolicy) <> ":update"

    {:ok, [approval | _]} =
      Samen.Approvals.list_pending(@org, kind,
        approval_resource: @approval_resource,
        repo: @repo
      )

    {:ok, _decided, _meta} =
      Samen.Approvals.approve(approval.id, approver,
        approval_resource: @approval_resource,
        repo: @repo
      )

    socket
    |> Phoenix.Component.assign(:saved, true)
    |> JournalApprovalLive.load()
  end

  # -- read -------------------------------------------------------------------

  test "renders the org's current policy inside the ERP shell with its nav item active" do
    seed_policy(%{threshold_cents: 12_500})
    html = render(open())

    assert html =~ ~s(id="erp-journal-approval")
    assert html =~ ~s(class="app")
    assert html =~ ~s(href="/erp/journal-approval?org=#{@org}" class="on")
    assert html =~ "Journal approval"
    assert html =~ "Enabled"
    assert html =~ "12500 cents ($125.00)"
    assert html =~ "All accounts"
    assert html =~ "All periods"
    assert html =~ "Scoped accounts (optional)"
    assert html =~ "Approver steps (optional JSON)"
    assert html =~ "Single distinct approver"
    assert html =~ ~s(id="journal-approval-form")
  end

  test "an org with no policy renders the honest not-configured state and a create form" do
    assert policies() == []
    html = render(open())

    assert html =~ "Not configured"
    assert html =~ "not set"
    assert html =~ ~s(id="journal-approval-form")
  end

  # -- update -----------------------------------------------------------------

  test "an admin requests a policy change and a distinct admin approves it" do
    seed_policy()
    socket = open()

    socket =
      event(socket, "save", %{
        "form" => %{"enabled" => "false", "threshold_cents" => "25000"}
      })

    assert only_policy().enabled
    socket = approve_policy_change!(socket)

    policy = only_policy()
    refute policy.enabled
    assert policy.threshold_cents == 25_000

    html = render(socket)
    assert html =~ "Disabled"
    assert html =~ "25000 cents ($250.00)"
    assert html =~ ~s(id="policy-saved")
    refute html =~ ~s(id="policy-error")
  end

  # -- create -----------------------------------------------------------------

  test "saving a threshold-only change preserves the configured approver chain" do
    steps = [%{"approver_type" => "role", "approver" => "admin"}]
    seed_policy(%{steps: steps})
    socket = open()

    socket =
      event(socket, "save", %{
        "form" => %{"enabled" => "true", "threshold_cents" => "2500"}
      })

    socket = approve_policy_change!(socket)
    policy = only_policy()
    assert policy.threshold_cents == 2_500
    assert policy.steps == steps

    html = render(socket)
    assert html =~ "1-step chain"
  end

  test "an admin can replace the approver chain through the settings form" do
    seed_policy()
    steps = [%{"approver_type" => "role", "approver" => "admin"}]
    socket = open()

    socket =
      event(socket, "save", %{
        "form" => %{
          "enabled" => "true",
          "threshold_cents" => "0",
          "steps_text" => Jason.encode!(steps)
        }
      })

    socket = approve_policy_change!(socket)
    assert only_policy().steps == steps
    assert render(socket) =~ "1-step chain"
  end

  test "creates the org's policy when none exists, pinned to the resolved org" do
    assert policies() == []
    account_a = Ash.UUID.generate()
    account_b = Ash.UUID.generate()
    steps = [%{"approver_type" => "role", "approver" => "admin"}]
    socket = open()

    socket =
      event(socket, "save", %{
        "form" => %{
          "enabled" => "true",
          "threshold_cents" => "50000",
          "account_ids" => "#{account_a}, #{account_b}",
          "period_keys" => "2026-11, 2026-12",
          "steps_text" => Jason.encode!(steps)
        }
      })

    assert [policy] = policies()
    assert policy.org_id == @org
    assert policy.enabled
    assert policy.threshold_cents == 50_000
    assert policy.account_ids == [account_a, account_b]
    assert policy.period_keys == ["2026-11", "2026-12"]
    assert policy.steps == steps

    html = render(socket)
    assert html =~ "Enabled"
    assert html =~ "50000 cents ($500.00)"
    assert html =~ "2 scoped"
  end

  # -- kernel validation ------------------------------------------------------

  test "a negative threshold is refused inline and persists nothing" do
    seed_policy()
    socket = open()

    socket =
      event(socket, "save", %{
        "form" => %{"enabled" => "false", "threshold_cents" => "-1"}
      })

    html = render(socket)
    assert html =~ "field-invalid"

    policy = only_policy()
    assert policy.enabled
    assert policy.threshold_cents == 0
  end

  # -- authorization ----------------------------------------------------------

  test "an armed member sees the control read-only and a crafted save writes nothing" do
    seed_policy()

    # `:required` is the armed tenant gate; with no resolvable membership the
    # admin scope correctly fails closed to `:member`.
    mount = %{build_mount(:erp) | labels: %{authn: :required}}

    socket =
      %Phoenix.LiveView.Socket{}
      |> Phoenix.Component.assign(:samen_mount, mount)
      |> Phoenix.Component.assign(:org_id, @org)
      |> Phoenix.Component.assign(:samen_acting_as, false)
      |> Phoenix.Component.assign(:return_to, nil)
      |> JournalApprovalLive.load()

    html = render(socket)
    refute html =~ ~s(id="journal-approval-form")
    assert html =~ "Only an organization admin can change this control."

    socket =
      event(socket, "save", %{
        "form" => %{"enabled" => "false", "threshold_cents" => "1"}
      })

    policy = only_policy()
    assert policy.enabled
    assert policy.threshold_cents == 0
    assert render(socket) =~ "Only an organization admin can change the journal approval policy."
  end

  test "the operator plane carries no write affordance" do
    seed_policy()

    mount = build_mount(:erp, plane: :operator, target_org_id: @org)
    session = mount_session(mount)
    params = %{"org" => @org}

    {:ok, socket} = JournalApprovalLive.mount(params, session, %Phoenix.LiveView.Socket{})

    {:noreply, socket} =
      JournalApprovalLive.handle_params(params, "http://localhost/erp/journal-approval", socket)

    html = render(socket)
    refute html =~ ~s(id="journal-approval-form")
    assert html =~ "Read-only on this plane."
  end
end
