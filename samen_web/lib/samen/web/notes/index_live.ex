defmodule Samen.Web.Notes.IndexLive do
  @moduledoc """
  The tenant **Pages** index (WS-Notes Phase 3 unit 3.2; ADR-053 §8 O4) — the page list and the
  one write that creates a page.

  Mounted at `/pages` by `Samen.Web.Router.samen_notes_routes/3`, so every host that mounts the
  macro inherits it at ≈0 authored LOC, and through `Samen.Web.Tenant.Live`, so it cannot render
  outside the shared chrome (a page-owned `render/1` is a compile error there).

  ## Reads and writes go through the ONE seam

  The list comes from `Samen.Web.Notes.Reads.index/3` — the same module the editor reads its
  blocks from — so the index cannot grow a second read path to `Doc`, and a page in another org
  is simply absent (R1). Titles are non-PII by construction (only `body`/`secure_body`/`block.text`
  are vault-routed), which is what makes a page LIST possible on the operator plane at all: there
  is nothing on this screen for `PiiResolution` to mask.

  `"New page"` calls `Samen.Web.Notes.Writes.create_page/3`, which runs the scope's own governed
  `:create` action (`OrgScope` + `RoleAtLeast :member`, ADR-053 §8 O6). The page does not write a
  `Doc` itself.

  ## Deleting a page

  Each row offers a DELETE that asks once before it writes (`"confirm_archive"` → `"archive_page"`),
  because a single mis-click on a page list must not remove a page. The write is
  `Samen.Web.Notes.Writes.archive_page/3` — a SOFT delete (the `:archive` action, the same
  `archivable` substrate the block ✕ uses), so the row leaves the tree and is recoverable rather
  than shredded. The control is offered on the tenant plane only (`Notes.Live.writable?/1`), which
  is POSTURE: an operator-plane or crafted event still reaches the model, where `OrgScope` +
  `RoleAtLeast :member` decide.

  A delete is not a dead end: the list says "Page deleted" next to an UNDO for the page just
  removed (an in-socket notice after this surface's own delete, or the `?deleted=` carrier the
  EDITOR hands over when it deletes the page it was showing). Undo is
  `Samen.Web.Notes.Writes.restore_page/3` — the `:restore` action, `record_restored` audit — and
  it patches the URL back to the plain index, so a reload cannot re-offer an undo that no longer
  applies.

  When the undo window is gone — a reload, another tab, a session later — the page is still not
  lost: `"Trash"` opens `Samen.Web.Notes.TrashLive` at `/pages/trash`, which lists the org's
  archived pages through `Samen.Web.Notes.Reads.trash/2` and restores one with the SAME
  `Writes.restore_page/3` this surface's Undo uses.

  ## Honest states

    * no org resolvable → `.no_org_card` (the framework's "you are not acting in an org" card);
    * an org with no pages → the `note_empty_state/1` kit card, which offers the first block
      instead of a blank tree;
    * a failed create → an alert banner; the page never redirects as if it had succeeded.
  """

  use Samen.Web.Tenant.Live

  import Samen.Web.CurrentOrg, only: [acting_as_banner: 1, no_org_card: 1, return_path: 1]

  import Samen.Web.Notes.Live,
    only: [
      assign_mount: 2,
      index_href: 2,
      notes_sidebar: 1,
      page_href: 3,
      trash_href: 2,
      writable?: 1
    ]

  alias Samen.Web.{Crumbs, CurrentOrg, Mount, TenantRole}
  alias Samen.Web.Notes.{PubSub, Reads, Search, Writes}

  @impl true
  def mount(params, session, socket) do
    socket = assign_mount(socket, session)
    org_id = CurrentOrg.resolve(socket.assigns[:samen_mount], params, session)

    {:ok,
     socket
     |> assign(
       org_id: org_id,
       return_to: nil,
       error: nil,
       confirm: nil,
       deleted: params["deleted"]
     )
     |> load(org_id, q(params))}
  end

  @impl true
  def handle_params(params, uri, socket) do
    org_id = CurrentOrg.reresolve(socket, params)

    {:noreply,
     socket
     |> assign(
       org_id: org_id,
       return_to: return_path(uri),
       confirm: nil,
       deleted: params["deleted"]
     )
     |> load(org_id, q(params))}
  end

  @doc false
  def load(socket, org_id, q \\ "")

  def load(socket, nil, q) do
    socket
    |> defaults()
    |> assign(pages: [], results: [], q: q, no_org: no_org?(socket), org_id: nil, confirm: nil)
  end

  def load(socket, org_id, q) do
    socket = defaults(socket)
    mount = socket.assigns.samen_mount
    scope = Mount.scope(mount, org_id)

    {:ok, pages} = Reads.index(mount, scope)
    results = if q == "", do: [], else: Search.search(mount, scope, q)

    # A reload settles any pending delete confirmation: it names a row of the list this load is
    # about to replace, so carrying it across would leave a confirm box on an unrelated page.
    assign(socket,
      pages: pages,
      results: results,
      q: q,
      no_org: false,
      org_id: org_id,
      confirm: nil
    )
  end

  # The search term rides the URL (`/pages?q=…`) so a result set is shareable and a reload is
  # the same query. `load/3` is the single place that turns it into hits.
  defp q(params), do: String.trim(to_string(Map.get(params, "q") || ""))

  @impl true
  def handle_event("search", %{"q" => q}, socket) do
    q = String.trim(to_string(q))
    {:noreply, load(socket, socket.assigns.org_id, q)}
  end

  @impl true
  def handle_event("create_page", %{"title" => title}, socket) do
    %{samen_mount: mount, org_id: org_id} = socket.assigns

    case is_binary(org_id) &&
           Writes.create_page(mount, Mount.scope(mount, org_id), %{title: title}) do
      {:ok, doc} ->
        {:noreply, push_navigate(socket, to: page_href(mount, org_id, doc.id))}

      _ ->
        {:noreply, assign(socket, error: "The page could not be created.")}
    end
  end

  def handle_event("create_page", _params, socket) do
    {:noreply, assign(socket, error: "The page could not be created.")}
  end

  # Deleting asks first: the ✕ only NAMES the page it would remove. Two-step, server-side, so the
  # confirmation works with no JavaScript and its state is the socket's, not the DOM's.
  def handle_event("confirm_archive", %{"id" => id}, socket) do
    {:noreply, assign(socket, confirm: id, error: nil)}
  end

  def handle_event("cancel_archive", _params, socket) do
    {:noreply, assign(socket, confirm: nil)}
  end

  def handle_event("archive_page", %{"id" => id}, socket) do
    %{samen_mount: mount, org_id: org_id} = socket.assigns

    # Counted BEFORE the write, from the list this socket already holds (no second read): the delete
    # takes the page's whole subtree with it, and after it those rows are gone, so a notice written
    # afterwards could not say how much actually went.
    subpages = subpage_count(socket.assigns.pages, id)

    # `identity_scope/2`, not `Mount.scope/2`: this is the write whose "who" the Trash view reads
    # back out of the governance trail, so it must name the acting principal where the host can
    # resolve one. Authority is unchanged (same plane/kind/role) — only the attribution moves.
    scope = is_binary(org_id) && TenantRole.identity_scope(mount, org_id)

    case scope && Writes.archive_page(mount, scope, id) do
      {:ok, doc} ->
        # A page someone else has open learns it is gone the way every structural change travels:
        # an id-only envelope, re-read on THEIR plane (their re-read now answers `:not_found`, so
        # the editor shows its "not in your workspace" card instead of a page that no longer
        # exists). Best-effort, exactly like every other notes broadcast.
        PubSub.broadcast_page_structure_changed(
          mount,
          to_string(doc.id),
          doc.id,
          Map.get(doc, :revision)
        )

        # The notice is the undo's only handle: it names the page just removed — and the subpages
        # that went with it — and it is cleared by the undo itself (or by any reload of the plain
        # index). The undo restores the subtree too (`CascadeRestore`), so the count is recoverable.
        {:noreply,
         load(
           assign(socket, deleted: doc.id, deleted_subpages: subpages),
           org_id,
           socket.assigns.q
         )}

      _ ->
        {:noreply, assign(socket, confirm: nil, error: "The page could not be deleted.")}
    end
  end

  # Undo: the `:restore` action, not a re-create — the page comes back with its blocks, its
  # children and its audit trail intact. Idempotent in `Writes.restore_page/3`, so a second click
  # (or a stale `?deleted=` carrier) settles instead of erroring.
  def handle_event("undo_delete", _params, socket) do
    %{samen_mount: mount, org_id: org_id} = socket.assigns
    deleted = socket.assigns[:deleted]

    scope = is_binary(org_id) && TenantRole.identity_scope(mount, org_id)

    case scope && is_binary(deleted) && Writes.restore_page(mount, scope, deleted) do
      {:ok, _doc} ->
        # The list comes back WITH the restored row, and the URL loses the `?deleted=` carrier: a
        # reload must not offer an undo for a page that is already back.
        socket =
          socket
          |> assign(deleted: nil)
          |> load(org_id, socket.assigns.q)

        {:noreply, push_patch(socket, to: index_href(mount, org_id))}

      _ ->
        {:noreply, assign(socket, deleted: nil, error: "The page could not be restored.")}
    end
  end

  @impl Samen.Web.Tenant.Live
  def tenant_sidebar(assigns) do
    ~H"""
    <.notes_sidebar
      mount={@samen_mount}
      org_id={@org_id}
      active={:pages}
      return_to={@return_to}
    />
    """
  end

  @impl Samen.Web.Tenant.Live
  def tenant_page(assigns) do
    ~H"""
    <div id="notes-index">
      <.topbar title="Pages" crumbs={crumbs(@samen_mount, @org_id)} />

      <.acting_as_banner mount={@samen_mount} org_id={@org_id} acting_as={@samen_acting_as} />

      <%= if @no_org do %>
        <.no_org_card mount={@samen_mount} />
      <% else %>
        <div class="wrap">
          <div :if={@error} id="notes-index-error" class="note-error" role="alert">{@error}</div>

          <%!-- The undo window. `role="status"` because it appears without the user asking and
               announces itself; the Undo is a governed write, so it is offered only where a write
               could land (posture — the model decides). --%>
          <div
            :if={is_binary(@deleted) && editable?(@samen_mount, @org_id)}
            id="notes-deleted-notice"
            class="note-undo-notice"
            role="status"
          >
            <span>{deleted_notice(@deleted_subpages)}</span>
            <button type="button" id="notes-undo-delete" class="note-undo" phx-click="undo_delete">
              Undo
            </button>
          </div>

          <form id="notes-search" class="note-search" phx-submit="search">
            <label class="sr-only" for="notes-search-q">Search pages</label>
            <input
              id="notes-search-q"
              type="search"
              name="q"
              value={@q}
              placeholder="Search pages and blocks…"
              autocomplete="off"
            />
            <.button type="submit">Search</.button>
          </form>

          <%!-- The vaulting trade-off, stated where a user would look for the content. --%>
          <p id="notes-search-vault-note" class="note-search-note">
            Vaulted (🔒) blocks are not searchable — their text never enters the index.
          </p>

          <%!-- The durable way back, beside the transient one: the undo notice above is cleared by
               any reload, while a deleted page stays in the trash until it is restored or the
               workspace drops it. --%>
          <div class="note-trash-link-row">
            <a id="notes-trash-link" class="note-trash-back" href={trash_href(@samen_mount, @org_id)}>
              Trash
            </a>
          </div>

          <%= if @q != "" do %>
            <div id="notes-search-results" class="note-search-results" aria-label="Search results">
              <%= if @results == [] do %>
                <div id="notes-search-empty" class="note-empty">
                  <p class="note-empty-title">No blocks match “{@q}”.</p>
                  <p class="note-empty-body">
                    Only plain-text blocks and page titles are indexed. A vaulted block is
                    intentionally invisible to search.
                  </p>
                </div>
              <% else %>
                <a
                  :for={hit <- @results}
                  id={"note-search-hit-" <> to_string(hit.block_id || hit.doc_id)}
                  class="note-search-hit"
                  href={hit_href(@samen_mount, @org_id, hit)}
                >
                  <span class="note-search-hit-title">{hit.doc_title}</span>
                  <span :if={hit.snippet} class="note-search-hit-snippet">{hit.snippet}</span>
                </a>
              <% end %>
            </div>
          <% else %>
            <form id="notes-new-page" class="note-new-page" phx-submit="create_page">
              <label class="sr-only" for="notes-new-page-title">New page title</label>
              <input
                id="notes-new-page-title"
                type="text"
                name="title"
                placeholder="A new page"
                autocomplete="off"
                required
              />
              <.button variant="primary" type="submit">New page</.button>
            </form>

            <div id="notes-tree" class="notes-tree" aria-label="Pages">
              <%= if @pages == [] do %>
                <.note_empty_state />
              <% else %>
                <div
                  :for={page <- @pages}
                  id={"note-tree-item-" <> page.id}
                  class="note-tree-item"
                  data-parent={page.parent_doc_id || ""}
                >
                  <a
                    id={"note-tree-row-" <> page.id}
                    class="note-tree-row"
                    href={page_href(@samen_mount, @org_id, page.id)}
                  >
                    <span class="note-tree-icon" aria-hidden="true">{page.icon || "▤"}</span>
                    <span class="note-tree-title">{page.title}</span>
                    <span class="note-tree-meta">{edited_at(page.updated_at)}</span>
                  </a>

                  <%= if @confirm == page.id do %>
                    <div
                      id={"note-delete-confirm-" <> page.id}
                      class="note-confirm"
                      role="group"
                      aria-label="Delete page"
                    >
                      <span class="note-confirm-question">Delete “{page.title}”?</span>
                      <span
                        :if={subpage_count(@pages, page.id) > 0}
                        id={"note-delete-subpages-" <> page.id}
                        class="note-confirm-detail"
                      >
                        Its {subpage_label(subpage_count(@pages, page.id))} go with it.
                      </span>
                      <button
                        type="button"
                        id={"note-delete-yes-" <> page.id}
                        class="note-confirm-yes"
                        phx-click="archive_page"
                        phx-value-id={page.id}
                      >Delete page</button>
                      <button
                        type="button"
                        id={"note-delete-cancel-" <> page.id}
                        class="note-control"
                        phx-click="cancel_archive"
                        aria-label="Keep the page"
                      >Cancel</button>
                    </div>
                  <% else %>
                    <button
                      :if={editable?(@samen_mount, @org_id)}
                      type="button"
                      id={"note-delete-" <> page.id}
                      class="note-control"
                      phx-click="confirm_archive"
                      phx-value-id={page.id}
                      aria-label={"Delete " <> page.title}
                    >✕</button>
                  <% end %>
                </div>
              <% end %>
            </div>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  defp crumbs(mount, org_id) do
    [Crumbs.org(mount, org_id), Crumbs.section(mount, org_id, :pages)]
  end

  # A block hit deep-links to the block's row; a title hit opens the page itself.
  defp hit_href(mount, org_id, %{kind: :block} = hit) do
    page_href(mount, org_id, hit.doc_id) <> "#note-block-" <> to_string(hit.block_id)
  end

  defp hit_href(mount, org_id, hit), do: page_href(mount, org_id, hit.doc_id)

  # `mount/3` and `handle_params/3` set these; a direct caller (a render test) may hand in a bare
  # socket, so they are defaulted here rather than read unconditionally by the template.
  defp defaults(socket) do
    socket
    |> assign_new(:return_to, fn -> nil end)
    |> assign_new(:error, fn -> nil end)
    |> assign_new(:q, fn -> "" end)
    |> assign_new(:results, fn -> [] end)
    |> assign_new(:deleted, fn -> nil end)
    |> assign_new(:deleted_subpages, fn -> 0 end)
  end

  defp no_org?(socket), do: CurrentOrg.no_org?(socket.assigns[:samen_mount], nil)

  # POSTURE only, the `PageLive` rule: the affordance is offered where the write it leads to could
  # be admitted, and the model refuses it everywhere else.
  defp editable?(mount, org_id), do: writable?(mount) and is_binary(org_id)

  defp edited_at(%DateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M")
  defp edited_at(_), do: ""

  # How many pages hang under `id`, at any depth — counted from the rows this socket already has,
  # so naming the size of a delete costs no second read. `seen` bounds the walk: a corrupted cycle
  # in the parent edges must not hang a render.
  defp subpage_count(pages, id) do
    by_parent = Enum.group_by(pages, & &1.parent_doc_id)
    count_descendants(Map.get(by_parent, id, []), by_parent, MapSet.new([id]))
  end

  defp count_descendants(children, by_parent, seen) do
    fresh = Enum.reject(children, &MapSet.member?(seen, &1.id))
    seen = Enum.reduce(fresh, seen, &MapSet.put(&2, &1.id))

    length(fresh) +
      Enum.sum(
        Enum.map(fresh, &count_descendants(Map.get(by_parent, &1.id, []), by_parent, seen))
      )
  end

  defp subpage_label(1), do: "1 subpage"
  defp subpage_label(count), do: "#{count} subpages"

  defp deleted_notice(0), do: "Page deleted."
  defp deleted_notice(1), do: "Page and 1 subpage deleted."
  defp deleted_notice(count), do: "Page and #{count} subpages deleted."
end
