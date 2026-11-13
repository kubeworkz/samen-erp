defmodule Samen.FinanceJournalTemplatesTest do
  @moduledoc """
  Recurring/template journals (WS-ERP): a template generates an ORDINARY DRAFT
  journal, never a posted entry; the generated draft then rides the same
  `:post`/`JournalApprovalPolicy` path as any hand-entered draft.
  """

  use ExUnit.Case, async: false

  require Ash.Query

  alias SamenCore.Support.FinanceFixture.{
    Account,
    JournalApprovalPolicy,
    JournalEntry,
    JournalTemplate
  }

  alias Samen.Scopes.Finance.RecurringJournalRun

  @repo SamenCore.TestRepo
  @approval_resource SamenCore.Support.ApprovalsFixture.Approval

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(@repo)
    org = Ash.UUID.generate()
    other_org = Ash.UUID.generate()

    {:ok,
     org: org,
     admin_scope: scope(org, "admin:#{org}", :admin),
     member_scope: scope(org, "member:#{org}", :member),
     other_scope: scope(other_org, "other:#{other_org}", :admin)}
  end

  describe "template validation" do
    test "a balanced template is saved with canonical line values", %{
      org: org,
      admin_scope: admin_scope
    } do
      {cash, sales} = accounts(admin_scope, org)

      assert {:ok, template} =
               create_template(admin_scope, org, %{
                 name: "Monthly rent",
                 lines: [
                   %{account_id: cash.id, debit_cents: 125_000},
                   %{account_id: sales.id, credit_cents: 125_000}
                 ]
               })

      assert template.frequency == :none
      assert template.active
      assert length(template.lines) == 2
      assert Enum.any?(template.lines, &(&1.account_id == cash.id and &1.debit_cents == 125_000))
    end

    test "unbalanced, empty and foreign-account line sets are refused", %{
      org: org,
      admin_scope: admin_scope,
      other_scope: other_scope
    } do
      {cash, sales} = accounts(admin_scope, org)
      {foreign_cash, _foreign_sales} = accounts(other_scope, other_scope.actor.org_id)

      assert {:error, _} =
               create_template(admin_scope, org, %{
                 name: "Unbalanced",
                 lines: [
                   %{account_id: cash.id, debit_cents: 5_000},
                   %{account_id: sales.id, credit_cents: 4_000}
                 ]
               })

      assert {:error, _} =
               create_template(admin_scope, org, %{name: "Empty", lines: []})

      assert {:error, _} =
               create_template(admin_scope, org, %{
                 name: "Foreign",
                 lines: [
                   %{account_id: foreign_cash.id, debit_cents: 5_000},
                   %{account_id: sales.id, credit_cents: 5_000}
                 ]
               })

      assert Ash.read!(JournalTemplate, authorize?: false) == []
    end

    test "a recurring template requires a next run date; a manual one does not", %{
      org: org,
      admin_scope: admin_scope
    } do
      {cash, sales} = accounts(admin_scope, org)

      assert {:error, _} =
               create_template(admin_scope, org, %{
                 name: "No date",
                 frequency: :monthly,
                 lines: balanced_lines(cash, sales, 9_000)
               })

      assert {:ok, template} =
               create_template(admin_scope, org, %{
                 name: "Manual",
                 frequency: :none,
                 lines: balanced_lines(cash, sales, 9_000)
               })

      assert template.next_run_on == nil
    end
  end

  describe "generation" do
    test "generates a normal draft with copied lines and a source anchor", %{
      org: org,
      admin_scope: admin_scope
    } do
      {cash, sales} = accounts(admin_scope, org)

      {:ok, template} =
        create_template(admin_scope, org, %{
          name: "Payroll accrual",
          memo: "Monthly payroll",
          lines: balanced_lines(cash, sales, 42_000)
        })

      assert {:ok, generated} = generate(template, admin_scope, ~D[2026-11-12])
      assert generated.last_generated_on == ~D[2026-11-12]
      assert generated.last_entry_id

      entry = Ash.get!(JournalEntry, generated.last_entry_id, authorize?: false)
      entry = Ash.load!(entry, [:lines], authorize?: false)

      assert entry.status == :draft
      assert entry.entry_date == ~D[2026-11-12]
      assert entry.memo == "Monthly payroll"
      assert entry.source_key == "journal_template"
      assert entry.source_id == template.id
      assert entry.prepared_by == admin_scope.actor.id
      assert Enum.map(entry.lines, & &1.debit_cents) |> Enum.sum() == 42_000
      assert Enum.map(entry.lines, & &1.credit_cents) |> Enum.sum() == 42_000
    end

    test "generation is idempotent per template and entry date", %{
      org: org,
      admin_scope: admin_scope
    } do
      {cash, sales} = accounts(admin_scope, org)

      {:ok, template} =
        create_template(admin_scope, org, %{
          name: "Rent",
          lines: balanced_lines(cash, sales, 100_000)
        })

      assert {:ok, first} = generate(template, admin_scope, ~D[2026-11-12])
      assert {:ok, second} = generate(template, admin_scope, ~D[2026-11-12])

      assert first.last_entry_id == second.last_entry_id

      entries =
        JournalEntry
        |> Ash.Query.filter(source_key == "journal_template" and source_id == ^template.id)
        |> Ash.read!(authorize?: false)

      assert length(entries) == 1
    end

    test "a monthly schedule clamps month-end and advances from the due date", %{
      org: org,
      admin_scope: admin_scope
    } do
      {cash, sales} = accounts(admin_scope, org)

      {:ok, template} =
        create_template(admin_scope, org, %{
          name: "Month-end rent",
          frequency: :monthly,
          next_run_on: ~D[2026-01-31],
          lines: balanced_lines(cash, sales, 100_000)
        })

      assert {:ok, generated} = generate(template, admin_scope, ~D[2026-01-31])
      assert generated.last_generated_on == ~D[2026-01-31]
      assert generated.next_run_on == ~D[2026-02-28]
    end

    test "generating early does not consume the scheduled date", %{
      org: org,
      admin_scope: admin_scope
    } do
      {cash, sales} = accounts(admin_scope, org)

      {:ok, template} =
        create_template(admin_scope, org, %{
          name: "Quarterly tax",
          frequency: :quarterly,
          next_run_on: ~D[2027-01-01],
          lines: balanced_lines(cash, sales, 50_000)
        })

      assert {:ok, generated} = generate(template, admin_scope, ~D[2026-12-15])
      assert generated.last_generated_on == ~D[2026-12-15]
      assert generated.next_run_on == ~D[2027-01-01]
    end
  end

  describe "scheduled run and approval path" do
    test "the run generates one draft for a due active template and ignores inactive ones", %{
      org: org,
      admin_scope: admin_scope
    } do
      {cash, sales} = accounts(admin_scope, org)

      {:ok, due} =
        create_template(admin_scope, org, %{
          name: "Due rent",
          frequency: :monthly,
          next_run_on: ~D[2026-11-01],
          lines: balanced_lines(cash, sales, 100_000)
        })

      {:ok, inactive} =
        create_template(admin_scope, org, %{
          name: "Inactive",
          active: false,
          frequency: :monthly,
          next_run_on: ~D[2026-11-01],
          lines: balanced_lines(cash, sales, 20_000)
        })

      assert {:ok, %{generated: [entry_id], failed: []}} =
               RecurringJournalRun.run(
                 template_module: JournalTemplate,
                 today: ~D[2026-11-12]
               )

      entry = Ash.get!(JournalEntry, entry_id, authorize?: false)
      assert entry.status == :draft
      assert entry.source_id == due.id
      assert entry.entry_date == ~D[2026-11-01]

      assert Ash.get!(JournalTemplate, due.id, authorize?: false).next_run_on ==
               ~D[2026-12-01]

      assert Ash.get!(JournalTemplate, inactive.id, authorize?: false).last_entry_id == nil
      assert is_nil(inactive.last_entry_id)

      # A second run before the next due date is a clean no-op.
      assert {:ok, %{generated: [], failed: []}} =
               RecurringJournalRun.run(
                 template_module: JournalTemplate,
                 today: ~D[2026-11-12]
               )
    end

    test "a cron-generated draft is posted only through the ordinary approval gate", %{
      org: org,
      admin_scope: admin_scope,
      member_scope: member_scope
    } do
      {cash, sales} = accounts(admin_scope, org)

      {:ok, _template} =
        create_template(admin_scope, org, %{
          name: "Recurring accrual",
          frequency: :monthly,
          next_run_on: ~D[2026-11-01],
          lines: balanced_lines(cash, sales, 75_000)
        })

      approval_policy(admin_scope, org)

      assert {:ok, %{generated: [entry_id]}} =
               RecurringJournalRun.run(
                 template_module: JournalTemplate,
                 today: ~D[2026-11-02]
               )

      entry = Ash.get!(JournalEntry, entry_id, authorize?: false)
      assert entry.status == :draft
      assert is_nil(entry.prepared_by)

      # A person submits the cron draft; the first submitter becomes the
      # preparer, exactly as for any other system-created draft.
      assert {:error, %Ash.Error.Forbidden{errors: errors}} = post(entry, member_scope)
      approval = approval_error!(errors)

      assert approval.kind == Atom.to_string(JournalEntry) <> ":post"

      {:ok, row} =
        Samen.Approvals.get(approval.approval_id,
          approval_resource: @approval_resource,
          repo: @repo
        )

      assert row.requested_by == member_scope.actor.id
      assert row.state == :pending
      assert Ash.get!(JournalEntry, entry.id, authorize?: false).status == :draft

      assert {:error, :self_approval} =
               Samen.Approvals.approve(approval.approval_id, member_scope.actor.id,
                 approval_resource: @approval_resource,
                 repo: @repo
               )

      assert {:ok, _decided, _meta} =
               Samen.Approvals.approve(approval.approval_id, "approver:#{org}",
                 approval_resource: @approval_resource,
                 repo: @repo
               )

      posted = Ash.get!(JournalEntry, entry.id, authorize?: false)
      assert posted.status == :posted
      assert posted.prepared_by == member_scope.actor.id
      assert posted.approved_by == "approver:#{org}"
      assert posted.approval_id == approval.approval_id
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp scope(org_id, id, role) do
    %Samen.Scope{
      actor: %{id: id, org_id: org_id, role: role, kind: :tenant, plane: :tenant}
    }
  end

  defp accounts(scope, org) do
    cash = account(scope, org, "1000", "Cash", :asset, :debit)
    sales = account(scope, org, "4000", "Sales", :income, :credit)
    {cash, sales}
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

  defp balanced_lines(cash, sales, amount) do
    [
      %{account_id: cash.id, debit_cents: amount},
      %{account_id: sales.id, credit_cents: amount}
    ]
  end

  defp create_template(scope, org, attrs) do
    attrs =
      Map.merge(
        %{
          org_id: org,
          name: "Template",
          memo: "Template memo",
          frequency: :none,
          lines: []
        },
        attrs
      )

    JournalTemplate
    |> Ash.Changeset.for_create(:create, attrs, scope: scope)
    |> Ash.create()
  end

  defp generate(template, scope, date) do
    template
    |> Ash.Changeset.for_update(:generate, %{entry_date: date}, scope: scope)
    |> Ash.update()
  end

  defp post(entry, scope) do
    entry
    |> Ash.Changeset.for_update(:post, %{}, scope: scope)
    |> Ash.update()
  end

  defp approval_policy(scope, org) do
    JournalApprovalPolicy
    |> Ash.Changeset.for_create(
      :create,
      %{org_id: org, enabled: true, threshold_cents: 0},
      scope: scope
    )
    |> Ash.create!()
  end

  defp approval_error!(errors) do
    case Enum.find(errors, &match?(%{__struct__: Samen.Approvals.ApprovalRequired}, &1)) do
      nil -> flunk("expected ApprovalRequired, got: #{inspect(errors)}")
      found -> found
    end
  end
end
