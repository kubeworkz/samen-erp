defmodule Samen.Scopes.Docs.CascadeArchive do
  @moduledoc """
  Archive-side half of the **page tree** cascade (WS-Notes Phase 3 unit 3.13): deleting a page takes
  its subpages with it, and they all go at the SAME instant.

  ## Why the cascade is needed at all

  A page's blocks are deliberately NOT archived with it (ADR-053 §3.1), but its CHILDREN are pages in
  their own right, and `parent_doc_id` is what puts them in the tree. Deleting only the parent leaves
  every child live, pointing at a row nothing can read — an orphan: it cannot be navigated to from
  its ancestor, and the default read hides the parent that gave it its place. Restoring the parent
  later would also "discover" children the user never got back in one action.

  So the liveness of a subtree is a single fact: **a page is live iff its ancestors are live**. This
  change is the half that maintains it going down.

  ## Why not ash_archival's `archive_related`

  The same two gaps `Samen.Scopes.Chat.CascadeArchive` documents in full, and this tree needs both:

    1. **Timestamp exactness.** `archive_related` archives each child with its own clock read, so a
       restore cannot tell "went down with the parent" from "was deleted on its own" — this cascade
       stamps the PARENT's instant on every descendant (`force_change_attribute/3`), which is what
       `CascadeRestore` matches on (ADR-040 §5.4's same-instant contract).
    2. **Audit completeness.** `archive_related` invokes each child's PRIMARY destroy action, which
       would skip `record_archived` — the event that answers "who deleted this page" for the child.
       Each child is destroyed through its own governed `:archive` action instead, so a cascade of
       five pages leaves five governance rows, each naming the same actor: the person who clicked.

  ## How the walk recurses

  One level here: the live children of the page being archived become archives of their own, and each
  of THOSE runs this change too. Because a child is force-stamped with the parent's instant before it
  commits, the instant propagates unchanged all the way down the subtree.

  ## Failure posture

  A children read that fails aborts the action, which rolls the parent's archive back: an archive
  that cannot SEE its children must not proceed alone — that would be the orphan, shipped. A child
  archive that fails for any other reason fails the same way (one transaction).

  Runs inside the parent `:archive` action's transaction (nested Ash/Ecto transactions in one process
  reuse it). `authorize?: false` on the child writes is the system-level cascade posture every
  foundry cascade uses: the parent action was already authorized, the actor still rides along so the
  child's audit row names them.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    actor = acting_actor(changeset)

    Ash.Changeset.after_action(changeset, fn cs, record ->
      if cs.action.name == :archive do
        case archive_children(cs.resource, record, actor) do
          :ok -> {:ok, record}
          {:error, error} -> {:error, error}
        end
      else
        {:ok, record}
      end
    end)
  end

  # `on: [:destroy]` also reaches `:destroy_permanently` (a real hard delete), which IS
  # atomic-eligible. This change contributes nothing to it (the name guard skips it), so `:ok` keeps
  # that action atomic instead of making the whole resource's terminal delete lose eligibility — the
  # `Chat.CascadeArchive.atomic/3` posture. `:archive` itself is `require_atomic?(false)`
  # (`Samen.Resource`'s archival DSL), so the cascade always runs through `change/3`.
  @impl true
  def atomic(_changeset, _opts, _context), do: :ok

  defp archive_children(resource, %{archived_at: %DateTime{} = instant} = record, actor) do
    with {:ok, children} <- Samen.Scopes.Docs.Tree.live_children(resource, record.id) do
      Enum.reduce_while(children, :ok, fn child, :ok ->
        case archive_at(child, instant, actor) do
          {:ok, _archived} -> {:cont, :ok}
          {:error, error} -> {:halt, {:error, error}}
        end
      end)
    end
  end

  # No instant to propagate (the archive did not stamp one — should not happen) means no cascade:
  # archiving children at an invented instant would break the restore pairing.
  defp archive_children(_resource, _record, _actor), do: :ok

  # `return_destroyed?: true` because a destroy otherwise answers a bare `:ok`, and the caller needs
  # the persisted row (its audit hook has already run by then).
  defp archive_at(child, instant, actor) do
    child
    |> Ash.Changeset.for_destroy(:archive, %{}, authorize?: false, actor: actor)
    |> Ash.Changeset.force_change_attribute(:archived_at, instant)
    |> Ash.destroy(authorize?: false, return_destroyed?: true)
  end

  defp acting_actor(changeset) do
    case get_in(changeset.context, [:private, :actor]) do
      %{} = actor -> actor
      _ -> nil
    end
  end
end
