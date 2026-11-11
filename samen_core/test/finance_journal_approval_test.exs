defmodule Samen.FinanceJournalApprovalTest do
  @moduledoc """
  WS-ACCT journal controls: the org policy gates manual postings, the preparer
  is the requester, self-approval is refused, a distinct approver posts exactly
  once, and system cascades remain outside the human approval queue.
  """

  use ExUnit.Case, async: false

  require Ash.Query

  alias SamenCore.Support.FinanceFixture.{
    Account,
    JournalApprovalPolicy,
    JournalEntry
  }

  @repo SamenCore.TestRepo
  @approval_resource SamenCore.Support.ApprovalsFixture.Approval

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(@repo)
    org = Ash.UUID.generate()

    {:ok,
     org: org,
     admin_scope: scope(org, "admin:#{org}", :admin),
     other_admin_scope: scope(org, "admin2:#{org}", :admin),
     member_scope: scope(org, "member:#{org}", :member),
     other_member_scope: scope(org, "member2:#{org}", :member)}
  end

  describe "journal approval policy" do
    test "a policy-gated manual post opens an approval and leaves the entry draft", %{
      org: org,
      admin_scope: admin_scope,
      member_scope: member_scope
    } do
      {cash, sales} = accounts(admin_scope, org)
      policy(admin_scope, org)
      entry = entry(member_scope, org, cash, sales, 5_000)

      assert {:error, %Ash.Error.Forbidden{errors: errors}} = post(entry, member_scope)
      approval = approval_error!(errors)

      assert approval.kind == Atom.to_string(JournalEntry) <> ":post"

      {:ok, row} =
        Samen.Approvals.get(approval.approval_id,
          approval_resource: @approval_resource,
          repo: @repo
        )

      assert row.state == :pending
      assert row.requested_by == "member:#{org}"
      assert String.starts_with?(row.subject_ref, "samen:sje:#{entry.id}:")

      assert Ash.get!(JournalEntry, entry.id, authorize?: false).status == :draft
    end

    test "self-approval is refused; a distinct approver posts exactly once", %{
      org: org,
      admin_scope: admin_scope,
      member_scope: member_scope
    } do
      {cash, sales} = accounts(admin_scope, org)
      policy(admin_scope, org)
      entry = entry(member_scope, org, cash, sales, 5_000)

      assert {:error, %Ash.Error.Forbidden{errors: errors}} = post(entry, member_scope)
      approval_id = approval_error!(errors).approval_id

      assert {:error, :self_approval} =
               Samen.Approvals.approve(approval_id, "member:#{org}",
                 approval_resource: @approval_resource,
                 repo: @repo
               )

      assert {:ok, _decided, _meta} =
               Samen.Approvals.approve(approval_id, "approver:#{org}",
                 approval_resource: @approval_resource,
                 repo: @repo
               )

      posted = Ash.get!(JournalEntry, entry.id, authorize?: false)
      assert posted.status == :posted
      assert posted.prepared_by == "member:#{org}"
      assert posted.approved_by == "approver:#{org}"
      assert posted.approval_id == approval_id
      assert posted.approved_at

      # The same approval cannot be replayed, and the one-way state machine
      # refuses a second post even if someone reopens the action.
      assert {:error, :not_pending} =
               Samen.Approvals.approve(approval_id, "approver2:#{org}",
                 approval_resource: @approval_resource,
                 repo: @repo
               )

      assert {:error, _} = post(posted, member_scope)
    end

    test "an entry cannot be edited while its post approval is pending", %{
      org: org,
      admin_scope: admin_scope,
      member_scope: member_scope
    } do
      {cash, sales} = accounts(admin_scope, org)
      policy(admin_scope, org)
      entry = entry(member_scope, org, cash, sales, 5_000)

      assert {:error, %Ash.Error.Forbidden{errors: errors}} = post(entry, member_scope)
      _approval = approval_error!(errors)

      assert {:error, %Ash.Error.Invalid{} = error} =
               entry
               |> Ash.Changeset.for_update(
                 :update,
                 %{
                   lines: [
                     %{account_id: sales.id, debit_cents: 5_000},
                     %{account_id: cash.id, credit_cents: 5_000}
                   ]
                 },
                 action_opts(member_scope)
               )
               |> Ash.update(action_opts(member_scope))

      assert Exception.message(error) =~ "approval is pending"
      assert length(Ash.load!(entry, [:lines], authorize?: false).lines) == 2
    end

    test "a changed draft cannot use an approval opened for the old revision", %{
      org: org,
      admin_scope: admin_scope,
      member_scope: member_scope
    } do
      {cash, sales} = accounts(admin_scope, org)
      policy(admin_scope, org)
      entry = entry(member_scope, org, cash, sales, 5_000)

      assert {:error, %Ash.Error.Forbidden{errors: errors}} = post(entry, member_scope)
      approval_id = approval_error!(errors).approval_id

      {:ok, entry_id} = Ecto.UUID.dump(entry.id)

      # Line rows reject UPDATE at the DB; a permitted entry-level mutation
      # still proves the approval is bound to the stored content.
      @repo.query!(
        "UPDATE sje_journal_entry SET sje_memo = $1 WHERE sje_id = $2",
        ["tampered after approval", entry_id]
      )

      assert Ash.get!(JournalEntry, entry.id, authorize?: false).memo == "tampered after approval"

      assert {:error, _reason} =
               Samen.Approvals.approve(approval_id, "approver:#{org}",
                 approval_resource: @approval_resource,
                 repo: @repo
               )

      assert Ash.get!(JournalEntry, entry.id, authorize?: false).status == :draft
    end

    test "a different principal cannot submit the preparer's entry", %{
      org: org,
      admin_scope: admin_scope,
      member_scope: member_scope,
      other_member_scope: other_member_scope
    } do
      {cash, sales} = accounts(admin_scope, org)
      policy(admin_scope, org)
      entry = entry(member_scope, org, cash, sales, 5_000)

      assert {:error, %Ash.Error.Invalid{} = error} = post(entry, other_member_scope)
      assert Exception.message(error) =~ "prepared by member:"
    end

    test "a disabled policy and a below-threshold entry keep the ordinary post path", %{
      org: org,
      admin_scope: admin_scope,
      member_scope: member_scope
    } do
      {cash, sales} = accounts(admin_scope, org)
      policy(admin_scope, org, %{threshold_cents: 10_000})

      small = entry(member_scope, org, cash, sales, 5_000)
      assert {:ok, posted} = post(small, member_scope)
      assert posted.status == :posted

      policy_row =
        JournalApprovalPolicy
        |> Ash.Query.filter(org_id == ^org)
        |> Ash.read_one!(authorize?: false)

      policy_row =
        change_policy!(policy_row, %{enabled: false}, admin_scope, "admin2:#{org}")

      refute policy_row.enabled

      large = entry(member_scope, org, cash, sales, 25_000)
      assert {:ok, posted_large} = post(large, member_scope)
      assert posted_large.status == :posted
    end

    test "policy changes need a distinct admin and apply the approved values", %{
      org: org,
      admin_scope: admin_scope,
      other_admin_scope: other_admin_scope
    } do
      policy_row = policy(admin_scope, org)

      assert {:error, %Ash.Error.Forbidden{errors: errors}} =
               policy_row
               |> Ash.Changeset.for_update(
                 :update,
                 %{enabled: false, threshold_cents: 12_500},
                 scope: admin_scope
               )
               |> Ash.update()

      approval = approval_error!(errors)
      assert approval.kind == Atom.to_string(JournalApprovalPolicy) <> ":update"

      assert {:error, :self_approval} =
               Samen.Approvals.approve(approval.approval_id, admin_scope.actor.id,
                 approval_resource: @approval_resource,
                 repo: @repo
               )

      assert Ash.get!(JournalApprovalPolicy, policy_row.id, authorize?: false).enabled

      assert {:ok, _decided, _meta} =
               Samen.Approvals.approve(approval.approval_id, other_admin_scope.actor.id,
                 approval_resource: @approval_resource,
                 repo: @repo
               )

      updated = Ash.get!(JournalApprovalPolicy, policy_row.id, authorize?: false)
      refute updated.enabled
      assert updated.threshold_cents == 12_500
    end

    test "account scope only gates entries touching a scoped account", %{
      org: org,
      admin_scope: admin_scope,
      member_scope: member_scope
    } do
      {cash, sales} = accounts(admin_scope, org)
      other = account(admin_scope, org, "1001", "Other Cash", :asset, :debit)
      policy(admin_scope, org, %{account_ids: [cash.id]})

      scoped = entry(member_scope, org, cash, sales, 5_000)
      assert {:error, %Ash.Error.Forbidden{errors: errors}} = post(scoped, member_scope)
      assert approval_error!(errors).kind == Atom.to_string(JournalEntry) <> ":post"

      outside = entry(member_scope, org, other, sales, 5_000)
      assert {:ok, posted} = post(outside, member_scope)
      assert posted.status == :posted
    end

    test "period scope only gates entries in a listed month", %{
      org: org,
      admin_scope: admin_scope,
      member_scope: member_scope
    } do
      {cash, sales} = accounts(admin_scope, org)
      policy(admin_scope, org, %{period_keys: ["2026-11"]})

      matching = entry(member_scope, org, cash, sales, 5_000, ~D[2026-11-08])
      assert {:error, %Ash.Error.Forbidden{errors: errors}} = post(matching, member_scope)
      assert approval_error!(errors).kind == Atom.to_string(JournalEntry) <> ":post"

      outside = entry(member_scope, org, cash, sales, 5_000, ~D[2026-12-08])
      assert {:ok, posted} = post(outside, member_scope)
      assert posted.status == :posted
    end

    test "a system posting without an actor is not sent to a human approval queue", %{
      org: org,
      admin_scope: admin_scope
    } do
      {cash, sales} = accounts(admin_scope, org)
      policy(admin_scope, org)

      entry = entry(nil, org, cash, sales, 5_000)
      assert {:ok, posted} = post(entry, nil)
      assert posted.status == :posted
      assert is_nil(posted.prepared_by)
      assert is_nil(posted.approved_by)
    end

    test "a forged approval context is refused — the approval row is re-read", %{
      org: org,
      admin_scope: admin_scope,
      member_scope: member_scope
    } do
      {cash, sales} = accounts(admin_scope, org)
      policy(admin_scope, org)
      entry = entry(member_scope, org, cash, sales, 5_000)

      result =
        entry
        |> Ash.Changeset.for_update(:post, %{},
          scope: member_scope,
          context: %{
            approval_ok: true,
            approved_by: "approver:#{org}",
            approval_id: Ash.UUID.generate()
          }
        )
        |> Ash.update()

      assert {:error, %Ash.Error.Invalid{} = error} = result
      assert Exception.message(error) =~ "could not be verified"
      assert Ash.get!(JournalEntry, entry.id, authorize?: false).status == :draft
    end

    test "a void also needs a distinct approver", %{
      org: org,
      admin_scope: admin_scope,
      member_scope: member_scope
    } do
      {cash, sales} = accounts(admin_scope, org)
      policy(admin_scope, org)
      entry = entry(member_scope, org, cash, sales, 5_000)

      # The system path is how a document/seed lands the original; the VOID is
      # a human posting event and must go through the same policy.
      assert {:ok, posted} = post(entry, nil)

      assert {:error, %Ash.Error.Forbidden{errors: errors}} = void(posted, member_scope)
      approval_id = approval_error!(errors).approval_id

      assert {:ok, _decided, _meta} =
               Samen.Approvals.approve(approval_id, "approver:#{org}",
                 approval_resource: @approval_resource,
                 repo: @repo
               )

      assert Ash.get!(JournalEntry, posted.id, authorize?: false).status == :void
    end

    test "the policy threshold is validated and one row per org is enforced", %{
      org: org,
      admin_scope: admin_scope
    } do
      policy(admin_scope, org)

      assert {:error, _} = create_policy(admin_scope, org, %{threshold_cents: -1})
      assert {:error, _} = create_policy(admin_scope, org, %{})
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp scope(org_id, id, role) do
    %Samen.Scope{
      actor: %{id: id, org_id: org_id, role: role, kind: :tenant, plane: :tenant}
    }
  end

  defp accounts(scope, org) do
    cash =
      Account
      |> Ash.Changeset.for_create(
        :create,
        %{org_id: org, code: "1000", name: "Cash", kind: :asset, normal_side: :debit},
        scope: scope
      )
      |> Ash.create!()

    sales =
      Account
      |> Ash.Changeset.for_create(
        :create,
        %{org_id: org, code: "4000", name: "Sales", kind: :income, normal_side: :credit},
        scope: scope
      )
      |> Ash.create!()

    {cash, sales}
  end

  defp policy(scope, org, attrs \\ %{}) do
    case create_policy(scope, org, attrs) do
      {:ok, policy} -> policy
      {:error, error} -> flunk("could not create policy: #{inspect(error)}")
    end
  end

  defp create_policy(scope, org, attrs) do
    JournalApprovalPolicy
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(%{org_id: org, enabled: true, threshold_cents: 0}, attrs),
      scope: scope
    )
    |> Ash.create()
  end

  defp account(scope, org, code, name, kind, normal_side) do
    Account
    |> Ash.Changeset.for_create(
      :create,
      %{org_id: org, code: code, name: name, kind: kind, normal_side: normal_side},
      scope: scope
    )
    |> Ash.create!()
  end

  defp entry(scope, org, cash, sales, amount, entry_date \\ ~D[2026-11-08]) do
    attrs = %{
      org_id: org,
      entry_date: entry_date,
      memo: "manual journal",
      lines: [
        %{account_id: cash.id, debit_cents: amount},
        %{account_id: sales.id, credit_cents: amount}
      ]
    }

    JournalEntry
    |> Ash.Changeset.for_create(:create, attrs, action_opts(scope))
    |> Ash.create!(action_opts(scope))
  end

  defp post(entry, scope) do
    entry
    |> Ash.Changeset.for_update(:post, %{}, action_opts(scope))
    |> Ash.update(action_opts(scope))
  end

  defp void(entry, scope) do
    entry
    |> Ash.Changeset.for_update(:void, %{}, action_opts(scope))
    |> Ash.update(action_opts(scope))
  end

  defp action_opts(nil), do: [authorize?: false]
  defp action_opts(scope), do: [scope: scope]

  defp approval_error!(errors) do
    case Enum.find(errors, &match?(%{__struct__: Samen.Approvals.ApprovalRequired}, &1)) do
      nil -> flunk("expected ApprovalRequired, got: #{inspect(errors)}")
      found -> found
    end
  end

  defp change_policy!(policy, attrs, scope, approver_id) do
    assert {:error, %Ash.Error.Forbidden{errors: errors}} =
             policy
             |> Ash.Changeset.for_update(:update, attrs, scope: scope)
             |> Ash.update()

    approval = approval_error!(errors)

    assert {:ok, _decided, _meta} =
             Samen.Approvals.approve(approval.approval_id, approver_id,
               approval_resource: @approval_resource,
               repo: @repo
             )

    Ash.get!(JournalApprovalPolicy, policy.id, authorize?: false)
  end
end
