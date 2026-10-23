defmodule Samen.Scopes.Docs.Tree do
  @moduledoc """
  The page tree's **structural reads** (WS-Notes Phase 3 unit 3.13) — the one place the questions a
  delete / restore / purge cascade asks are answered:

    * **who is under this page?** — `subtree/2` (the live AND trashed set below a page, in
      breadth-first order, a parent always before its children) and `live_children/2` (one level,
      live only — what `CascadeArchive` walks, letting each child's own `:archive` carry the walk
      downward);
    * **is the page's parent still live?** — `parent_live?/2` and `live_parent?/2`, the guard that
      keeps a restored page from reappearing under a parent that is still in the trash.

  ## Why a module and not four inline queries

  The cascade lives in the MODEL (`Samen.Scopes.Docs.CascadeArchive` / `CascadeRestore`) and the
  purge/report walk lives in the surface seam (`Samen.Web.Notes.Writes`). If each spelled the filter
  itself, "the subtree" would mean two slightly different sets of rows — and the bug this unit
  closes is exactly a delete that reached one set and not the other. One definition, both callers.

  ## Scope posture

  Every read runs `authorize?: false`, the posture every cascade in this foundry uses
  (`Chat.CascadeArchive`, `Work.CascadeRestore`): these are FK-pinned structural walks that follow an
  ALREADY-AUTHORIZED write on the root page, they return opaque ids/timestamps and never content, and
  the `org_id` half is already guaranteed by `Samen.Policy.SameOrgFk` on `parent_doc_id`.

  ## Termination — and why there is no depth cap

  The archive side (`live_children/2`) returns LIVE rows only, so every step retires at least one row
  and the walk is bounded by the number of live pages under the root. A cap that TRUNCATED the walk
  would leave behind exactly the orphans this module exists to prevent, so none is applied. A
  corrupted cycle also terminates for the same reason (a row is archived before its children are
  read); no surface re-parents a page today, so no cycle is reachable at all.
  """

  require Ash.Query

  # Ids and metadata only: a cascade and a purge never read a title, a body or a `vt_*` token.
  @select [:id, :parent_doc_id, :revision, :archived_at]

  @doc """
  The pages below `root_id`, at ANY depth, split by archival state:
  `%{live: [...], archived: [...]}` in breadth-first order.

  `root_id` itself is not part of either list — the caller already holds it (that is what it was
  authorized against), and the cascade's question is what goes down WITH it.
  """
  @spec subtree(module(), term()) ::
          {:ok, %{live: [struct()], archived: [struct()]}} | {:error, term()}
  def subtree(resource, root_id) do
    walk(resource, [root_id], [], [], MapSet.new([root_id]))
  end

  @doc """
  The LIVE pages directly under `parent_id` — the one-level step `CascadeArchive` recurses on.

  A read failure is returned, never swallowed: an archive that cannot SEE its children would leave
  them live under a trashed parent (the orphan this cascade exists to prevent), so the caller lets
  the error roll its transaction back instead of archiving the parent alone.
  """
  @spec live_children(module(), term()) :: {:ok, [struct()]} | {:error, term()}
  def live_children(resource, parent_id), do: read(resource, [parent_id], :live)

  @doc """
  The TRASHED pages directly under `parent_id` whose `archived_at` is exactly `instant`.

  That equality is the whole restore contract (ADR-040 §5.4): a page that went down WITH its parent
  — `CascadeArchive` stamps one instant on the whole subtree — comes back with it, while a page
  somebody deleted on its own, at its own instant, stays in the trash.
  """
  @spec archived_children(module(), term(), DateTime.t()) ::
          {:ok, [struct()]} | {:error, term()}
  def archived_children(resource, parent_id, %DateTime{} = instant) do
    resource
    |> Ash.Query.for_read(:archived)
    |> Ash.Query.filter(parent_doc_id == ^parent_id and archived_at == ^instant)
    |> Ash.Query.ensure_selected(@select)
    # authz-scope: FK-pinned cascade read — the trashed children of ONE already-authorized page,
    # inside that page's own restore; ids/timestamps only, never content.
    |> Ash.read(authorize?: false)
  end

  @doc """
  Whether `parent_id` names a LIVE page — the orphan guard, answered about an id alone.

  `nil` (a root page) is always live: nothing above it can be missing. An id that resolves to
  nothing is NOT live (`false`): a page whose parent was purged would otherwise be restored into a
  tree with a hole where its ancestor was, which is the same orphan by another route.
  """
  @spec parent_live?(module(), term()) :: boolean()
  def parent_live?(_resource, nil), do: true

  def parent_live?(resource, parent_id) do
    resource
    |> Ash.Query.filter(id == ^parent_id)
    |> Ash.Query.limit(1)
    |> Ash.read(authorize?: false)
    |> case do
      {:ok, [_]} -> true
      _ -> false
    end
  end

  @doc """
  Whether the ARCHIVED page `record_id` has a live parent — the question
  `Samen.Scopes.Docs.CascadeRestore` asks before it clears `archived_at`.

  It reads the page's own `parent_doc_id` back out of the trash rather than off the changeset, so
  the answer does not depend on the caller having selected that column (the `PagePurge` precedent:
  a guard that cannot see its input must not guess).
  """
  @spec live_parent?(module(), term()) :: boolean()
  def live_parent?(resource, record_id) do
    case archived_row(resource, record_id) do
      {:ok, %{parent_doc_id: nil}} -> true
      {:ok, %{parent_doc_id: parent_id}} -> parent_live?(resource, parent_id)
      # Not in the trash at all: a restore of an already-live page is the idempotent no-op the
      # `Archival.Restore` change owns, so there is no parent to ask about.
      _ -> true
    end
  end

  # ── internals ─────────────────────────────────────────────────────────────

  defp walk(_resource, [], live, archived, _seen), do: {:ok, %{live: live, archived: archived}}

  defp walk(resource, frontier, live, archived, seen) do
    with {:ok, live_rows} <- read(resource, frontier, :live),
         {:ok, archived_rows} <- read(resource, frontier, :archived) do
      fresh = Enum.reject(live_rows ++ archived_rows, &MapSet.member?(seen, &1.id))

      seen = Enum.reduce(fresh, seen, &MapSet.put(&2, &1.id))

      walk(
        resource,
        Enum.map(fresh, & &1.id),
        live ++ Enum.filter(fresh, &live?/1),
        archived ++ Enum.reject(fresh, &live?/1),
        seen
      )
    end
  end

  defp live?(%{archived_at: nil}), do: true
  defp live?(_row), do: false

  # One level of children, in ONE read per archival state: the default read is live-only
  # (`ExcludeArchived`), the `:archived` read is its exact complement (`OnlyArchived`).
  defp read(resource, parent_ids, :live) do
    resource
    |> Ash.Query.filter(parent_doc_id in ^parent_ids)
    |> Ash.Query.ensure_selected(@select)
    # authz-scope: FK-pinned subtree walk — one level of children below an ALREADY-authorized
    # page, inside that page's own archive write; ids/timestamps only, never content.
    |> Ash.read(authorize?: false)
  end

  defp read(resource, parent_ids, :archived) do
    resource
    |> Ash.Query.for_read(:archived)
    |> Ash.Query.filter(parent_doc_id in ^parent_ids)
    |> Ash.Query.ensure_selected(@select)
    # authz-scope: FK-pinned subtree walk (the trashed half) — children of an ALREADY-authorized
    # page, inside that page's own purge/restore; ids/timestamps only, never content.
    |> Ash.read(authorize?: false)
  end

  defp archived_row(resource, id) do
    resource
    |> Ash.Query.for_read(:archived)
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.ensure_selected([:id, :parent_doc_id])
    |> Ash.Query.limit(1)
    |> Ash.read(authorize?: false)
    |> case do
      {:ok, [row | _]} -> {:ok, row}
      _ -> :error
    end
  end
end
