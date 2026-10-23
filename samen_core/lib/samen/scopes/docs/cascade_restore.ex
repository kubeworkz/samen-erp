defmodule Samen.Scopes.Docs.CascadeRestore do
  @moduledoc """
  Restore-side half of the **page tree** cascade (WS-Notes Phase 3 unit 3.13), and the guard that
  keeps the tree's one structural invariant true from the other direction: **a page is live iff its
  ancestors are live.**

  `Samen.Scopes.Docs.CascadeArchive` maintains it going down (deleting a page retires its subtree);
  this change maintains it going up:

    * **the pages that went down WITH this one come back with it** — `Tree.archived_children/3`
      matches on `archived_at == the page's own instant` (ADR-040 §5.4's same-instant contract), so
      restoring a parent restores its subtree, while a subpage somebody deleted on its own — at its
      own instant, before or after — stays in the trash. Undo restores what the action removed, not
      every deletion that happened nearby.
    * **a page cannot come back under a parent that is still deleted** — `refuse_trashed_parent/1`
      refuses the restore (`:parent_doc_id`), because restoring one subpage out from under a trashed
      parent would re-create exactly the orphan the cascade exists to prevent: a live row nobody can
      navigate to, whose ancestor is invisible to every read.

  ash_archival ships no restore-cascade primitive, and the DSL's `on:` option only discriminates by
  action TYPE (`:update` covers both `:restore` and the plain `:update`), so both hooks are guarded on
  `changeset.action.name`.

  ## How the walk recurses

  One level here, like the archive side: each restored child's own `:restore` runs this change too,
  matching ITS children against the same instant — so the instant travels down the whole subtree
  without a hand-rolled recursive query.

  Runs inside the `:restore` action's transaction; `authorize?: false` on the child writes is the
  system-level cascade posture (the parent restore was already authorized, the actor still rides
  along so each child's `record_restored` row names them).
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    actor = acting_actor(changeset)

    changeset
    |> Ash.Changeset.before_action(&refuse_trashed_parent/1)
    |> Ash.Changeset.after_action(fn cs, record ->
      if cs.action.name == :restore do
        case restore_children(cs, record, actor) do
          :ok -> {:ok, record}
          {:error, error} -> {:error, error}
        end
      else
        {:ok, record}
      end
    end)
  end

  # `on:` here is the default (`[:create, :update]`), so this change is attached to EVERY update
  # action — including the atomic ones. It contributes nothing to a plain update (the name guard
  # skips it, and a plain update does not clear `archived_at`), so `:ok` keeps those actions
  # atomic; `:restore` itself is `require_atomic?(false)` and always runs through `change/3`.
  @impl true
  def atomic(_changeset, _opts, _context), do: :ok

  # The instant the page itself was deleted at — captured from the ORIGINAL row, because the restore
  # has already cleared `archived_at` in the changeset by the time `after_action` runs.
  defp restore_children(cs, record, actor) do
    case Ash.Changeset.get_data(cs, :archived_at) do
      %DateTime{} = instant ->
        with {:ok, children} <-
               Samen.Scopes.Docs.Tree.archived_children(cs.resource, record.id, instant) do
          Enum.reduce_while(children, :ok, fn child, :ok ->
            case Samen.Archival.restore(child, authorize?: false, actor: actor) do
              {:ok, _restored} -> {:cont, :ok}
              {:error, error} -> {:halt, {:error, error}}
            end
          end)
        end

      # An idempotent restore (already live) has no instant to match on and nothing to bring back.
      _ ->
        :ok
    end
  end

  # The orphan guard. Refusing here — in the model — is what makes the invariant hold for a caller
  # the surface has not been written for yet; `Writes.restore_page/3` asks the same question early so
  # the trash can render an atom instead of an Ash changeset error.
  defp refuse_trashed_parent(changeset) do
    cond do
      changeset.action.name != :restore ->
        changeset

      live_parent?(changeset) ->
        changeset

      true ->
        Ash.Changeset.add_error(changeset,
          field: :parent_doc_id,
          message:
            "restore the parent page first — a page cannot come back under a parent that is still " <>
              "deleted (or was deleted permanently)"
        )
    end
  end

  defp live_parent?(changeset) do
    case Ash.Changeset.get_data(changeset, :id) do
      nil ->
        true

      id ->
        Samen.Scopes.Docs.Tree.live_parent?(changeset.resource, id)
    end
  end

  defp acting_actor(changeset) do
    case get_in(changeset.context, [:private, :actor]) do
      %{} = actor -> actor
      _ -> nil
    end
  end
end
