defmodule Samen.Web.Notes.Reads do
  @moduledoc """
  The **ONE read seam** for a WS-Notes page (ADR-053 §2 D5; WS-Notes Phase 2 unit 2.1).

  Every surface that renders a page — the editor, the tree, later the export and the search
  snippet — reads through this module. That is deliberate: there are exactly three decisions a
  page read has to make, and they are made here ONCE rather than in each renderer:

    1. **Which text is visible.** A block carries the `text` / `text_secure` pair (INV-1). The
       visible value is `text_secure` when the author wrote one, else `text`. This module resolves
       BOTH through `Samen.Api.PiiResolution` for the acting plane and picks the visible one — it
       never reads a vault field directly, never unwraps a `%Samen.Masked{}`, and has no
       "show plaintext" path (R5/R6).
    2. **Order.** Blocks are returned ordered by `(position, id)` within the page. `id` breaks a
       tie deterministically, so a transient duplicate ordinal never produces a random render
       order.
    3. **The legacy `body` fallback** (ADR-053 §8 O3): a doc with ZERO blocks renders its legacy
       `body`/`secure_body`; a doc with one block ignores them. That decision lives here, in one
       `legacy/2` clause — no renderer has to know which shape it is looking at.

  ## Masking (INV-1)

  Text resolution is `Samen.Api.PiiResolution.resolve/4` on the actor's plane, exactly as
  `Samen.Web.Files.Reads` does it:

    * **tenant plane** — the org reads its own page: `text_secure` resolves to the plaintext;
    * **operator plane (impersonation, no grant)** — `text_secure` resolves to `%Samen.Masked{}`
      (renders `••••`), never plaintext and never a `vt_*` token;
    * **unrecognised plane** — stays masked (fail-safe).

  `resolve/3` is wrapped in a `rescue` that returns the records unchanged, so a resolver failure
  degrades to "the field is still a `%Masked{}`" rather than a raise or a plaintext downgrade.

  ## What a caller gets

      {:ok, %{doc: doc, blocks: [block], legacy: nil | %{text: text, secure?: boolean}}}
      {:error, :not_found}

  `doc` is the `Doc` record with `body`/`secure_body` plane-resolved. Each returned block is a
  plain map (not the Ash struct): `:id`, `:doc_id`, `:parent_block_id`, `:position`, `:type`,
  `:checked`, `:metadata`, `:revision`, `:text` (the resolved visible value), `:secure?` and
  `:masked?`. `:text` may be a `%Samen.Masked{}` on a masked plane — that is the point: a caller
  that stringifies it gets `••••`, and no caller can accidentally render a token.

  `{:error, :not_found}` covers both "no such page" and "another org's page": `OrgScope` filters
  the row out of the read rather than returning a forbidden error, so this seam is not an
  existence oracle (R1).
  """

  require Ash.Query

  alias Samen.Web.{CurrentOrg, Mount}

  # AC-G1-5 (A3 read-bounding): a page's block list is a SINGLE-PARENT fan-out, so it carries
  # an explicit limit instead of being paginated — the chat reads' `@detail_limit` idiom. This is
  # a DoS / row-transfer bound, not a UI page size: 2,000 blocks is far past a document someone
  # edits in one page, and hitting it is a signal to split the page (M2 nesting), not to stream
  # an unbounded result set into a render.
  @block_limit 2_000

  # The governance event `Samen.Archival.Archive` writes on the live → archived transition. The
  # trash reads it back to answer "who deleted this" (see `trash/2`).
  @delete_event "record_archived"

  # The INDEX fan-out (WS-Notes Phase 3): the pages list is a bounded first screen, not a
  # paginated list. A tree of 200 pages is a workspace; a thousand is a search problem, which is
  # Phase 4's job. A DoS / row-transfer bound, like `@block_limit`.
  @index_limit 200

  # The backlink fan-out (WS-Notes Phase 4). A bounded reverse query, not pagination: a page
  # linked from more than this is a hub, and the UI shows the first screen.
  @backlink_limit 200

  @doc_select [:id, :title, :body, :secure_body, :icon, :parent_doc_id, :position, :revision]
  @block_select [
    :id,
    :doc_id,
    :parent_block_id,
    :position,
    :type,
    :text,
    :text_secure,
    :checked,
    :metadata,
    :revision
  ]

  @type block :: %{
          id: term(),
          doc_id: term(),
          parent_block_id: term() | nil,
          position: integer(),
          type: atom(),
          checked: boolean() | nil,
          metadata: map(),
          revision: integer(),
          text: String.t() | Samen.Masked.t() | nil,
          secure?: boolean(),
          masked?: boolean()
        }

  @type page :: %{
          doc: struct(),
          blocks: [block()],
          legacy: nil | %{text: String.t() | Samen.Masked.t(), secure?: boolean()}
        }

  @doc """
  Read one page and its ordered blocks for `scope`.

  `{:ok, %{doc: doc, blocks: blocks, legacy: legacy}}` or `{:error, :not_found}` — a page in
  another org is simply not found (R1).
  """
  @spec page(Mount.t(), Samen.Scope.t(), term()) :: {:ok, page()} | {:error, :not_found}
  def page(mount, scope, doc_id) do
    with {:ok, doc} <- fetch_doc(mount, scope, doc_id) do
      blocks = fetch_blocks(mount, scope, doc_id)

      [resolved_doc] = resolve([doc], mount, scope, doc_resource(mount))
      resolved_blocks = resolve(blocks, mount, scope, block_resource(mount))

      {:ok,
       %{
         doc: resolved_doc,
         blocks: Enum.map(resolved_blocks, &project/1),
         legacy: legacy(resolved_doc, resolved_blocks)
       }}
    end
  end

  @doc """
  Re-read ONE block through the same seam (the remote-change path: a subscriber that receives an
  id-only `{:block_changed, id, revision}` re-reads here, on its own plane).

  `{:ok, block}` or `{:error, :not_found}`.
  """
  @spec block(Mount.t(), Samen.Scope.t(), term()) :: {:ok, block()} | {:error, :not_found}
  def block(mount, scope, block_id) do
    query =
      block_resource(mount)
      |> Ash.Query.ensure_selected(@block_select)
      |> Ash.Query.filter(id == ^block_id)
      |> Ash.Query.limit(1)

    case Ash.read(query, scope: scope) do
      {:ok, [record | _]} ->
        [resolved] = resolve([record], mount, scope, block_resource(mount))
        {:ok, project(resolved)}

      _ ->
        {:error, :not_found}
    end
  end

  @doc """
  List the org's pages for the INDEX surface (WS-Notes Phase 3 unit 3.2) — bounded, newest first,
  titles only.

  This is the same seam as `page/3`, so the index cannot start reading `Doc` by another route: a
  page in another org is simply absent (R1), and an empty org returns `[]` (an honest empty
  state) rather than raising.

  Returns `{:ok, [%{id: id, title: title, icon: icon, parent_doc_id: parent, position: position,
  revision: revision, updated_at: updated_at}]}`. `title`/`icon` are non-PII by construction
  (only `body`/`secure_body` are vault-routed), so nothing here is resolved — a title is safe to
  show on every plane, which is exactly what makes a page list possible on the operator plane at
  all.
  """
  @spec index(Mount.t(), Samen.Scope.t()) :: {:ok, [map()]}
  def index(mount, scope) do
    rows =
      doc_resource(mount)
      |> Ash.Query.ensure_selected([:id, :title, :icon, :parent_doc_id, :position, :revision, :updated_at])
      |> Ash.Query.sort(updated_at: :desc)
      |> Ash.Query.limit(@index_limit)
      |> Ash.read!(scope: scope)

    {:ok, Enum.map(rows, &project_doc/1)}
  end

  @doc """
  The org's TRASH — the pages a soft delete removed (WS-Notes Phase 3 unit 3.7).

  The same seam as `index/2`, on the SAME `Doc` resource: this is the `:archived` read
  (`Samen.Archival.OnlyArchived`, injected by `archivable: true`), so it returns archived rows
  ONLY — never a union with the live set. A page in another org is simply absent (R1), and an
  empty trash is `{:ok, []}` rather than an error.

  Sorted newest-deleted first, bounded by `@index_limit` like the live list. Titles are non-PII
  by construction (only `body`/`secure_body`/`block.text` are vault-routed), so nothing here is
  resolved — which is also why the trash shows a page's TITLE and never its content: the row a
  restore names is metadata, and restoring is how the content comes back.

  ## "Who deleted this?" comes from the governance trail, not from the row

  Each result carries the page's most recent `record_archived` event (`Samen.Archival.Audit`
  writes it inside the delete's own transaction, so the trail and the row cannot disagree about
  whether a delete happened):

    * `deleted_by` — the `aud_actor_id`, an opaque id (never rendered);
    * `deleted_by_name` — that actor's `Identity.User.full_name`, resolved through
      `Samen.Api.PiiResolution` ON THE ACTING PLANE, exactly as this module resolves block text.
      So the tenant plane reads the name CLEAR and an operator plane without a grant gets a
      `%Samen.Masked{}` (`••••`, present-but-masked — the impersonation posture), never plaintext
      and never a `vt_*` token. The name is shaped by `Samen.Web.ObjectRef.FieldValue.full_name/2`
      (the shared formatter that decodes the revealed `{"first":…,"last":…}` form and passes a
      `%Masked{}` through untouched), so this seam never invents its own PII rendering.

  A name is read ONLY for an actor id inside the ACTING org (`id in … and org_id == acting org`,
  `authorize?: false` with that explicit filter — the `Samen.Auth.OrgActor` posture): an audit row
  is an opaque string, and one that named a different org's user must never produce a name here.

  `nil` in either key means the trail has no such event (a page archived by a seed or by a host
  that does not write the audit tier) — the surface then says WHEN and stays silent about WHO,
  rather than guessing. `deleted_by_name` is also `nil` when the host has no Identity seam to
  resolve against; the surface falls back to the coarse identity label it already renders.

  Both reads are BOUNDED (the page ids this call already returned; the actor ids those events
  named — never a table scan), and fail-soft in the one place that is safe: an unreadable audit or
  identity tier costs the "who" column, never the trash itself — the pages are what the user came
  for.

  Returns `{:ok, [%{id: id, title: title, icon: icon, parent_doc_id: parent, position: position,
  revision: revision, archived_at: deleted_at, deleted_by: actor_id | nil,
  deleted_by_name: String.t() | Samen.Masked.t() | nil}]}`.
  """
  @spec trash(Mount.t(), Samen.Scope.t()) :: {:ok, [map()]}
  def trash(mount, scope) do
    rows =
      doc_resource(mount)
      |> Ash.Query.for_read(:archived)
      |> Ash.Query.ensure_selected([:id, :title, :icon, :parent_doc_id, :position, :revision, :archived_at])
      |> Ash.Query.sort(archived_at: :desc)
      |> Ash.Query.limit(@index_limit)
      |> Ash.read!(scope: scope)

    deleters = deletion_actors(mount.repo, Enum.map(rows, &to_string(&1.id)))
    names = deleter_names(mount, scope, Map.values(deleters))

    {:ok,
     Enum.map(rows, fn row ->
       actor = Map.get(deleters, to_string(row.id))
       project_trashed(row, actor, Map.get(names, actor))
     end)}
  end

  # The DELETER's display name per actor id, resolved on the acting plane. `org_id` comes from the
  # ACTOR (the governed scope), never from a record, and the read is filtered by it — an audit row
  # is an opaque string, so the filter is what keeps a foreign id from naming a foreign user.
  defp deleter_names(_mount, _scope, []), do: %{}

  defp deleter_names(mount, scope, actor_ids) do
    ids = actor_ids |> Enum.reject(&is_nil/1) |> Enum.uniq()
    org_id = Map.get(actor_of(scope), :org_id)

    if ids == [] or is_nil(org_id) do
      %{}
    else
      identity = CurrentOrg.identity_mount(mount)
      user_resource = Mount.resource(identity, :User)

      users =
        user_resource
        |> Ash.Query.ensure_selected([:id, :full_name])
        |> Ash.Query.filter(id in ^ids and org_id == ^org_id)
        |> Ash.Query.limit(length(ids))
        |> Ash.read!(authorize?: false)

      users
      |> resolve(mount, scope, user_resource)
      |> Enum.reduce(%{}, fn user, acc ->
        case display_name(user) do
          nil -> acc
          name -> Map.put(acc, user.id, name)
        end
      end)
    end
  rescue
    # No Identity seam (a module mount with no `:identity_namespace`), an unmigrated Identity
    # spine, or a failed decrypt: the row falls back to the coarse identity label, never to a
    # guessed name.
    _ -> %{}
  end

  # `FieldValue.full_name/2` decodes the revealed JSON and passes a `%Masked{}` through — the ONE
  # shared formatter, so this surface cannot invent its own (or a leaking) rendering.
  defp display_name(user) do
    case Samen.Web.ObjectRef.FieldValue.full_name(Map.get(user, :full_name)) do
      "—" -> nil
      "" -> nil
      name -> name
    end
  end

  # The latest `record_archived` event per page id → its actor id. Newest first, first row wins, so
  # a page that was deleted, restored and deleted again reports the delete that produced the row in
  # the trash rather than the oldest opinion about it.
  defp deletion_actors(_repo, []), do: %{}

  defp deletion_actors(repo, doc_ids) do
    import Ecto.Query, only: [from: 2]

    rows =
      repo.all(
        from(a in Samen.AuditEvent,
          where: a.subject_id in ^doc_ids and a.event_type == ^@delete_event,
          order_by: [desc: a.occurred_at],
          select: %{subject_id: a.subject_id, actor_id: a.actor_id}
        )
      )

    Enum.reduce(rows, %{}, fn row, acc -> Map.put_new(acc, row.subject_id, row.actor_id) end)
  rescue
    # Fail-soft on the AUDIT tier only (a host that has not migrated `aud_event`): the trash still
    # lists, and a row without a deleter says so by omission instead of inventing one.
    _ -> %{}
  end

  @doc """
  The pages that LINK to `doc_id` (WS-Notes Phase 4 unit 4.3) — the reverse of the org-scoped
  `DocLink` rows.

  Returns `[%{source_id: id, source_title: title, anchor_text: typed, stale?: boolean}]`, sorted
  by source title. Both halves are scoped/filtered reads:

    * the LINK rows come from `DocLink`, whose both endpoints are same-org (`SameOrgFk`, R13);
    * the SOURCE page is re-read through `Doc` on the same scope, so an archived source page drops
      out of the list (R15) instead of rendering a link to a page the tree no longer shows.

  `stale?` is true when the text the author typed no longer equals the TARGET's current title —
  the "link may point at an older title" hint. Nothing is rewritten here; the next save of the
  source page re-resolves it (ADR-053 §5).
  """
  @spec backlinks(Mount.t(), Samen.Scope.t(), term()) :: [map()]
  def backlinks(mount, scope, doc_id) do
    case fetch_doc(mount, scope, doc_id) do
      {:ok, target} ->
        links =
          mount
          |> link_resource()
          |> Ash.Query.ensure_selected([:source_doc_id, :target_doc_id, :anchor_text])
          |> Ash.Query.filter(target_doc_id == ^doc_id)
          |> Ash.Query.limit(@backlink_limit)
          |> Ash.read!(scope: scope)

        sources = live_docs(mount, scope, Enum.map(links, & &1.source_doc_id))

        links
        |> Enum.flat_map(fn link ->
          case Map.get(sources, link.source_doc_id) do
            nil ->
              []

            source ->
              [
                %{
                  source_id: source.id,
                  source_title: source.title || "Untitled",
                  anchor_text: link.anchor_text,
                  stale?: link.anchor_text != target.title
                }
              ]
          end
        end)
        |> Enum.sort_by(&String.downcase(&1.source_title))

      _ ->
        []
    end
  rescue
    _ -> []
  end

  @doc """
  The `[[Title]]` references on this page that do NOT resolve to a live, same-org page
  (WS-Notes Phase 4 unit 4.3) — the "create this page" affordance.

  Only the PLAIN `text` column is parsed (a vaulted block never contributes link intent), and
  resolution is `Samen.Web.Notes.Links.resolve_all/3`, which is org-scoped (R13) and excludes
  archived pages. Nothing is persisted for an unresolved title.
  """
  @spec unresolved(Mount.t(), Samen.Scope.t(), term()) :: [String.t()]
  def unresolved(mount, scope, doc_id) do
    titles = Samen.Web.Notes.Links.page_titles(mount, scope, doc_id)
    resolved = Samen.Web.Notes.Links.resolve_all(mount, scope, titles)
    Enum.reject(titles, &Map.has_key?(resolved, &1))
  rescue
    _ -> []
  end

  # ── internals ──────────────────────────────────────────────────────────────

  defp fetch_doc(mount, scope, doc_id) do
    query =
      doc_resource(mount)
      |> Ash.Query.ensure_selected(@doc_select)
      |> Ash.Query.filter(id == ^doc_id)
      |> Ash.Query.limit(1)

    case Ash.read(query, scope: scope) do
      {:ok, [doc | _]} -> {:ok, doc}
      _ -> {:error, :not_found}
    end
  end

  defp fetch_blocks(mount, scope, doc_id) do
    block_resource(mount)
    |> Ash.Query.ensure_selected(@block_select)
    |> Ash.Query.filter(doc_id == ^doc_id)
    |> Ash.Query.sort(position: :asc, id: :asc)
    |> Ash.Query.limit(@block_limit)
    |> Ash.read!(scope: scope)
  end

  # Resolve vault-routed fields through the shared chokepoint. Fail-safe: on any resolver error
  # the fields stay `%Masked{}` — never a raise, never a plaintext downgrade.
  defp resolve(records, mount, scope, resource) do
    Samen.Api.PiiResolution.resolve(records, resource, actor_of(scope), repo: mount.repo)
  rescue
    _ -> records
  end

  defp actor_of(%Samen.Scope{actor: actor}), do: actor
  defp actor_of(actor) when is_map(actor), do: actor
  defp actor_of(_), do: %{}

  # `Mount.resource/2` concatenates a SHORT name onto the mount's namespace, so these are the
  # `:Doc`/`:DocBlock` atoms — not the aliased modules (which would concatenate twice).
  defp doc_resource(mount), do: Mount.resource(mount, :Doc)
  defp block_resource(mount), do: Mount.resource(mount, :DocBlock)
  defp link_resource(mount), do: Mount.resource(mount, :DocLink)

  # The LIVE pages behind a set of ids — org-scoped AND archive-filtered, so an archived page is
  # absent from the map (the backlink half of R15).
  defp live_docs(_mount, _scope, []), do: %{}

  defp live_docs(mount, scope, doc_ids) do
    ids = doc_ids |> Enum.reject(&is_nil/1) |> Enum.uniq()

    mount
    |> doc_resource()
    |> Ash.Query.ensure_selected([:id, :title])
    |> Ash.Query.filter(id in ^ids)
    |> Ash.Query.limit(length(ids))
    |> Ash.read!(scope: scope)
    |> Map.new(&{&1.id, &1})
  rescue
    _ -> %{}
  end

  # ── projection ─────────────────────────────────────────────────────────────

  defp project_doc(doc) do
    %{
      id: doc.id,
      title: doc.title,
      icon: Map.get(doc, :icon),
      parent_doc_id: Map.get(doc, :parent_doc_id),
      position: Map.get(doc, :position),
      revision: Map.get(doc, :revision),
      updated_at: Map.get(doc, :updated_at)
    }
  end

  defp project_trashed(doc, deleted_by, deleted_by_name) do
    doc
    |> project_doc()
    |> Map.put(:archived_at, Map.get(doc, :archived_at))
    |> Map.put(:deleted_by, deleted_by)
    |> Map.put(:deleted_by_name, deleted_by_name)
  end

  defp project(block) do
    secure? = not is_nil(Map.get(block, :text_secure))
    text = if secure?, do: Map.get(block, :text_secure), else: Map.get(block, :text)

    %{
      id: block.id,
      doc_id: Map.get(block, :doc_id),
      parent_block_id: Map.get(block, :parent_block_id),
      position: Map.get(block, :position),
      type: Map.get(block, :type),
      checked: Map.get(block, :checked),
      metadata: Map.get(block, :metadata) || %{},
      revision: Map.get(block, :revision),
      text: text,
      secure?: secure?,
      masked?: match?(%Samen.Masked{}, text)
    }
  end

  # ADR-053 §8 O3: blocks win whenever blocks exist. With zero blocks, the legacy body is the page —
  # resolved on the same plane as everything else, so a masked plane reads `••••` here too.
  defp legacy(_doc, [_ | _]), do: nil

  defp legacy(doc, []) do
    cond do
      not is_nil(doc.secure_body) and doc.secure_body != "" ->
        %{text: doc.secure_body, secure?: true}

      is_binary(doc.body) and doc.body != "" ->
        %{text: doc.body, secure?: false}

      true ->
        nil
    end
  end
end
