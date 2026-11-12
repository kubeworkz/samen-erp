defmodule Samen.Web.ErpApApprovalTest do
  @moduledoc """
  The AP approval-chain settings surface (`/erp/ap-approval`) over the REAL
  `Samen.WebTest.Erp.ApprovalPolicy` resource:

    * the page renders the current threshold, auto-approval flag and ordered
      named-user/role chain inside the ERP shell;
    * an admin can create the policy when the org has none;
    * an admin can reorder/update the chain only through a distinct admin's
      approval;
    * account and period scopes are editable and persisted;
    * named-user steps use a searchable org-member picker (handle search,
      non-PII) instead of a raw principal-id field;
    * a role outside the supported set is refused inline and persists nothing;
    * an armed member sees the policy read-only and a crafted save writes
      nothing;
    * the operator plane carries no form.
  """

  use Samen.WebTest.DataCase, async: false

  alias Samen.Web.Erp.ApApprovalLive
  alias Samen.WebTest.Erp.ApprovalPolicy
  alias Samen.WebTest.Operator.{Membership, User}

  @org "55555555-6666-7777-8888-999999999999"
  @other_org "66666666-7777-8888-9999-000000000000"
  @kind "ap_invoice:approve"
  @approval_resource Samen.WebTest.Approvals.Approval
  @repo Samen.WebTest.Repo

  # -- harness ----------------------------------------------------------------

  defp open(params \\ %{"org" => @org}) do
    mount = build_mount(:erp)
    session = mount_session(mount)
    {:ok, socket} = ApApprovalLive.mount(params, session, %Phoenix.LiveView.Socket{})

    {:noreply, socket} =
      ApApprovalLive.handle_params(params, "http://localhost/erp/ap-approval", socket)

    socket
  end

  defp event(socket, name, params) do
    {:noreply, socket} = ApApprovalLive.handle_event(name, params, socket)
    socket
  end

  defp render(socket), do: render_html(ApApprovalLive, socket.assigns)

  defp steps_params(steps) do
    steps
    |> Enum.with_index()
    |> Map.new(fn {step, index} -> {Integer.to_string(index), step} end)
  end

  # A create form with one named-user step, ready for the member picker.
  defp open_user_step do
    socket = open()
    socket = event(socket, "add_step", %{})

    event(socket, "validate", %{
      "form" => %{
        "threshold_cents" => "0",
        "auto_approve_below" => "false",
        "steps" => %{"0" => %{"approver_type" => "user", "approver" => "admin"}}
      }
    })
  end

  defp set_step_role(socket, role) do
    event(socket, "validate", %{
      "form" => %{
        "threshold_cents" => "0",
        "auto_approve_below" => "false",
        "steps" => %{
          "0" => %{"approver_type" => "user", "approver" => "", "role" => role}
        }
      }
    })
  end

  # -- seeds ------------------------------------------------------------------

  # A real Identity User + active Membership in the identity sibling mount the
  # ERP test mount names through `:identity_namespace`.
  defp seed_member(handle, role, org \\ @org, status \\ "active") do
    user =
      User
      |> Ash.Changeset.for_create(:create, %{org_id: org, handle: handle, status: status})
      |> Ash.create!(authorize?: false)

    Membership
    |> Ash.Changeset.for_create(:create, %{
      org_id: org,
      user_id: user.id,
      role: role,
      status: status
    })
    |> Ash.create!(authorize?: false)

    user
  end

  defp seed_policy(attrs) do
    ApprovalPolicy
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(
        %{
          org_id: @org,
          kind: @kind,
          threshold_cents: 0,
          auto_approve_below: false,
          steps: []
        },
        attrs
      ),
      authorize?: false
    )
    |> Ash.create!()
  end

  defp policies do
    ApprovalPolicy
    |> Ash.Query.ensure_selected([
      :org_id,
      :kind,
      :threshold_cents,
      :auto_approve_below,
      :steps,
      :account_ids,
      :period_keys
    ])
    |> Ash.read!(authorize?: false)
  end

  defp only_policy, do: policies() |> List.first()

  defp approve_policy_change!(socket, approver \\ "policy-approver:#{@org}") do
    kind = Atom.to_string(ApprovalPolicy) <> ":update"

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
    |> ApApprovalLive.load()
  end

  # -- read -------------------------------------------------------------------

  test "renders the current threshold, scopes, auto-approval flag and chain in the ERP shell" do
    dana = seed_member("dana", :member)
    scoped_account = Ash.UUID.generate()

    seed_policy(%{
      threshold_cents: 12_500,
      auto_approve_below: true,
      account_ids: [scoped_account],
      period_keys: ["2026-11"],
      steps: [
        %{"approver_type" => "role", "approver" => "admin"},
        %{"approver_type" => "user", "approver" => dana.id}
      ]
    })

    html = render(open())

    assert html =~ ~s(id="erp-ap-approval")
    assert html =~ ~s(class="app")
    assert html =~ ~s(href="/erp/ap-approval?org=#{@org}" class="on")
    assert html =~ "AP approval"
    assert html =~ "Chain configured"
    assert html =~ "12500 cents ($125.00)"
    assert html =~ "1 scoped"
    assert html =~ "Scoped expense accounts (optional)"
    assert html =~ "Scoped bill periods (optional)"
    assert html =~ scoped_account
    assert html =~ "2026-11"
    assert html =~ "Role · admin"
    assert html =~ "User · dana (member)"
    assert html =~ ~s(id="ap-approval-form")
    assert html =~ ~s(id="save-ap-approval")
    assert html =~ ~s(phx-click="save")
    refute html =~ "User id (principal id)"
  end

  test "an org with no policy renders the honest not-configured state and a create form" do
    assert policies() == []
    html = render(open())

    assert html =~ "Not configured"
    assert html =~ "single decision — no chain steps"
    assert html =~ ~s(id="ap-approval-form")
    assert html =~ ~s(id="ap-approval-no-steps")
  end

  # -- create -----------------------------------------------------------------

  test "creates the org's AP policy with ordered steps and scopes" do
    riley = seed_member("riley", :member)
    riley_id = riley.id
    scoped_account = Ash.UUID.generate()

    assert policies() == []
    socket = open()
    socket = event(socket, "add_step", %{})
    assert [%{"approver_type" => "role", "approver" => "admin"}] = socket.assigns.step_values

    socket =
      event(socket, "save", %{
        "form" => %{
          "threshold_cents" => "50000",
          "auto_approve_below" => "true",
          "account_ids" => scoped_account,
          "period_keys" => "2026-11, 2026-12",
          "steps" => %{
            "0" => %{"approver_type" => "role", "approver" => "admin"},
            "1" => %{"approver_type" => "user", "approver" => riley.id}
          }
        }
      })

    assert socket.assigns.save_error == nil
    assert socket.assigns.saved

    assert [policy] = policies()
    assert policy.org_id == @org
    assert policy.kind == @kind
    assert policy.threshold_cents == 50_000
    assert policy.auto_approve_below
    assert policy.account_ids == [scoped_account]
    assert policy.period_keys == ["2026-11", "2026-12"]

    assert [
             %{"approver_type" => "role", "approver" => "admin"},
             %{"approver_type" => "user", "approver" => ^riley_id}
           ] = policy.steps

    html = render(socket)
    assert html =~ ~s(id="ap-approval-saved")
    assert html =~ "Chain configured"
    assert html =~ "Step 1: Role · admin"
    assert html =~ "Step 2: User · riley (member)"
  end

  # -- update / ordering ------------------------------------------------------

  test "an admin can reorder the chain and update the threshold" do
    nadia = seed_member("nadia", :member)
    nadia_id = nadia.id

    seed_policy(%{
      threshold_cents: 1_000,
      steps: [
        %{"approver_type" => "role", "approver" => "admin"},
        %{"approver_type" => "user", "approver" => nadia.id}
      ]
    })

    socket = open()
    socket = event(socket, "move_step", %{"index" => "0", "direction" => "down"})

    assert Enum.map(socket.assigns.step_values, & &1["approver_type"]) == ["user", "role"]

    socket =
      event(socket, "save", %{
        "form" => %{
          "threshold_cents" => "2500",
          "auto_approve_below" => "false",
          "steps" => steps_params(socket.assigns.step_values)
        }
      })

    # The save is only a request; the live policy is unchanged until a distinct
    # admin approves it.
    assert only_policy().threshold_cents == 1_000
    socket = approve_policy_change!(socket)

    assert socket.assigns.save_error == nil
    policy = only_policy()
    assert policy.threshold_cents == 2_500
    refute policy.auto_approve_below

    assert [
             %{"approver_type" => "user", "approver" => ^nadia_id},
             %{"approver_type" => "role", "approver" => "admin"}
           ] = policy.steps

    html = render(socket)
    assert html =~ "Step 1: User · nadia (member)"
    assert html =~ "Step 2: Role · admin"
  end

  test "a submitted update is explicitly pending a distinct admin's approval" do
    seed_policy(%{threshold_cents: 1_000})
    socket = open()

    socket =
      event(socket, "save", %{
        "form" => %{
          "threshold_cents" => "5000",
          "auto_approve_below" => "false",
          "steps" => %{}
        }
      })

    assert socket.assigns.approval_pending
    assert socket.assigns.save_error == nil

    html = render(socket)
    assert html =~ ~s(id="ap-approval-pending")
    assert html =~ "Pending a distinct admin's approval."
    assert html =~ "current policy remains in effect"
    assert only_policy().threshold_cents == 1_000

    socket = approve_policy_change!(socket)

    refute socket.assigns.approval_pending
    refute render(socket) =~ ~s(id="ap-approval-pending")
    assert only_policy().threshold_cents == 5_000
  end

  test "removing every step returns the policy to the single-decision Gate" do
    seed_policy(%{
      steps: [%{"approver_type" => "role", "approver" => "admin"}]
    })

    socket = open()
    socket = event(socket, "remove_step", %{"index" => "0"})
    assert socket.assigns.step_values == []

    socket =
      event(socket, "save", %{
        "form" => %{
          "threshold_cents" => "0",
          "auto_approve_below" => "false",
          "steps" => %{}
        }
      })

    assert only_policy().steps == [%{"approver_type" => "role", "approver" => "admin"}]
    socket = approve_policy_change!(socket)

    assert socket.assigns.save_error == nil
    assert only_policy().steps == []
    assert render(socket) =~ "single decision — no chain steps"
  end

  # -- member picker ----------------------------------------------------------

  test "named-user steps search active org members by handle instead of a raw id field" do
    dana = seed_member("dana", :member)
    seed_member("dana-elsewhere", :admin, @other_org)

    socket = open_user_step()

    assert [%{"approver_type" => "user", "approver" => ""}] = socket.assigns.step_values

    html = render(socket)
    refute html =~ "User id (principal id)"
    assert html =~ ~s(phx-change="search_members")
    assert html =~ "Search organization members by handle"

    socket = event(socket, "search_members", %{"index" => "0", "query" => "dan"})

    assert [%{id: dana_id, handle: "dana", role: :member}] =
             socket.assigns.member_results[0]

    assert dana_id == dana.id
    assert socket.assigns.member_highlights[0] == 0

    html = render(socket)
    assert html =~ ~s(id="approval-step-0-results")
    assert html =~ ~s(phx-click="pick_member")
    assert html =~ ~s(phx-keydown="member_keydown")
    assert html =~ ~s(role="combobox")
    assert html =~ ~s(aria-activedescendant="approval-step-0-option-0")
    assert html =~ ~s(aria-selected="true")
    assert html =~ "↑/↓ to navigate"

    socket =
      event(socket, "pick_member", %{
        "index" => "0",
        "id" => dana.id,
        "handle" => "dana",
        "role" => "member"
      })

    assert [%{"approver_type" => "user", "approver" => approver}] = socket.assigns.step_values
    assert approver == dana.id

    html = render(socket)
    assert html =~ ~s(id="approval-step-0-member")
    assert html =~ "dana (member)"
    assert html =~ ~s(value="#{dana.id}")
    refute html =~ ~s(phx-change="search_members")

    socket =
      event(socket, "save", %{
        "form" => %{
          "threshold_cents" => "1000",
          "auto_approve_below" => "false",
          "steps" => steps_params(socket.assigns.step_values)
        }
      })

    assert socket.assigns.save_error == nil
    assert [%{"approver_type" => "user", "approver" => approver}] = only_policy().steps
    assert approver == dana.id
  end

  test "arrow keys move the highlighted member and Enter selects it" do
    seed_member("dana", :member)
    daniel = seed_member("daniel", :member)

    socket = open_user_step()
    socket = event(socket, "search_members", %{"index" => "0", "query" => "dan"})

    assert Enum.map(socket.assigns.member_results[0], & &1.handle) == ["dana", "daniel"]
    assert socket.assigns.member_highlights[0] == 0

    socket = event(socket, "member_keydown", %{"index" => "0", "key" => "ArrowDown"})
    assert socket.assigns.member_highlights[0] == 1

    html = render(socket)
    assert html =~ ~s(aria-activedescendant="approval-step-0-option-1")
    assert html =~ ~s(id="approval-step-0-option-1")
    assert html =~ ~s(aria-selected="true")

    socket = event(socket, "member_keydown", %{"index" => "0", "key" => "ArrowUp"})
    assert socket.assigns.member_highlights[0] == 0

    socket = event(socket, "member_keydown", %{"index" => "0", "key" => "ArrowDown"})
    socket = event(socket, "member_keydown", %{"index" => "0", "key" => "Enter"})

    assert [%{"approver_type" => "user", "approver" => approver}] = socket.assigns.step_values
    assert approver == daniel.id
    assert socket.assigns.member_results[0] == nil
    assert socket.assigns.member_highlights[0] == nil

    assert render(socket) =~ "daniel (member)"
  end

  test "Escape clears the member search and closes the results" do
    seed_member("dana", :member)

    socket = open_user_step()
    socket = event(socket, "search_members", %{"index" => "0", "query" => "dan"})
    assert socket.assigns.member_results[0] != []

    socket = event(socket, "member_keydown", %{"index" => "0", "key" => "Escape"})

    assert socket.assigns.member_queries[0] == nil
    assert socket.assigns.member_results[0] == nil
    assert socket.assigns.member_highlights[0] == nil

    html = render(socket)
    refute html =~ ~s(id="approval-step-0-results")
    assert html =~ ~s(value="")
  end

  test "Enter leaves the step unassigned when no member matches" do
    socket = open_user_step()
    socket = event(socket, "search_members", %{"index" => "0", "query" => "zzz"})
    assert socket.assigns.member_results[0] == []

    socket = event(socket, "member_keydown", %{"index" => "0", "key" => "Enter"})

    assert [%{"approver_type" => "user", "approver" => ""}] = socket.assigns.step_values
  end

  test "the save button persists the form state tracked by validate" do
    socket =
      event(open(), "validate", %{
        "form" => %{
          "threshold_cents" => "7500",
          "auto_approve_below" => "true",
          "steps" => %{}
        }
      })

    socket = event(socket, "save", %{})

    assert socket.assigns.save_error == nil
    assert socket.assigns.saved

    assert [policy] = policies()
    assert policy.threshold_cents == 7_500
    assert policy.auto_approve_below
  end

  test "clearing a selected member returns the step to the search field" do
    dana = seed_member("dana", :member)

    seed_policy(%{
      steps: [%{"approver_type" => "user", "approver" => dana.id}]
    })

    socket = open()
    assert socket.assigns.user_labels[dana.id].handle == "dana"

    socket = event(socket, "clear_member", %{"index" => "0"})

    assert [%{"approver_type" => "user", "approver" => ""}] = socket.assigns.step_values

    html = render(socket)
    assert html =~ ~s(phx-change="search_members")
    refute html =~ ~s(id="approval-step-0-member")
  end

  test "the member picker filters results by the step's role" do
    dana = seed_member("dana", :admin)
    seed_member("daniel", :member)

    socket = open_user_step()
    socket = event(socket, "search_members", %{"index" => "0", "query" => "dan"})

    assert socket.assigns.member_results[0] |> Enum.map(& &1.handle) |> Enum.sort() ==
             ["dana", "daniel"]

    socket = set_step_role(socket, "admin")
    assert [%{"role" => "admin", "approver" => ""}] = socket.assigns.step_values

    socket = event(socket, "search_members", %{"index" => "0", "query" => "dan"})
    assert [%{id: dana_id, handle: "dana", role: :admin}] = socket.assigns.member_results[0]
    assert dana_id == dana.id

    html = render(socket)
    assert html =~ "Search admin members by handle"
    assert html =~ ~s(aria-label="Role filter for step 1")
    assert html =~ "admin only"

    socket =
      event(socket, "pick_member", %{
        "index" => "0",
        "id" => dana.id,
        "handle" => "dana",
        "role" => "admin"
      })

    assert [%{"approver" => approver, "role" => "admin"}] = socket.assigns.step_values
    assert approver == dana.id

    socket = set_step_role(socket, "member")
    assert [%{"role" => "member", "approver" => ""}] = socket.assigns.step_values

    socket = event(socket, "search_members", %{"index" => "0", "query" => "dan"})
    assert [%{handle: "daniel", role: :member}] = socket.assigns.member_results[0]
  end

  test "saves a named-user step's role filter" do
    dana = seed_member("dana", :admin)

    socket = open_user_step()
    socket = set_step_role(socket, "admin")
    socket = event(socket, "search_members", %{"index" => "0", "query" => "dan"})

    socket =
      event(socket, "pick_member", %{
        "index" => "0",
        "id" => dana.id,
        "handle" => "dana",
        "role" => "admin"
      })

    socket =
      event(socket, "save", %{
        "form" => %{
          "threshold_cents" => "1000",
          "auto_approve_below" => "false",
          "steps" => steps_params(socket.assigns.step_values)
        }
      })

    assert socket.assigns.save_error == nil

    assert [
             %{
               "approver_type" => "user",
               "approver" => approver,
               "role" => "admin"
             }
           ] = only_policy().steps

    assert approver == dana.id
    assert render(socket) =~ "Step 1: User · dana (admin) · admin only"
  end

  # -- kernel validation ------------------------------------------------------

  test "a scoped update waits for a distinct admin and then applies the scope" do
    seed_policy(%{threshold_cents: 1_000})
    scoped_account = Ash.UUID.generate()
    socket = open()

    socket =
      event(socket, "save", %{
        "form" => %{
          "threshold_cents" => "5000",
          "auto_approve_below" => "false",
          "account_ids" => scoped_account,
          "period_keys" => "2026-11, 2026-12",
          "steps" => %{}
        }
      })

    unchanged = only_policy()
    assert unchanged.threshold_cents == 1_000
    assert unchanged.account_ids == []
    assert unchanged.period_keys == []
    refute socket.assigns.saved

    socket = approve_policy_change!(socket)
    policy = only_policy()
    assert policy.threshold_cents == 5_000
    assert policy.account_ids == [scoped_account]
    assert policy.period_keys == ["2026-11", "2026-12"]
    assert render(socket) =~ "1 scoped"
  end

  test "an invalid period is refused inline and opens no approval" do
    seed_policy(%{threshold_cents: 1_000})

    socket =
      event(open(), "save", %{
        "form" => %{
          "threshold_cents" => "5000",
          "auto_approve_below" => "false",
          "period_keys" => "2026-13",
          "steps" => %{}
        }
      })

    assert render(socket) =~ "period keys must be YYYY-MM"
    assert only_policy().threshold_cents == 1_000

    kind = Atom.to_string(ApprovalPolicy) <> ":update"

    assert {:ok, []} =
             Samen.Approvals.list_pending(@org, kind,
               approval_resource: @approval_resource,
               repo: @repo
             )
  end

  test "an unsupported role is refused inline and persists nothing" do
    seed_policy(%{
      steps: [%{"approver_type" => "role", "approver" => "admin"}]
    })

    socket =
      event(open(), "save", %{
        "form" => %{
          "threshold_cents" => "1000",
          "auto_approve_below" => "false",
          "steps" => %{
            "0" => %{"approver_type" => "role", "approver" => "owner"}
          }
        }
      })

    html = render(socket)
    assert html =~ "unknown role"

    policy = only_policy()
    assert policy.threshold_cents == 0
    assert policy.steps == [%{"approver_type" => "role", "approver" => "admin"}]
  end

  # -- authorization ----------------------------------------------------------

  test "an armed member sees the policy read-only and a crafted save writes nothing" do
    seed_policy(%{
      threshold_cents: 1_000,
      steps: [%{"approver_type" => "role", "approver" => "admin"}]
    })

    mount = %{build_mount(:erp) | labels: %{authn: :required}}

    socket =
      %Phoenix.LiveView.Socket{}
      |> Phoenix.Component.assign(:samen_mount, mount)
      |> Phoenix.Component.assign(:org_id, @org)
      |> Phoenix.Component.assign(:samen_acting_as, false)
      |> Phoenix.Component.assign(:return_to, nil)
      |> ApApprovalLive.load()

    html = render(socket)
    refute html =~ ~s(id="ap-approval-form")
    assert html =~ "Only an organization admin can change this policy."

    socket =
      event(socket, "save", %{
        "form" => %{
          "threshold_cents" => "1",
          "auto_approve_below" => "true",
          "steps" => %{
            "0" => %{"approver_type" => "role", "approver" => "member"}
          }
        }
      })

    policy = only_policy()
    assert policy.threshold_cents == 1_000
    refute policy.auto_approve_below
    assert policy.steps == [%{"approver_type" => "role", "approver" => "admin"}]

    assert render(socket) =~
             "Only an organization admin can change the AP approval policy."
  end

  test "the operator plane carries no write affordance" do
    seed_policy(%{steps: [%{"approver_type" => "role", "approver" => "admin"}]})

    mount = build_mount(:erp, plane: :operator, target_org_id: @org)
    session = mount_session(mount)
    params = %{"org" => @org}

    {:ok, socket} = ApApprovalLive.mount(params, session, %Phoenix.LiveView.Socket{})

    {:noreply, socket} =
      ApApprovalLive.handle_params(params, "http://localhost/erp/ap-approval", socket)

    html = render(socket)
    refute html =~ ~s(id="ap-approval-form")
    assert html =~ "Read-only on this plane."
  end
end
