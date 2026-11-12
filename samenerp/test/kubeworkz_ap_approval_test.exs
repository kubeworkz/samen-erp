defmodule Samenerp.KubeworkzApApprovalTest do
  @moduledoc """
  The Kubeworkz host proof for the generic AP approval policy:

    * an admin's policy update is refused with `ApprovalRequired` and opens a
      pending approval;
    * the persisted policy is unchanged while the request is pending;
    * the requester cannot approve their own request;
    * a distinct admin's approval is what applies the new threshold,
      auto-approval flag, account/period scopes, and approver chain.

  This is the host-level companion to the core resource tests and the web
  settings LiveView tests.
  """

  use Samenerp.DataCase, async: false

  alias Samen.Scopes.Finance.ApApproval
  alias Samenerp.Erp
  alias Samenerp.Operator, as: Op

  @approval_opts [
    approval_resource: Samenerp.Approvals.Approval,
    repo: Samenerp.Repo
  ]

  defp create_org!(name) do
    Op.Org
    |> Ash.Changeset.for_create(:create, %{name: name}, authorize?: false)
    |> Ash.create!(authorize?: false)
  end

  defp admin_scope(org_id, prefix \\ "admin") do
    %Samen.Scope{
      actor: %{
        id: "#{prefix}:#{org_id}",
        org_id: org_id,
        role: :admin,
        kind: :tenant,
        plane: :tenant
      }
    }
  end

  defp create_policy!(org_id) do
    Erp.ApprovalPolicy
    |> Ash.Changeset.for_create(
      :create,
      %{
        org_id: org_id,
        kind: ApApproval.policy_kind(),
        threshold_cents: 0,
        auto_approve_below: false,
        steps: [],
        account_ids: [],
        period_keys: []
      },
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end

  defp approval_required!(errors) do
    Enum.find(errors, &match?(%{__struct__: Samen.Approvals.ApprovalRequired}, &1)) ||
      flunk("expected ApprovalRequired, got: #{inspect(errors)}")
  end

  test "an AP policy update is pending until a distinct admin approves it" do
    org = create_org!("Kubeworkz AP Approval Policy")
    org_id = to_string(org.id)
    admin = admin_scope(org_id)
    policy = create_policy!(org_id)

    account_id = Ash.UUID.generate()

    steps = [
      %{"approver_type" => "role", "approver" => "admin"}
    ]

    attrs = %{
      threshold_cents: 75_000,
      auto_approve_below: true,
      account_ids: [account_id],
      period_keys: ["2026-11"],
      steps: steps
    }

    assert {:error, %Ash.Error.Forbidden{errors: errors}} =
             policy
             |> Ash.Changeset.for_update(:update, attrs, scope: admin)
             |> Ash.update()

    approval = approval_required!(errors)
    assert approval.kind == Atom.to_string(Erp.ApprovalPolicy) <> ":update"
    assert is_binary(approval.approval_id)

    assert {:ok, pending} = Samen.Approvals.get(approval.approval_id, @approval_opts)
    assert pending.state == :pending
    assert pending.requested_by == "admin:#{org_id}"
    assert pending.reason == "an AP approval policy change requires a distinct admin"
    assert pending.steps == []

    unchanged = Ash.get!(Erp.ApprovalPolicy, policy.id, authorize?: false)
    assert unchanged.threshold_cents == 0
    refute unchanged.auto_approve_below
    assert unchanged.account_ids == []
    assert unchanged.period_keys == []
    assert unchanged.steps == []

    assert {:error, :self_approval} =
             Samen.Approvals.approve(approval.approval_id, "admin:#{org_id}", @approval_opts)

    still_unchanged = Ash.get!(Erp.ApprovalPolicy, policy.id, authorize?: false)
    assert still_unchanged.threshold_cents == 0
    assert still_unchanged.account_ids == []

    assert {:ok, _decided, _meta} =
             Samen.Approvals.approve(
               approval.approval_id,
               "admin2:#{org_id}",
               @approval_opts
             )

    updated = Ash.get!(Erp.ApprovalPolicy, policy.id, authorize?: false)
    assert updated.threshold_cents == 75_000
    assert updated.auto_approve_below
    assert updated.account_ids == [account_id]
    assert updated.period_keys == ["2026-11"]
    assert updated.steps == steps
  end
end
