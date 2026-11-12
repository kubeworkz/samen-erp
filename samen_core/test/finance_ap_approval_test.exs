defmodule Samen.FinanceApApprovalTest do
  @moduledoc """
  AP amount routing and sequential approval chains.

  A policy may auto-approve strictly below its threshold when explicitly enabled.
  Otherwise the Gate opens an approval whose `steps` are the policy's ordered
  named-user/role chain; intermediate decisions do not execute the bill posting.
  """

  use ExUnit.Case, async: false

  require Ash.Query

  alias SamenCore.Support.FinanceFixture.{
    Account,
    ApInvoice,
    ApprovalPolicy,
    JournalEntry,
    PostingAccount
  }

  @repo SamenCore.TestRepo
  @approval_resource SamenCore.Support.ApprovalsFixture.Approval
  @policy_kind "ap_invoice:approve"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(@repo)
    org = Ash.UUID.generate()

    {:ok,
     org: org,
     admin_scope: scope(org, "admin:#{org}", :admin),
     member_scope: scope(org, "member:#{org}", :member)}
  end

  test "a policy auto-approves strictly below its threshold; the boundary still gates", %{
    org: org,
    admin_scope: admin_scope,
    member_scope: member_scope
  } do
    expense = seed_posting_accounts(org)

    policy(admin_scope, org, %{auto_approve_below: true, threshold_cents: 10_000})

    below = new_bill(member_scope, org, [line(expense, 9_999)])
    assert {:ok, approved} = approve(below, member_scope)
    assert approved.status == :approved
    assert approved.posted_at
    assert ap_entry!(org, below.id).status == :posted

    at_threshold = new_bill(member_scope, org, [line(expense, 10_000)])

    assert {:error, %Ash.Error.Forbidden{errors: errors}} = approve(at_threshold, member_scope)
    approval_id = approval_id!(errors)

    assert Ash.get!(ApInvoice, at_threshold.id, authorize?: false).status == :draft

    assert {:ok, _decided, _meta} =
             Samen.Approvals.approve(approval_id, "approver:#{org}", approval_opts())

    assert Ash.get!(ApInvoice, at_threshold.id, authorize?: false).status == :approved
  end

  test "account scope selects the configured chain and never auto-approves outside it", %{
    org: org,
    admin_scope: admin_scope,
    member_scope: member_scope
  } do
    expense = seed_posting_accounts(org)
    other_expense = new_account(org, "6100")

    policy(admin_scope, org, %{
      threshold_cents: 0,
      auto_approve_below: true,
      account_ids: [expense.id],
      steps: [%{"approver_type" => "role", "approver" => "admin"}]
    })

    inside = new_bill(member_scope, org, [line(expense, 5_000)])
    assert {:error, %Ash.Error.Forbidden{errors: inside_errors}} = approve(inside, member_scope)

    assert {:ok, inside_pending} =
             Samen.Approvals.get(approval_id!(inside_errors), approval_opts())

    assert [%{"approver" => "admin"}] = inside_pending.steps

    outside = new_bill(member_scope, org, [line(other_expense, 1_000)])
    assert {:error, %Ash.Error.Forbidden{errors: outside_errors}} = approve(outside, member_scope)

    assert {:ok, outside_pending} =
             Samen.Approvals.get(approval_id!(outside_errors), approval_opts())

    assert outside_pending.steps == []
    assert Ash.get!(ApInvoice, outside.id, authorize?: false).status == :draft
  end

  test "period scope applies auto-approval only inside the listed bill month", %{
    org: org,
    admin_scope: admin_scope,
    member_scope: member_scope
  } do
    expense = seed_posting_accounts(org)

    policy(admin_scope, org, %{
      threshold_cents: 10_000,
      auto_approve_below: true,
      period_keys: ["2026-11"]
    })

    inside = new_bill(member_scope, org, [line(expense, 1_000)], ~D[2026-11-12])
    assert {:ok, approved} = approve(inside, member_scope)
    assert approved.status == :approved

    outside = new_bill(member_scope, org, [line(expense, 1_000)], ~D[2026-12-12])
    assert {:error, %Ash.Error.Forbidden{errors: errors}} = approve(outside, member_scope)

    assert {:ok, pending} = Samen.Approvals.get(approval_id!(errors), approval_opts())
    assert pending.steps == []
    assert Ash.get!(ApInvoice, outside.id, authorize?: false).status == :draft
  end

  test "a policy update needs a distinct admin and applies the approved scope and chain", %{
    org: org,
    admin_scope: admin_scope
  } do
    expense = seed_posting_accounts(org)
    policy_row = policy(admin_scope, org, %{threshold_cents: 0})

    attrs = %{
      threshold_cents: 25_000,
      auto_approve_below: true,
      account_ids: [expense.id],
      period_keys: ["2026-11"],
      steps: [%{"approver_type" => "role", "approver" => "admin"}]
    }

    assert {:error, %Ash.Error.Forbidden{errors: errors}} =
             policy_row
             |> Ash.Changeset.for_update(:update, attrs, scope: admin_scope)
             |> Ash.update()

    approval_id = approval_id!(errors)
    unchanged = Ash.get!(ApprovalPolicy, policy_row.id, authorize?: false)
    assert unchanged.threshold_cents == 0
    assert unchanged.account_ids == []
    assert unchanged.period_keys == []

    assert {:error, :self_approval} =
             Samen.Approvals.approve(approval_id, "admin:#{org}", approval_opts())

    assert {:ok, _decided, _meta} =
             Samen.Approvals.approve(approval_id, "admin2:#{org}", approval_opts())

    updated = Ash.get!(ApprovalPolicy, policy_row.id, authorize?: false)
    assert updated.threshold_cents == 25_000
    assert updated.auto_approve_below
    assert updated.account_ids == [expense.id]
    assert updated.period_keys == ["2026-11"]
    assert updated.steps == [%{"approver_type" => "role", "approver" => "admin"}]
  end

  test "no policy and an opt-out policy both preserve the Gate", %{
    org: org,
    admin_scope: admin_scope,
    member_scope: member_scope
  } do
    expense = seed_posting_accounts(org)

    no_policy_bill = new_bill(member_scope, org, [line(expense, 1_000)])

    assert {:error, %Ash.Error.Forbidden{errors: no_policy_errors}} =
             approve(no_policy_bill, member_scope)

    assert approval_id!(no_policy_errors)

    policy(admin_scope, org, %{auto_approve_below: false, threshold_cents: 50_000})

    opt_out_bill = new_bill(member_scope, org, [line(expense, 1_000)])

    assert {:error, %Ash.Error.Forbidden{errors: opt_out_errors}} =
             approve(opt_out_bill, member_scope)

    assert approval_id!(opt_out_errors)
  end

  test "the generic policy is admin-owned, one per org and kind, and validates steps", %{
    org: org,
    admin_scope: admin_scope,
    member_scope: member_scope
  } do
    assert {:error, %Ash.Error.Forbidden{}} =
             create_policy(member_scope, org, %{threshold_cents: 1_000})

    assert {:error, _} = create_policy(admin_scope, org, %{threshold_cents: -1})

    assert {:error, _} =
             create_policy(admin_scope, org, %{
               steps: [%{"approver_type" => "role", "approver" => "owner"}]
             })

    assert {:error, _} =
             create_policy(admin_scope, org, %{
               steps: [
                 %{"approver_type" => "user", "approver" => "u1", "role" => "owner"}
               ]
             })

    assert {:ok, _policy} = create_policy(admin_scope, org, %{threshold_cents: 1_000})
    assert {:error, _} = create_policy(admin_scope, org, %{threshold_cents: 2_000})

    assert {:ok, _other_kind} =
             create_policy(admin_scope, org, %{kind: "journal_entry:post", threshold_cents: 1_000})
  end

  test "named-user and role steps approve sequentially; only the final step posts", %{
    org: org,
    admin_scope: admin_scope,
    member_scope: member_scope
  } do
    expense = seed_posting_accounts(org)
    first = "admin:#{org}"
    final = "final:#{org}"

    policy(admin_scope, org, %{
      threshold_cents: 0,
      auto_approve_below: false,
      steps: [
        %{"approver_type" => "role", "approver" => "admin"},
        %{"approver_type" => "user", "approver" => final}
      ]
    })

    bill = new_bill(member_scope, org, [line(expense, 5_000)])

    assert {:error, %Ash.Error.Forbidden{errors: errors}} = approve(bill, member_scope)
    approval_id = approval_id!(errors)

    assert {:ok, pending} = Samen.Approvals.get(approval_id, approval_opts())
    assert pending.state == :pending
    assert pending.decided_by == nil
    assert [%{"state" => "pending"}, %{"state" => "pending"}] = pending.steps

    assert {:error, :step_approver_mismatch} =
             Samen.Approvals.approve(
               approval_id,
               "other:#{org}",
               approval_opts() ++ [role: :member]
             )

    assert {:ok, advanced, %{step: 1, pending_step: 2}} =
             Samen.Approvals.approve(approval_id, first, approval_opts() ++ [role: :admin])

    assert advanced.state == :pending
    assert advanced.decided_by == nil
    assert [%{"state" => "approved"}, %{"state" => "pending"}] = advanced.steps
    assert Ash.get!(ApInvoice, bill.id, authorize?: false).status == :draft
    assert ap_entry(org, bill.id) == nil

    assert {:ok, approved, %{executed: "approve"}} =
             Samen.Approvals.approve(approval_id, final, approval_opts())

    assert approved.state == :approved
    assert approved.decided_by == final
    assert [%{"state" => "approved"}, %{"state" => "approved"}] = approved.steps
    assert Ash.get!(ApInvoice, bill.id, authorize?: false).status == :approved
    assert ap_entry!(org, bill.id).status == :posted

    assert {:error, :not_pending} =
             Samen.Approvals.approve(approval_id, "another:#{org}", approval_opts())
  end

  test "a named-user step can be limited to an admin or member role", %{
    org: org,
    admin_scope: admin_scope,
    member_scope: member_scope
  } do
    expense = seed_posting_accounts(org)
    approver = "role-limited:#{org}"

    policy(admin_scope, org, %{
      threshold_cents: 0,
      auto_approve_below: false,
      steps: [%{"approver_type" => "user", "approver" => approver, "role" => "admin"}]
    })

    bill = new_bill(member_scope, org, [line(expense, 5_000)])
    assert {:error, %Ash.Error.Forbidden{errors: errors}} = approve(bill, member_scope)
    approval_id = approval_id!(errors)

    assert {:ok, pending} = Samen.Approvals.get(approval_id, approval_opts())

    assert [%{"approver" => ^approver, "role" => "admin", "state" => "pending"}] =
             pending.steps

    assert {:error, :step_approver_mismatch} =
             Samen.Approvals.approve(approval_id, approver, approval_opts() ++ [role: :member])

    assert {:error, :step_approver_mismatch} =
             Samen.Approvals.approve(approval_id, approver, approval_opts())

    assert {:ok, approved, %{executed: "approve"}} =
             Samen.Approvals.approve(approval_id, approver, approval_opts() ++ [role: :admin])

    assert approved.state == :approved
    assert Ash.get!(ApInvoice, bill.id, authorize?: false).status == :approved
    assert ap_entry!(org, bill.id).status == :posted
  end

  test "a rejection at an intermediate step leaves the bill draft and skips the rest", %{
    org: org,
    admin_scope: admin_scope,
    member_scope: member_scope
  } do
    expense = seed_posting_accounts(org)

    policy(admin_scope, org, %{
      steps: [
        %{"approver_type" => "role", "approver" => "admin"},
        %{"approver_type" => "user", "approver" => "final:#{org}"}
      ]
    })

    bill = new_bill(member_scope, org, [line(expense, 5_000)])
    assert {:error, %Ash.Error.Forbidden{errors: errors}} = approve(bill, member_scope)
    approval_id = approval_id!(errors)

    assert {:ok, rejected} =
             Samen.Approvals.reject(
               approval_id,
               "admin:#{org}",
               approval_opts() ++ [role: :admin]
             )

    assert rejected.state == :rejected
    assert rejected.decided_by == "admin:#{org}"
    assert [%{"state" => "rejected"}, %{"state" => "skipped"}] = rejected.steps
    assert Ash.get!(ApInvoice, bill.id, authorize?: false).status == :draft
    assert ap_entry(org, bill.id) == nil
  end

  test "the requester cannot approve their own first step", %{
    org: org,
    admin_scope: admin_scope
  } do
    expense = seed_posting_accounts(org)

    policy(admin_scope, org, %{
      steps: [%{"approver_type" => "role", "approver" => "admin"}]
    })

    bill = new_bill(admin_scope, org, [line(expense, 5_000)])
    assert {:error, %Ash.Error.Forbidden{errors: errors}} = approve(bill, admin_scope)
    approval_id = approval_id!(errors)

    assert {:error, :self_approval} =
             Samen.Approvals.approve(
               approval_id,
               "admin:#{org}",
               approval_opts() ++ [role: :admin]
             )

    assert {:ok, still_pending} = Samen.Approvals.get(approval_id, approval_opts())
    assert still_pending.state == :pending
    assert Ash.get!(ApInvoice, bill.id, authorize?: false).status == :draft
  end

  # -- helpers ----------------------------------------------------------------

  defp approval_opts,
    do: [approval_resource: @approval_resource, repo: @repo]

  defp scope(org_id, id, role) do
    %Samen.Scope{
      actor: %{id: id, org_id: org_id, role: role, kind: :tenant, plane: :tenant}
    }
  end

  defp policy(scope, org, attrs) do
    case create_policy(scope, org, attrs) do
      {:ok, policy} -> policy
      {:error, error} -> flunk("could not create approval policy: #{inspect(error)}")
    end
  end

  defp create_policy(scope, org, attrs) do
    ApprovalPolicy
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(
        %{
          org_id: org,
          kind: @policy_kind,
          threshold_cents: 0,
          auto_approve_below: false,
          steps: []
        },
        attrs
      ),
      scope: scope
    )
    |> Ash.create()
  end

  defp seed_posting_accounts(org) do
    expense = new_account(org, "6000")
    income = new_account(org, "4000")

    for {key, account} <- [
          {:ap_clearing, new_account(org, "2000")},
          {:ar_clearing, new_account(org, "1200")},
          {:cash, new_account(org, "1000")},
          {:income, income}
        ] do
      PostingAccount
      |> Ash.Changeset.for_create(:create, %{org_id: org, key: key, account_id: account.id},
        scope: scope(org, "admin:#{org}", :admin)
      )
      |> Ash.create!()
    end

    expense
  end

  defp new_account(org, code) do
    Account
    |> Ash.Changeset.for_create(
      :create,
      %{org_id: org, code: code, name: "Account #{code}", kind: :asset, normal_side: :debit},
      scope: scope(org, "member:#{org}", :member)
    )
    |> Ash.create!()
  end

  defp new_bill(scope, org, lines, bill_date \\ ~D[2026-11-12]) do
    ApInvoice
    |> Ash.Changeset.for_create(
      :create,
      %{
        org_id: org,
        vendor_id: Ash.UUID.generate(),
        number: "V-" <> binary_part(Ash.UUID.generate(), 0, 8),
        bill_date: bill_date,
        lines: lines
      },
      scope: scope
    )
    |> Ash.create!()
  end

  defp line(account, amount), do: %{account_id: account.id, amount_cents: amount}

  defp approve(bill, scope) do
    bill
    |> Ash.Changeset.for_update(:approve, %{}, scope: scope)
    |> Ash.update()
  end

  defp ap_entry(org, bill_id) do
    JournalEntry
    |> Ash.Query.filter(org_id == ^org and source_key == "ap_invoice" and source_id == ^bill_id)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, entry} -> entry
      _ -> nil
    end
  end

  defp ap_entry!(org, bill_id) do
    case ap_entry(org, bill_id) do
      nil -> flunk("expected an AP journal entry")
      entry -> entry
    end
  end

  defp approval_id!(errors) do
    case Enum.find(errors, &match?(%{__struct__: Samen.Approvals.ApprovalRequired}, &1)) do
      nil -> flunk("expected ApprovalRequired, got: #{inspect(errors)}")
      found -> found.approval_id
    end
  end
end
