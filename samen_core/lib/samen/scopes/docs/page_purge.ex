defmodule Samen.Scopes.Docs.PagePurge do
  @moduledoc """
  The **terminal** delete of a page (WS-Notes Phase 3 unit 3.11) — "delete forever", from the trash.

  `Samen.Archival`'s `:destroy_permanently` is the substrate's hard delete, but it saves nothing to
  the governance trail: archive and restore each write their event (`Samen.Archival.Archive`,
  `Samen.Archival.Restore`) while the terminal destroy is silent. A page's content — including the
  vaulted half a tenant classified — is exactly the thing a trail must be able to say was
  *destroyed*, and by whom. So a page's purge is its own governed action, `Doc.:purge`
  (admin-only, see the blueprint), with this change on it.

  ## Two guarantees, both in the model

    1. **Archive first, fail-closed.** Purging a LIVE page is refused (`field: :archived_at`), as is
       a purge whose archival state cannot be SEEN (`%Ash.NotLoaded{}`): a hard delete can only be
       sanctioned by the soft delete that preceded it. Without that rule a crafted `:purge` would
       wipe content with no trash stop and no `record_archived` row, and "the trash can undo it"
       would be a lie for precisely the pages that are gone. The surface (`TrashLive`) reaches this
       through `Writes.purge_page/3`, which reads the page out of the `:archived` read — it cannot
       see a live page at all — and this guard is the layer beneath that, so the invariant holds for
       every governed write including one nobody has written yet.
    2. **Audit, in-transaction.** `record_purged` is written through `Samen.Archival.Audit.write/3`
       from `after_action`, i.e. inside the action's own transaction, so a purge that cannot record
       itself does not commit.

  ## What this action does NOT do — and where that lives

  Two things a terminal delete must also take are deliberately NOT here, because they are not this
  action's subject: the page's **blocks** (the seam destroys them, `Writes.purge_one/3`, in the same
  transaction) and the page's **trashed subtree** (the same seam, `Samen.Scopes.Docs.Tree`, since a
  page is live iff its ancestors are live — ADR-053 §3.4). The split is the same one the archive
  side already has: this change owns the GUARD and the ROW, the write seam owns the CONTENT, and a
  caller reaching `:purge` directly gets exactly the refusal/rules the model states and nothing
  more.

  ## PII posture (INV-1)

  `detail` is `resource=<Module> action=<name>` — enum/id-only, `PiiReasonScan`-gated at the chain
  boundary exactly like its archive/restore siblings, so the row can never carry a title, a block's
  text, or a `vt_*` token. The `subject_id` is the page's opaque id. Like `record_archived` /
  `record_restored` this event is NOT in the operator activity feed's org-linkable set
  (`Samen.Web.Operator.ActivityReads` states why): `correlation_id` is unset, and empty-the-trash is
  a tenant-plane action whose record lives in the tenant's own trail.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    case archived_state(changeset) do
      :archived ->
        Ash.Changeset.after_action(changeset, fn cs, record ->
          Samen.Archival.Audit.write(cs, record, "record_purged")
          {:ok, record}
        end)

      :live ->
        refuse(
          changeset,
          "a live page cannot be deleted permanently. Delete it first (it goes to the trash, where " <>
            "every member can restore it), then empty it from the trash."
        )

      :unknown ->
        refuse(
          changeset,
          "a permanent delete must follow a soft delete, and this write cannot see whether it does " <>
            "(`archived_at` was not loaded). Read the page through the `:archived` read."
        )
    end
  end

  # `nil` is a LIVE row; a real instant is the archived one; `%Ash.NotLoaded{}` (or a changeset with
  # no original data) is unknown and fails CLOSED — a hard delete that cannot be PROVEN to follow a
  # soft delete is refused rather than taken on trust.
  defp archived_state(changeset) do
    case Ash.Changeset.fetch_data(changeset, :archived_at) do
      {:ok, nil} -> :live
      {:ok, %Ash.NotLoaded{}} -> :unknown
      {:ok, %DateTime{}} -> :archived
      {:ok, _other} -> :archived
      :error -> :unknown
    end
  end

  defp refuse(changeset, message) do
    Ash.Changeset.add_error(changeset, field: :archived_at, message: message)
  end
end
