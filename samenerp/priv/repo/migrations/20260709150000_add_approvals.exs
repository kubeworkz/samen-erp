defmodule Samenerp.Repo.Migrations.AddApprovals do
  @moduledoc """
  T35 §4.7 / T37h — materializes the T34 E3 `Approval` resource
  (`Samen.Approvals.Blueprint`) on this app's own repo: `erz_approval`,
  abbrev `erz` (allocator-reserved).

  This app is `Samen.Reveal.Grants`' engine client for the `"pii_reveal"` kind
  (`Samen.Reveal.ApprovalHandler`; registered in `config/config.exs`) — this is the
  table `Grants.approve/2` now writes through via `Samen.Approvals`, closing the T35
  non-fatal note (a generated app's reveal-approve previously took the fail-safe
  INLINE path, never the T34 engine, because no `pii_reveal` approvals module was
  wired). Shape mirrors `demo/priv/repo/migrations/20260728180000_add_approvals.exs`
  (the T35 in-tree reference) — no AshOban expiry-scan index (this resource carries
  no `:expire` action — see `Samen.Approvals.Blueprint` moduledoc for why).
  """
  use Samen.Migration

  @resources [Samenerp.Approvals.Approval]

  def up do
    create table(:erz_approval, primary_key: false) do
      # NULL = plane-global governance approval (reveal); non-NULL = tenant-plane (§4.1).
      add(:erz_org_id, :uuid)
      add(:erz_kind, :text, null: false)
      add(:erz_subject_ref, :text, null: false)
      add(:erz_requested_by, :text, null: false)
      add(:erz_decided_by, :text)
      add(:erz_reason, :text)
      add(:erz_deadline_at, :utc_datetime_usec)
      add(:erz_requested_at, :utc_datetime_usec)
      add(:erz_decided_at, :utc_datetime_usec)
      add(:erz_state, :text, null: false, default: "pending")
      add(:erz_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:erz_inserted_at, :utc_datetime, null: false)
      add(:erz_updated_at, :utc_datetime, null: false)
    end

    # Distinct-party DB CHECK — the rvg_distinct_party twin (§4.2 layer 2), carrying the
    # T34-F1 tightening: a DECIDED row (approved | rejected) MUST carry a non-NULL approver.
    create(
      constraint(:erz_approval, :erz_distinct_party,
        check: """
        (erz_decided_by IS NULL OR erz_decided_by <> erz_requested_by)
        AND (erz_state NOT IN ('approved', 'rejected') OR erz_decided_by IS NOT NULL)
        """
      )
    )

    create(
      unique_index(:erz_approval, [:erz_org_id, :erz_kind, :erz_subject_ref],
        where: "erz_state = 'pending' AND erz_org_id IS NOT NULL",
        name: "erz_approval_pending_tenant_idx"
      )
    )

    create(
      unique_index(:erz_approval, [:erz_kind, :erz_subject_ref],
        where: "erz_state = 'pending' AND erz_org_id IS NULL",
        name: "erz_approval_pending_global_idx"
      )
    )

    create(index(:erz_approval, [:erz_org_id], name: "erz_approval_org_idx"))

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    drop(index(:erz_approval, [:erz_org_id], name: "erz_approval_org_idx"))

    drop(
      unique_index(:erz_approval, [:erz_kind, :erz_subject_ref],
        name: "erz_approval_pending_global_idx"
      )
    )

    drop(
      unique_index(:erz_approval, [:erz_org_id, :erz_kind, :erz_subject_ref],
        name: "erz_approval_pending_tenant_idx"
      )
    )

    drop(constraint(:erz_approval, :erz_distinct_party))
    drop(table(:erz_approval))
  end
end
