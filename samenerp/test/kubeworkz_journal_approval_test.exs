defmodule Samenerp.KubeworkzJournalApprovalTest do
  @moduledoc """
  The Kubeworkz books seed opens an ENABLED journal approval policy, and a real
  mounted `Samenerp.Erp.JournalEntry` manual posting goes through the existing
  approvals Gate: the preparer is refused, self-approval is refused, a distinct
  approver posts exactly once, and the entry carries the approval evidence.

  End-to-end proofs change the threshold THROUGH the admin settings page for
  both `:post` and `:void`: below the threshold the action runs without an
  approval, while at or above it the Gate still needs a distinct approver.
  The boundary tests pin the exact edge: one cent below skips approval, exactly
  at the threshold requires it. A system posting has no human actor, so it
  bypasses the queue even at or above the threshold. Disabling the same control
  releases a draft that was already gated: the retry posts with no approval
  evidence, even though its threshold is still met. Re-enabling the same control
  gates a subsequently prepared manual posting again. Rejection leaves the entry
  draft; the preparer can resubmit it, and a distinct approval completes the post.
  The same cycle holds for a gated void: the entry stays posted until a fresh
  approval executes the void. Cancelling a pending post leaves the draft
  untouched; cancelling a pending void leaves the entry posted. Either can be
  resubmitted through a fresh approval. Only the requester may cancel; a
  different actor is refused.
  """

  use Samenerp.DataCase, async: false

  require Ash.Query

  alias Samen.Web.Erp.JournalApprovalLive
  alias Samen.Web.Mount
  alias Samenerp.Erp
  alias Samenerp.Kubeworkz.Books
  alias Samenerp.Operator, as: Op

  @approval_resource Samenerp.Approvals.Approval
  @repo Samenerp.Repo
  @settings_path "http://localhost/erp/journal-approval"

  defp create_org!(name) do
    Op.Org
    |> Ash.Changeset.for_create(:create, %{name: name}, authorize?: false)
    |> Ash.create!(authorize?: false)
  end

  defp scope(org_id, prefix, role) do
    %Samen.Scope{
      actor: %{
        id: "#{prefix}:#{org_id}",
        org_id: org_id,
        role: role,
        kind: :tenant,
        plane: :tenant
      }
    }
  end

  defp account!(org_id, code) do
    Erp.Account
    |> Ash.Query.filter(org_id == ^org_id and code == ^code)
    |> Ash.read_one!(authorize?: false)
  end

  defp entry!(scope, org_id, cash, sales, amount, memo) do
    Erp.JournalEntry
    |> Ash.Changeset.for_create(
      :create,
      entry_attrs(org_id, cash, sales, amount, memo),
      scope: scope
    )
    |> Ash.create!()
  end

  defp system_entry!(org_id, cash, sales, amount, memo) do
    Erp.JournalEntry
    |> Ash.Changeset.for_create(
      :create,
      entry_attrs(org_id, cash, sales, amount, memo),
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end

  defp entry_attrs(org_id, cash, sales, amount, memo) do
    %{
      org_id: org_id,
      entry_date: ~D[2026-11-08],
      memo: memo,
      lines: [
        %{account_id: cash.id, debit_cents: amount},
        %{account_id: sales.id, credit_cents: amount}
      ]
    }
  end

  defp post_entry(entry, scope) do
    entry
    |> Ash.Changeset.for_update(:post, %{}, scope: scope)
    |> Ash.update()
  end

  # A system posting has no human actor, so the approval Gate deliberately stays
  # out of the way (the same path a document/seed uses). The VOID under test is
  # the human action.
  defp post_system!(entry) do
    entry
    |> Ash.Changeset.for_update(:post, %{}, authorize?: false)
    |> Ash.update!(authorize?: false)
  end

  defp void_entry(entry, scope) do
    entry
    |> Ash.Changeset.for_update(:void, %{}, scope: scope)
    |> Ash.update()
  end

  defp approval_error!(errors) do
    Enum.find(errors, &match?(%{__struct__: Samen.Approvals.ApprovalRequired}, &1)) ||
      flunk("expected ApprovalRequired, got: #{inspect(errors)}")
  end

  defp open_settings_page(org_id) do
    mount =
      Mount.new(:erp, Samenerp.Erp, @repo,
        plane: Samen.Web.Plane.tenant(),
        labels: %{erp_path: "/erp"}
      )

    params = %{"org" => org_id}
    session = %{"samen_mount" => Mount.to_session(mount)}

    {:ok, socket} = JournalApprovalLive.mount(params, session, %Phoenix.LiveView.Socket{})
    {:noreply, socket} = JournalApprovalLive.handle_params(params, @settings_path, socket)
    socket
  end

  defp save_policy(socket, enabled, threshold_cents) do
    {:noreply, socket} =
      JournalApprovalLive.handle_event(
        "save",
        %{"form" => %{"enabled" => enabled, "threshold_cents" => threshold_cents}},
        socket
      )

    socket
  end

  defp render_settings(socket) do
    socket.assigns
    |> Map.put(:__changed__, %{})
    |> JournalApprovalLive.render()
    |> Phoenix.HTML.Safe.to_iodata()
    |> IO.iodata_to_binary()
  end

  test "the seeded policy gates a real Kubeworkz manual posting" do
    org = create_org!("Kubeworkz Journal Approval")
    org_id = to_string(org.id)
    member = scope(org_id, "member", :member)

    summary = Books.seed!(org_id)
    assert summary.journal_approval.created
    assert summary.journal_approval.enabled
    assert summary.journal_approval.threshold_cents == 0
    assert {:ok, %{journal_approval: true}} = Books.verify(org_id)

    policy =
      Erp.JournalApprovalPolicy
      |> Ash.Query.filter(org_id == ^org_id)
      |> Ash.read_one!(authorize?: false)

    assert policy.enabled
    assert policy.threshold_cents == 0

    cash = account!(org_id, "1000")
    sales = account!(org_id, "4000")

    entry =
      Erp.JournalEntry
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: org_id,
          entry_date: ~D[2026-11-08],
          memo: "Kubeworkz manual journal",
          lines: [
            %{account_id: cash.id, debit_cents: 125_000},
            %{account_id: sales.id, credit_cents: 125_000}
          ]
        },
        scope: member
      )
      |> Ash.create!()

    assert entry.prepared_by == "member:#{org_id}"

    assert {:error, %Ash.Error.Forbidden{errors: errors}} =
             entry
             |> Ash.Changeset.for_update(:post, %{}, scope: member)
             |> Ash.update()

    approval =
      Enum.find(errors, &match?(%{__struct__: Samen.Approvals.ApprovalRequired}, &1)) ||
        flunk("expected ApprovalRequired, got: #{inspect(errors)}")

    assert approval.kind == Atom.to_string(Erp.JournalEntry) <> ":post"

    {:ok, pending} =
      Samen.Approvals.get(approval.approval_id,
        approval_resource: @approval_resource,
        repo: @repo
      )

    assert pending.state == :pending
    assert pending.requested_by == "member:#{org_id}"
    assert pending.subject_ref == "samen:ecj:#{entry.id}"
    assert Ash.get!(Erp.JournalEntry, entry.id, authorize?: false).status == :draft

    assert {:error, :self_approval} =
             Samen.Approvals.approve(approval.approval_id, "member:#{org_id}",
               approval_resource: @approval_resource,
               repo: @repo
             )

    assert {:ok, _decided, %{executed: "post"}} =
             Samen.Approvals.approve(approval.approval_id, "approver:#{org_id}",
               approval_resource: @approval_resource,
               repo: @repo
             )

    posted = Ash.get!(Erp.JournalEntry, entry.id, authorize?: false)
    assert posted.status == :posted
    assert posted.approved_by == "approver:#{org_id}"
    assert posted.approval_id == approval.approval_id
    assert posted.approved_at

    assert {:error, _} =
             posted
             |> Ash.Changeset.for_update(:post, %{}, scope: member)
             |> Ash.update()
  end

  test "the settings page threshold separates below-threshold posts from gated ones" do
    org = create_org!("Kubeworkz Journal Approval Settings")
    org_id = to_string(org.id)
    member = scope(org_id, "member", :member)

    Books.seed!(org_id)

    socket = open_settings_page(org_id)
    html = render_settings(socket)
    assert html =~ "Enabled"
    assert html =~ "0 cents — every manual posting"
    assert html =~ ~s(id="journal-approval-form")

    socket = save_policy(socket, "true", "50000")
    html = render_settings(socket)
    assert html =~ "50000 cents ($500.00)"
    assert html =~ ~s(id="policy-saved")
    refute html =~ ~s(id="policy-error")

    policy =
      Erp.JournalApprovalPolicy
      |> Ash.Query.filter(org_id == ^org_id)
      |> Ash.read_one!(authorize?: false)

    assert policy.enabled
    assert policy.threshold_cents == 50_000

    cash = account!(org_id, "1000")
    sales = account!(org_id, "4000")

    below = entry!(member, org_id, cash, sales, 40_000, "Below threshold")
    assert {:ok, posted_below} = post_entry(below, member)
    assert posted_below.status == :posted
    assert posted_below.prepared_by == "member:#{org_id}"
    assert is_nil(posted_below.approval_id)

    above = entry!(member, org_id, cash, sales, 75_000, "Above threshold")

    assert {:error, %Ash.Error.Forbidden{errors: errors}} = post_entry(above, member)
    approval = approval_error!(errors)

    assert approval.kind == Atom.to_string(Erp.JournalEntry) <> ":post"
    assert Ash.get!(Erp.JournalEntry, above.id, authorize?: false).status == :draft

    {:ok, pending} =
      Samen.Approvals.get(approval.approval_id,
        approval_resource: @approval_resource,
        repo: @repo
      )

    assert pending.state == :pending
    assert pending.requested_by == "member:#{org_id}"

    assert {:error, :self_approval} =
             Samen.Approvals.approve(approval.approval_id, "member:#{org_id}",
               approval_resource: @approval_resource,
               repo: @repo
             )

    assert {:ok, _decided, %{executed: "post"}} =
             Samen.Approvals.approve(approval.approval_id, "approver:#{org_id}",
               approval_resource: @approval_resource,
               repo: @repo
             )

    posted_above = Ash.get!(Erp.JournalEntry, above.id, authorize?: false)
    assert posted_above.status == :posted
    assert posted_above.prepared_by == "member:#{org_id}"
    assert posted_above.approved_by == "approver:#{org_id}"
    assert posted_above.approval_id == approval.approval_id
    assert posted_above.approved_at
  end

  test "the settings page threshold separates below-threshold voids from gated ones" do
    org = create_org!("Kubeworkz Journal Approval Void Settings")
    org_id = to_string(org.id)
    member = scope(org_id, "member", :member)

    Books.seed!(org_id)

    socket = open_settings_page(org_id)
    assert render_settings(socket) =~ "0 cents — every manual posting"

    socket = save_policy(socket, "true", "50000")
    assert render_settings(socket) =~ "50000 cents ($500.00)"

    policy =
      Erp.JournalApprovalPolicy
      |> Ash.Query.filter(org_id == ^org_id)
      |> Ash.read_one!(authorize?: false)

    assert policy.enabled
    assert policy.threshold_cents == 50_000

    cash = account!(org_id, "1000")
    sales = account!(org_id, "4000")

    below = entry!(member, org_id, cash, sales, 40_000, "Below threshold void")
    posted_below = post_system!(below)
    assert posted_below.status == :posted
    assert is_nil(posted_below.approval_id)

    assert {:ok, voided_below} = void_entry(posted_below, member)
    assert voided_below.status == :void
    assert is_nil(voided_below.approval_id)
    assert is_nil(voided_below.approved_by)

    above = entry!(member, org_id, cash, sales, 75_000, "Above threshold void")
    posted_above = post_system!(above)
    assert posted_above.status == :posted

    assert {:error, %Ash.Error.Forbidden{errors: errors}} = void_entry(posted_above, member)
    approval = approval_error!(errors)

    assert approval.kind == Atom.to_string(Erp.JournalEntry) <> ":void"
    assert Ash.get!(Erp.JournalEntry, above.id, authorize?: false).status == :posted

    {:ok, pending} =
      Samen.Approvals.get(approval.approval_id,
        approval_resource: @approval_resource,
        repo: @repo
      )

    assert pending.state == :pending
    assert pending.requested_by == "member:#{org_id}"

    assert {:error, :self_approval} =
             Samen.Approvals.approve(approval.approval_id, "member:#{org_id}",
               approval_resource: @approval_resource,
               repo: @repo
             )

    assert {:ok, _decided, %{executed: "void"}} =
             Samen.Approvals.approve(approval.approval_id, "approver:#{org_id}",
               approval_resource: @approval_resource,
               repo: @repo
             )

    voided_above = Ash.get!(Erp.JournalEntry, above.id, authorize?: false)
    assert voided_above.status == :void
    assert voided_above.prepared_by == "member:#{org_id}"
    assert voided_above.approved_by == "approver:#{org_id}"
    assert voided_above.approval_id == approval.approval_id
    assert voided_above.approved_at
  end

  test "post boundary: one cent below skips approval, exactly at the threshold needs one" do
    org = create_org!("Kubeworkz Journal Approval Post Boundary")
    org_id = to_string(org.id)
    member = scope(org_id, "member", :member)

    Books.seed!(org_id)

    socket = open_settings_page(org_id)
    socket = save_policy(socket, "true", "50000")
    assert render_settings(socket) =~ "50000 cents ($500.00)"

    policy =
      Erp.JournalApprovalPolicy
      |> Ash.Query.filter(org_id == ^org_id)
      |> Ash.read_one!(authorize?: false)

    assert policy.enabled
    assert policy.threshold_cents == 50_000

    cash = account!(org_id, "1000")
    sales = account!(org_id, "4000")

    below = entry!(member, org_id, cash, sales, 49_999, "Post one cent below threshold")
    assert {:ok, posted_below} = post_entry(below, member)
    assert posted_below.status == :posted
    assert is_nil(posted_below.approval_id)

    at = entry!(member, org_id, cash, sales, 50_000, "Post exactly at threshold")

    assert {:error, %Ash.Error.Forbidden{errors: errors}} = post_entry(at, member)
    approval = approval_error!(errors)

    assert approval.kind == Atom.to_string(Erp.JournalEntry) <> ":post"
    assert Ash.get!(Erp.JournalEntry, at.id, authorize?: false).status == :draft

    {:ok, pending} =
      Samen.Approvals.get(approval.approval_id,
        approval_resource: @approval_resource,
        repo: @repo
      )

    assert pending.state == :pending
    assert pending.requested_by == "member:#{org_id}"

    assert {:error, :self_approval} =
             Samen.Approvals.approve(approval.approval_id, "member:#{org_id}",
               approval_resource: @approval_resource,
               repo: @repo
             )

    assert {:ok, _decided, %{executed: "post"}} =
             Samen.Approvals.approve(approval.approval_id, "approver:#{org_id}",
               approval_resource: @approval_resource,
               repo: @repo
             )

    posted_at = Ash.get!(Erp.JournalEntry, at.id, authorize?: false)
    assert posted_at.status == :posted
    assert posted_at.prepared_by == "member:#{org_id}"
    assert posted_at.approved_by == "approver:#{org_id}"
    assert posted_at.approval_id == approval.approval_id
    assert posted_at.approved_at
  end

  test "void boundary: one cent below skips approval, exactly at the threshold needs one" do
    org = create_org!("Kubeworkz Journal Approval Void Boundary")
    org_id = to_string(org.id)
    member = scope(org_id, "member", :member)

    Books.seed!(org_id)

    socket = open_settings_page(org_id)
    socket = save_policy(socket, "true", "50000")
    assert render_settings(socket) =~ "50000 cents ($500.00)"

    policy =
      Erp.JournalApprovalPolicy
      |> Ash.Query.filter(org_id == ^org_id)
      |> Ash.read_one!(authorize?: false)

    assert policy.enabled
    assert policy.threshold_cents == 50_000

    cash = account!(org_id, "1000")
    sales = account!(org_id, "4000")

    below = entry!(member, org_id, cash, sales, 49_999, "Void one cent below threshold")
    posted_below = post_system!(below)
    assert posted_below.status == :posted
    assert is_nil(posted_below.approval_id)

    assert {:ok, voided_below} = void_entry(posted_below, member)
    assert voided_below.status == :void
    assert is_nil(voided_below.approval_id)
    assert is_nil(voided_below.approved_by)

    at = entry!(member, org_id, cash, sales, 50_000, "Void exactly at threshold")
    posted_at = post_system!(at)
    assert posted_at.status == :posted

    assert {:error, %Ash.Error.Forbidden{errors: errors}} = void_entry(posted_at, member)
    approval = approval_error!(errors)

    assert approval.kind == Atom.to_string(Erp.JournalEntry) <> ":void"
    assert Ash.get!(Erp.JournalEntry, at.id, authorize?: false).status == :posted

    {:ok, pending} =
      Samen.Approvals.get(approval.approval_id,
        approval_resource: @approval_resource,
        repo: @repo
      )

    assert pending.state == :pending
    assert pending.requested_by == "member:#{org_id}"

    assert {:error, :self_approval} =
             Samen.Approvals.approve(approval.approval_id, "member:#{org_id}",
               approval_resource: @approval_resource,
               repo: @repo
             )

    assert {:ok, _decided, %{executed: "void"}} =
             Samen.Approvals.approve(approval.approval_id, "approver:#{org_id}",
               approval_resource: @approval_resource,
               repo: @repo
             )

    voided_at = Ash.get!(Erp.JournalEntry, at.id, authorize?: false)
    assert voided_at.status == :void
    assert voided_at.prepared_by == "member:#{org_id}"
    assert voided_at.approved_by == "approver:#{org_id}"
    assert voided_at.approval_id == approval.approval_id
    assert voided_at.approved_at
  end

  test "a system posting at or above the threshold still bypasses the approval queue" do
    org = create_org!("Kubeworkz Journal Approval System Posting")
    org_id = to_string(org.id)

    Books.seed!(org_id)

    socket = open_settings_page(org_id)
    socket = save_policy(socket, "true", "50000")
    assert render_settings(socket) =~ "50000 cents ($500.00)"

    policy =
      Erp.JournalApprovalPolicy
      |> Ash.Query.filter(org_id == ^org_id)
      |> Ash.read_one!(authorize?: false)

    assert policy.enabled
    assert policy.threshold_cents == 50_000

    cash = account!(org_id, "1000")
    sales = account!(org_id, "4000")

    # Exactly at the threshold and above it: the policy applies to HUMAN
    # submissions, and these have no preparer at all.
    for amount <- [50_000, 75_000] do
      entry = system_entry!(org_id, cash, sales, amount, "System posting #{amount}")
      assert is_nil(entry.prepared_by)

      posted = post_system!(entry)
      assert posted.status == :posted
      assert posted.posted_at
      assert is_nil(posted.prepared_by)
      assert is_nil(posted.approved_by)
      assert is_nil(posted.approved_at)
      assert is_nil(posted.approval_id)
    end
  end

  test "disabling the policy through the settings page releases a formerly gated posting" do
    org = create_org!("Kubeworkz Journal Approval Disable")
    org_id = to_string(org.id)
    member = scope(org_id, "member", :member)

    Books.seed!(org_id)

    socket = open_settings_page(org_id)
    socket = save_policy(socket, "true", "50000")
    assert render_settings(socket) =~ "50000 cents ($500.00)"

    cash = account!(org_id, "1000")
    sales = account!(org_id, "4000")

    entry = entry!(member, org_id, cash, sales, 75_000, "Gated until the policy is disabled")

    assert {:error, %Ash.Error.Forbidden{errors: errors}} = post_entry(entry, member)
    approval = approval_error!(errors)

    assert approval.kind == Atom.to_string(Erp.JournalEntry) <> ":post"
    assert Ash.get!(Erp.JournalEntry, entry.id, authorize?: false).status == :draft

    socket = save_policy(socket, "false", "50000")
    html = render_settings(socket)
    assert html =~ "Disabled"
    assert html =~ "50000 cents ($500.00)"
    assert html =~ ~s(id="policy-saved")
    refute html =~ ~s(id="policy-error")

    policy =
      Erp.JournalApprovalPolicy
      |> Ash.Query.filter(org_id == ^org_id)
      |> Ash.read_one!(authorize?: false)

    refute policy.enabled
    assert policy.threshold_cents == 50_000

    assert {:ok, posted} = post_entry(entry, member)
    assert posted.status == :posted
    assert posted.posted_at
    assert posted.prepared_by == "member:#{org_id}"
    assert is_nil(posted.approved_by)
    assert is_nil(posted.approved_at)
    assert is_nil(posted.approval_id)
  end

  test "re-enabling the policy through the settings page gates subsequent manual postings" do
    org = create_org!("Kubeworkz Journal Approval Re-enable")
    org_id = to_string(org.id)
    member = scope(org_id, "member", :member)

    Books.seed!(org_id)

    socket = open_settings_page(org_id)
    socket = save_policy(socket, "true", "50000")
    assert render_settings(socket) =~ "50000 cents ($500.00)"

    socket = save_policy(socket, "false", "50000")
    html = render_settings(socket)
    assert html =~ "Disabled"
    assert html =~ "50000 cents ($500.00)"

    cash = account!(org_id, "1000")
    sales = account!(org_id, "4000")

    while_disabled = entry!(member, org_id, cash, sales, 75_000, "Posts while disabled")
    assert {:ok, posted_while_disabled} = post_entry(while_disabled, member)
    assert posted_while_disabled.status == :posted
    assert is_nil(posted_while_disabled.approval_id)

    socket = save_policy(socket, "true", "50000")
    html = render_settings(socket)
    assert html =~ "Enabled"
    assert html =~ "50000 cents ($500.00)"
    assert html =~ ~s(id="policy-saved")
    refute html =~ ~s(id="policy-error")

    policy =
      Erp.JournalApprovalPolicy
      |> Ash.Query.filter(org_id == ^org_id)
      |> Ash.read_one!(authorize?: false)

    assert policy.enabled
    assert policy.threshold_cents == 50_000

    while_enabled = entry!(member, org_id, cash, sales, 75_000, "Gated after re-enable")

    assert {:error, %Ash.Error.Forbidden{errors: errors}} = post_entry(while_enabled, member)
    approval = approval_error!(errors)

    assert approval.kind == Atom.to_string(Erp.JournalEntry) <> ":post"
    assert Ash.get!(Erp.JournalEntry, while_enabled.id, authorize?: false).status == :draft

    {:ok, pending} =
      Samen.Approvals.get(approval.approval_id,
        approval_resource: @approval_resource,
        repo: @repo
      )

    assert pending.state == :pending
    assert pending.requested_by == "member:#{org_id}"
    assert pending.subject_ref == "samen:ecj:#{while_enabled.id}"
  end

  test "a rejected gated posting stays draft and can be resubmitted" do
    org = create_org!("Kubeworkz Journal Approval Rejection")
    org_id = to_string(org.id)
    member = scope(org_id, "member", :member)

    Books.seed!(org_id)

    socket = open_settings_page(org_id)
    socket = save_policy(socket, "true", "50000")
    assert render_settings(socket) =~ "50000 cents ($500.00)"

    cash = account!(org_id, "1000")
    sales = account!(org_id, "4000")

    entry = entry!(member, org_id, cash, sales, 75_000, "Rejected then resubmitted")

    assert {:error, %Ash.Error.Forbidden{errors: errors}} = post_entry(entry, member)
    approval = approval_error!(errors)

    assert approval.kind == Atom.to_string(Erp.JournalEntry) <> ":post"
    assert Ash.get!(Erp.JournalEntry, entry.id, authorize?: false).status == :draft

    {:ok, pending} =
      Samen.Approvals.get(approval.approval_id,
        approval_resource: @approval_resource,
        repo: @repo
      )

    assert pending.state == :pending
    assert pending.requested_by == "member:#{org_id}"

    assert {:ok, rejected} =
             Samen.Approvals.reject(approval.approval_id, "approver:#{org_id}",
               approval_resource: @approval_resource,
               repo: @repo
             )

    assert rejected.state == :rejected
    assert rejected.decided_by == "approver:#{org_id}"

    draft = Ash.get!(Erp.JournalEntry, entry.id, authorize?: false)
    assert draft.status == :draft
    assert is_nil(draft.approved_by)
    assert is_nil(draft.approved_at)
    assert is_nil(draft.approval_id)

    assert {:error, %Ash.Error.Forbidden{errors: resubmit_errors}} = post_entry(entry, member)
    resubmitted = approval_error!(resubmit_errors)

    assert resubmitted.kind == Atom.to_string(Erp.JournalEntry) <> ":post"
    assert resubmitted.approval_id != approval.approval_id
    assert Ash.get!(Erp.JournalEntry, entry.id, authorize?: false).status == :draft

    {:ok, pending_again} =
      Samen.Approvals.get(resubmitted.approval_id,
        approval_resource: @approval_resource,
        repo: @repo
      )

    assert pending_again.state == :pending
    assert pending_again.requested_by == "member:#{org_id}"
    assert pending_again.subject_ref == "samen:ecj:#{entry.id}"

    assert {:ok, _decided, %{executed: "post"}} =
             Samen.Approvals.approve(resubmitted.approval_id, "approver:#{org_id}",
               approval_resource: @approval_resource,
               repo: @repo
             )

    posted = Ash.get!(Erp.JournalEntry, entry.id, authorize?: false)
    assert posted.status == :posted
    assert posted.prepared_by == "member:#{org_id}"
    assert posted.approved_by == "approver:#{org_id}"
    assert posted.approval_id == resubmitted.approval_id
    assert posted.approved_at
  end

  test "a rejected gated void stays posted and can be resubmitted" do
    org = create_org!("Kubeworkz Journal Approval Void Rejection")
    org_id = to_string(org.id)
    member = scope(org_id, "member", :member)

    Books.seed!(org_id)

    socket = open_settings_page(org_id)
    socket = save_policy(socket, "true", "50000")
    assert render_settings(socket) =~ "50000 cents ($500.00)"

    cash = account!(org_id, "1000")
    sales = account!(org_id, "4000")

    entry = entry!(member, org_id, cash, sales, 75_000, "Void rejected then resubmitted")
    posted = post_system!(entry)
    assert posted.status == :posted

    assert {:error, %Ash.Error.Forbidden{errors: errors}} = void_entry(posted, member)
    approval = approval_error!(errors)

    assert approval.kind == Atom.to_string(Erp.JournalEntry) <> ":void"
    assert Ash.get!(Erp.JournalEntry, entry.id, authorize?: false).status == :posted

    {:ok, pending} =
      Samen.Approvals.get(approval.approval_id,
        approval_resource: @approval_resource,
        repo: @repo
      )

    assert pending.state == :pending
    assert pending.requested_by == "member:#{org_id}"

    assert {:ok, rejected} =
             Samen.Approvals.reject(approval.approval_id, "approver:#{org_id}",
               approval_resource: @approval_resource,
               repo: @repo
             )

    assert rejected.state == :rejected
    assert rejected.decided_by == "approver:#{org_id}"

    still_posted = Ash.get!(Erp.JournalEntry, entry.id, authorize?: false)
    assert still_posted.status == :posted
    assert is_nil(still_posted.approved_by)
    assert is_nil(still_posted.approved_at)
    assert is_nil(still_posted.approval_id)

    assert {:error, %Ash.Error.Forbidden{errors: resubmit_errors}} =
             void_entry(still_posted, member)

    resubmitted = approval_error!(resubmit_errors)

    assert resubmitted.kind == Atom.to_string(Erp.JournalEntry) <> ":void"
    assert resubmitted.approval_id != approval.approval_id
    assert Ash.get!(Erp.JournalEntry, entry.id, authorize?: false).status == :posted

    {:ok, pending_again} =
      Samen.Approvals.get(resubmitted.approval_id,
        approval_resource: @approval_resource,
        repo: @repo
      )

    assert pending_again.state == :pending
    assert pending_again.requested_by == "member:#{org_id}"
    assert pending_again.subject_ref == "samen:ecj:#{entry.id}"

    assert {:ok, _decided, %{executed: "void"}} =
             Samen.Approvals.approve(resubmitted.approval_id, "approver:#{org_id}",
               approval_resource: @approval_resource,
               repo: @repo
             )

    voided = Ash.get!(Erp.JournalEntry, entry.id, authorize?: false)
    assert voided.status == :void
    assert voided.prepared_by == "member:#{org_id}"
    assert voided.approved_by == "approver:#{org_id}"
    assert voided.approval_id == resubmitted.approval_id
    assert voided.approved_at
  end

  test "a cancelled pending posting stays draft and can be resubmitted" do
    org = create_org!("Kubeworkz Journal Approval Cancellation")
    org_id = to_string(org.id)
    member = scope(org_id, "member", :member)

    Books.seed!(org_id)

    socket = open_settings_page(org_id)
    socket = save_policy(socket, "true", "50000")
    assert render_settings(socket) =~ "50000 cents ($500.00)"

    cash = account!(org_id, "1000")
    sales = account!(org_id, "4000")

    entry = entry!(member, org_id, cash, sales, 75_000, "Cancelled then resubmitted")

    assert {:error, %Ash.Error.Forbidden{errors: errors}} = post_entry(entry, member)
    approval = approval_error!(errors)

    assert approval.kind == Atom.to_string(Erp.JournalEntry) <> ":post"
    assert Ash.get!(Erp.JournalEntry, entry.id, authorize?: false).status == :draft

    {:ok, pending} =
      Samen.Approvals.get(approval.approval_id,
        approval_resource: @approval_resource,
        repo: @repo
      )

    assert pending.state == :pending
    assert pending.requested_by == "member:#{org_id}"

    assert {:ok, cancelled} =
             Samen.Approvals.cancel(approval.approval_id, "member:#{org_id}",
               approval_resource: @approval_resource,
               repo: @repo
             )

    assert cancelled.state == :cancelled
    assert is_nil(cancelled.decided_by)

    draft = Ash.get!(Erp.JournalEntry, entry.id, authorize?: false)
    assert draft.status == :draft
    assert is_nil(draft.approved_by)
    assert is_nil(draft.approved_at)
    assert is_nil(draft.approval_id)

    assert {:error, %Ash.Error.Forbidden{errors: resubmit_errors}} = post_entry(entry, member)
    resubmitted = approval_error!(resubmit_errors)

    assert resubmitted.kind == Atom.to_string(Erp.JournalEntry) <> ":post"
    assert resubmitted.approval_id != approval.approval_id
    assert Ash.get!(Erp.JournalEntry, entry.id, authorize?: false).status == :draft

    {:ok, pending_again} =
      Samen.Approvals.get(resubmitted.approval_id,
        approval_resource: @approval_resource,
        repo: @repo
      )

    assert pending_again.state == :pending
    assert pending_again.requested_by == "member:#{org_id}"
    assert pending_again.subject_ref == "samen:ecj:#{entry.id}"

    assert {:ok, _decided, %{executed: "post"}} =
             Samen.Approvals.approve(resubmitted.approval_id, "approver:#{org_id}",
               approval_resource: @approval_resource,
               repo: @repo
             )

    posted = Ash.get!(Erp.JournalEntry, entry.id, authorize?: false)
    assert posted.status == :posted
    assert posted.prepared_by == "member:#{org_id}"
    assert posted.approved_by == "approver:#{org_id}"
    assert posted.approval_id == resubmitted.approval_id
    assert posted.approved_at
  end

  test "a cancelled pending void stays posted and can be resubmitted" do
    org = create_org!("Kubeworkz Journal Approval Void Cancellation")
    org_id = to_string(org.id)
    member = scope(org_id, "member", :member)

    Books.seed!(org_id)

    socket = open_settings_page(org_id)
    socket = save_policy(socket, "true", "50000")
    assert render_settings(socket) =~ "50000 cents ($500.00)"

    cash = account!(org_id, "1000")
    sales = account!(org_id, "4000")

    entry = entry!(member, org_id, cash, sales, 75_000, "Void cancelled then resubmitted")
    posted = post_system!(entry)
    assert posted.status == :posted

    assert {:error, %Ash.Error.Forbidden{errors: errors}} = void_entry(posted, member)
    approval = approval_error!(errors)

    assert approval.kind == Atom.to_string(Erp.JournalEntry) <> ":void"
    assert Ash.get!(Erp.JournalEntry, entry.id, authorize?: false).status == :posted

    {:ok, pending} =
      Samen.Approvals.get(approval.approval_id,
        approval_resource: @approval_resource,
        repo: @repo
      )

    assert pending.state == :pending
    assert pending.requested_by == "member:#{org_id}"

    assert {:ok, cancelled} =
             Samen.Approvals.cancel(approval.approval_id, "member:#{org_id}",
               approval_resource: @approval_resource,
               repo: @repo
             )

    assert cancelled.state == :cancelled
    assert is_nil(cancelled.decided_by)

    still_posted = Ash.get!(Erp.JournalEntry, entry.id, authorize?: false)
    assert still_posted.status == :posted
    assert is_nil(still_posted.approved_by)
    assert is_nil(still_posted.approved_at)
    assert is_nil(still_posted.approval_id)

    assert {:error, %Ash.Error.Forbidden{errors: resubmit_errors}} =
             void_entry(still_posted, member)

    resubmitted = approval_error!(resubmit_errors)

    assert resubmitted.kind == Atom.to_string(Erp.JournalEntry) <> ":void"
    assert resubmitted.approval_id != approval.approval_id
    assert Ash.get!(Erp.JournalEntry, entry.id, authorize?: false).status == :posted

    {:ok, pending_again} =
      Samen.Approvals.get(resubmitted.approval_id,
        approval_resource: @approval_resource,
        repo: @repo
      )

    assert pending_again.state == :pending
    assert pending_again.requested_by == "member:#{org_id}"
    assert pending_again.subject_ref == "samen:ecj:#{entry.id}"

    assert {:ok, _decided, %{executed: "void"}} =
             Samen.Approvals.approve(resubmitted.approval_id, "approver:#{org_id}",
               approval_resource: @approval_resource,
               repo: @repo
             )

    voided = Ash.get!(Erp.JournalEntry, entry.id, authorize?: false)
    assert voided.status == :void
    assert voided.prepared_by == "member:#{org_id}"
    assert voided.approved_by == "approver:#{org_id}"
    assert voided.approval_id == resubmitted.approval_id
    assert voided.approved_at
  end

  test "a non-requester cannot cancel another preparer's pending posting" do
    org = create_org!("Kubeworkz Journal Approval Cancel Authorization")
    org_id = to_string(org.id)
    member = scope(org_id, "member", :member)

    Books.seed!(org_id)

    socket = open_settings_page(org_id)
    socket = save_policy(socket, "true", "50000")
    assert render_settings(socket) =~ "50000 cents ($500.00)"

    cash = account!(org_id, "1000")
    sales = account!(org_id, "4000")

    entry = entry!(member, org_id, cash, sales, 75_000, "Cancel authorization")

    assert {:error, %Ash.Error.Forbidden{errors: errors}} = post_entry(entry, member)
    approval = approval_error!(errors)

    assert approval.kind == Atom.to_string(Erp.JournalEntry) <> ":post"
    assert Ash.get!(Erp.JournalEntry, entry.id, authorize?: false).status == :draft

    {:ok, pending} =
      Samen.Approvals.get(approval.approval_id,
        approval_resource: @approval_resource,
        repo: @repo
      )

    assert pending.state == :pending
    assert pending.requested_by == "member:#{org_id}"

    assert {:error, :not_requester} =
             Samen.Approvals.cancel(approval.approval_id, "intruder:#{org_id}",
               approval_resource: @approval_resource,
               repo: @repo
             )

    {:ok, still_pending} =
      Samen.Approvals.get(approval.approval_id,
        approval_resource: @approval_resource,
        repo: @repo
      )

    assert still_pending.state == :pending
    assert still_pending.requested_by == "member:#{org_id}"
    assert is_nil(still_pending.decided_by)

    draft = Ash.get!(Erp.JournalEntry, entry.id, authorize?: false)
    assert draft.status == :draft
    assert is_nil(draft.approved_by)
    assert is_nil(draft.approved_at)
    assert is_nil(draft.approval_id)

    assert {:ok, cancelled} =
             Samen.Approvals.cancel(approval.approval_id, "member:#{org_id}",
               approval_resource: @approval_resource,
               repo: @repo
             )

    assert cancelled.state == :cancelled
    assert is_nil(cancelled.decided_by)
    assert Ash.get!(Erp.JournalEntry, entry.id, authorize?: false).status == :draft
  end

  test "a re-seed keeps the policy and reports an operator's disable as drift" do
    org = create_org!("Kubeworkz Journal Approval Drift")
    org_id = to_string(org.id)

    assert Books.seed!(org_id).journal_approval.created
    policy = Books.seed!(org_id).journal_approval
    refute policy.created
    assert policy.drifted == []

    existing =
      Erp.JournalApprovalPolicy
      |> Ash.Query.filter(org_id == ^org_id)
      |> Ash.read_one!(authorize?: false)

    existing
    |> Ash.Changeset.for_update(:update, %{enabled: false}, authorize?: false)
    |> Ash.update!(authorize?: false)

    drift = Books.seed!(org_id).journal_approval
    refute drift.created
    refute drift.enabled
    assert Enum.any?(drift.drifted, &String.contains?(&1, "enabled"))

    assert {:error, gaps} = Books.verify(org_id)
    assert Enum.any?(gaps, &String.contains?(&1, "journal approval policy"))
  end
end
