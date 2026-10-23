defmodule Samen.Web.Notes.TrashLive do
  @moduledoc """
  The tenant **Trash** for Pages (WS-Notes Phase 3 unit 3.7) — where a deleted page is still
  findable once the undo notice has gone.

  Mounted at `/pages/trash` by `Samen.Web.Router.samen_notes_routes/3`, so every host that mounts
  the macro inherits it at ≈0 authored LOC, and through `Samen.Web.Tenant.Live`, so it cannot
  render outside the shared chrome.

  ## The undo window ends; the page does not

  The index's Undo is a convenience with a short life: it names the page just removed, and any
  reload of the plain index clears it. A delete is a SOFT delete (the model's `:archive` action),
  so the page is still there — this view is the second, durable way back. It reads
  `Samen.Web.Notes.Reads.trash/2`, the `:archived` read on the SAME `Doc` resource, so an archived
  page in another org is simply absent (R1) and there is no second read path to keep in step.

  Restoring is `Samen.Web.Notes.Writes.restore_page/3` — the SAME write the Undo uses, so a page
  comes back from here exactly as it does from there: blocks, children and audit trail intact, its
  outgoing `[[Title]]` edges re-derived in the same transaction, and a `record_restored` audit row
  as the counterpart of the delete's `record_archived`.

  ## What a row shows, and what it deliberately does not

  A trashed page has no editor to open, so its title is NOT a link: the row is a title, when it was
  deleted, WHO deleted it, and one Restore. The "who" is read out of the governance trail —
  `Reads.trash/2` returns the `aud_actor_id` of the page's `record_archived` event and, for that
  actor, their `Identity.User.full_name` resolved ON THE ACTING PLANE — and rendered in order of
  specificity:

    * **"you"** when the trail's actor IS the signed-in principal (`TenantRole.principal_actor_id/2`);
    * **the person's NAME**, as the acting plane resolved it: the tenant plane reads its own
      members' names in the CLEAR, while an operator plane without a grant gets a `%Samen.Masked{}`
      and the row renders `••••` — present-but-masked, never plaintext, never a `vt_*` token;
    * **"a workspace member"** when the event names the workspace's shared pseudo-principal
      (`Mount.scope/2`'s `broker:<org>` — a host with no identity seam, or a page deleted before
      `TenantRole.identity_scope/2` was wired), and **"another member"** for any other actor the
      surface cannot name.

  The opaque actor id is never printed. The name is resolved by `Reads` through the ONE PII seam
  (no renderer here reads a vault field), so this row cannot grow a plaintext branch: masking is
  the resolver's per-plane decision, and the row only formats what it was handed.

  When the trail has no `record_archived` event for the row (a seeded archive, or a host that does
  not write the audit tier), the row says WHEN and stays silent about WHO rather than guessing. The body — and every block in it — is absent from this screen: a page's
  title is non-PII by construction, its content is not, and a list of deleted pages has no reason
  to become a second, unmasked reader of vaulted text. Restoring is how you see the content again.

  The control is offered on the tenant plane only (`Notes.Live.writable?/1`), which is POSTURE: a
  crafted `restore_page` event from anywhere still reaches the model, where `OrgScope` +
  `RoleAtLeast :member` decide.

  ## Emptying the trash — the one WRITE that ends a page

  Restore is the way back; **Delete forever** is the way out, and it is deliberately narrow
  (WS-Notes Phase 3 unit 3.11):

    * **ADMIN only**, decided in the MODEL — the `Doc.:purge` policy (`RoleAtLeast :admin`), never
      by this view. The view only decides whether to OFFER the control, off the same
      `TenantRole.admin_scope/3` role the kernel gate will read (disarmed dev posture ⇒ `:admin`;
      armed ⇒ the caller's real `Membership` rank), so a crafted `purge_page` event reaches exactly
      the same refusal a missing button would have prevented;
    * **trash only** — `Writes.purge_page/3` reads the page through the `:archived` read, so a LIVE
      page is `{:error, :not_found}` here, and the model refuses a live page even when called
      directly (`Samen.Scopes.Docs.PagePurge`): a page is always soft-deleted first, and only a
      trashed page can be destroyed outright;
    * **404-safe** — an unknown id, another org's page, or a row already emptied from a stale tab
      all settle as "no longer in the trash" rather than raising or leaving a confirm box on a
      row that is not there;
    * **audited** — the destroy writes `record_purged` in its own transaction, so the trail names
      the terminal delete the way it named the archive that preceded it;
    * **content goes with it** — the page's blocks are hard-destroyed in the same transaction
      (`Doc`'s blocks are NOT archived with the page, so a page-only delete would orphan them).

  Like the delete itself this is a two-step, server-side confirm (`confirm_purge` → `purge_page`),
  so the state is the socket's and it works with no JavaScript.

  ## Emptying it all at once (unit 3.12)

  **Empty the trash** runs the SAME write over the whole set: `Writes.empty_trash/2` reads the trash
  (`:archived`, newest-deleted first, bounded by the same 200 rows this view renders) and purges
  every page INSIDE ONE TRANSACTION, so a refusal anywhere — a member reaching the scope, a page
  past the block bound — leaves the trash exactly as it was instead of emptying three of seven.
  Every page still gets its OWN `record_purged` row: the trail has to name WHICH pages were
  destroyed, so a batch never collapses into one summary row. Admin-only and two-step for exactly
  the reasons the per-page delete is, and the notice reports the count that actually went, never
  "the trash is empty" unless the reloaded list is empty.
  """

  use Samen.Web.Tenant.Live

  import Samen.Web.CurrentOrg, only: [acting_as_banner: 1, no_org_card: 1, return_path: 1]

  import Samen.Web.Notes.Live,
    only: [assign_mount: 2, index_href: 2, notes_sidebar: 1, page_href: 3, writable?: 1]

  alias Samen.Web.{Crumbs, CurrentOrg, Mount, TenantRole}
  alias Samen.Web.Notes.{PubSub, Reads, Writes}

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
       restored: nil,
       confirm: nil,
       confirm_empty: false,
       emptied: nil,
       purged: nil
     )
     |> load(org_id)}
  end

  @impl true
  def handle_params(params, uri, socket) do
    org_id = CurrentOrg.reresolve(socket, params)

    {:noreply,
     socket
     |> assign(org_id: org_id, return_to: return_path(uri), error: nil)
     |> load(org_id)}
  end

  @doc """
  Load the trash for `org_id`. Public for the same reason the sibling surfaces' `load/*` are: a
  render test drives the mounted code path without booting an Endpoint, and a handler's result can
  be asserted in the DOM.
  """
  def load(socket, org_id \\ nil)

  def load(socket, nil) do
    socket
    |> defaults()
    |> assign(pages: [], no_org: no_org?(socket), org_id: nil, viewer_id: nil, purgeable: false)
  end

  def load(socket, org_id) do
    socket = defaults(socket)
    mount = socket.assigns.samen_mount

    {:ok, pages} = Reads.trash(mount, Mount.scope(mount, org_id))

    # `nil` when the host cannot resolve who is signed in — which must stay distinguishable from a
    # recorded actor, or every anonymous session would read every row as its own.
    assign(socket,
      pages: pages,
      no_org: false,
      org_id: org_id,
      viewer_id: TenantRole.principal_actor_id(mount, org_id),
      # POSTURE: whether the "Delete forever" control is OFFERED. The kernel decides whether the
      # write is allowed (`Doc.:purge`, admin-only), and this reads the SAME role that gate will
      # read — see the moduledoc.
      purgeable: purgeable?(mount, org_id)
    )
  end

  # Restoring from the trash is the same governed write the index's Undo runs, so the two ways back
  # cannot drift: `{:error, :not_found}` here means the row is already gone from the trash (someone
  # else restored or hard-deleted it), which the page says instead of rendering a stale list.
  @impl true
  def handle_event("restore_page", %{"id" => id}, socket) do
    %{samen_mount: mount, org_id: org_id} = socket.assigns

    # The same attribution the delete wrote: a restore that named the workspace would leave the
    # page's own two governance events disagreeing about who acted.
    scope = is_binary(org_id) && TenantRole.identity_scope(mount, org_id)

    case scope && Writes.restore_page(mount, scope, id) do
      {:ok, doc} ->
        # A page that is open somewhere (it may have been left open, or the restore races a
        # reload) learns it is back the way every structural change travels: an id-only envelope
        # re-read on the RECEIVER's plane. Best-effort, like every other notes broadcast.
        PubSub.broadcast_page_structure_changed(
          mount,
          to_string(doc.id),
          doc.id,
          Map.get(doc, :revision)
        )

        socket =
          socket
          |> assign(
            restored: %{id: doc.id, title: doc.title},
            purged: nil,
            emptied: nil,
            error: nil
          )
          |> load(org_id)

        {:noreply, socket}

      # The orphan guard, said in the user's terms: this row's parent is still deleted, so bringing
      # this one back would put a live page under a parent no read can see. One action fixes it.
      {:error, :parent_in_trash} ->
        socket =
          socket
          |> assign(
            restored: nil,
            error: "This page's parent is still in the trash — restore the parent first."
          )
          |> load(org_id)

        {:noreply, socket}

      _ ->
        socket =
          socket
          |> assign(restored: nil, error: "The page could not be restored.")
          |> load(org_id)

        {:noreply, socket}
    end
  end

  def handle_event("restore_page", _params, socket) do
    {:noreply, assign(socket, error: "The page could not be restored.")}
  end

  # Delete-forever asks first, exactly like the index's ✕: two-step, server-side, so the confirmation
  # works with no JavaScript and its state is the socket's, not the DOM's.
  def handle_event("confirm_purge", %{"id" => id}, socket) do
    {:noreply, assign(socket, confirm: id, confirm_empty: false, error: nil)}
  end

  def handle_event("cancel_purge", _params, socket) do
    {:noreply, assign(socket, confirm: nil)}
  end

  # Emptying the WHOLE trash asks first too, and there is one confirm slot: asking for one withdraws
  # the other, so a stale confirm can never be the thing a later click confirms.
  def handle_event("confirm_empty_trash", _params, socket) do
    {:noreply, assign(socket, confirm_empty: true, confirm: nil, error: nil)}
  end

  def handle_event("cancel_empty_trash", _params, socket) do
    {:noreply, assign(socket, confirm_empty: false)}
  end

  def handle_event("empty_trash", _params, socket) do
    %{samen_mount: mount, org_id: org_id} = socket.assigns

    case is_binary(org_id) && Writes.empty_trash(mount, purge_scope(mount, org_id)) do
      # Nothing in the trash: an idempotent no-op (a stale tab, a double click). Not an error, and
      # not a notice claiming a delete that never happened — the empty state speaks for itself.
      {:ok, []} ->
        {:noreply,
         socket
         |> assign(confirm_empty: false, confirm: nil, emptied: nil, purged: nil, error: nil)
         |> load(org_id)}

      {:ok, purged} ->
        # Every page that just left the trash may be open somewhere; each learns it is gone the way
        # every structural change travels — an id-only envelope whose own read answers `:not_found`.
        Enum.each(purged, fn doc ->
          PubSub.broadcast_page_structure_changed(
            mount,
            to_string(doc.id),
            doc.id,
            Map.get(doc, :revision)
          )
        end)

        socket =
          socket
          |> assign(
            emptied: length(purged),
            confirm_empty: false,
            confirm: nil,
            restored: nil,
            purged: nil,
            error: nil
          )
          |> load(org_id)

        {:noreply, socket}

      # A page in the trash still has a LIVE subpage (only reachable from a page deleted before the
      # cascade existed): the subtree cannot be destroyed whole, so nothing was, and the fix is the
      # user's — delete that subpage into the trash, then empty again.
      {:error, :live_descendants} ->
        socket =
          socket
          |> assign(
            confirm_empty: false,
            emptied: nil,
            error:
              "A page in the trash still has live subpages. Delete those, then empty the trash."
          )
          |> load(org_id)

        {:noreply, socket}

      # The transaction rolled back whole: nothing was destroyed, and a page past the block bound is
      # the one reason the user can act on.
      {:error, :too_many_blocks} ->
        socket =
          socket
          |> assign(
            confirm_empty: false,
            emptied: nil,
            error: "One of the pages in the trash is too large to delete permanently in one step."
          )
          |> load(org_id)

        {:noreply, socket}

      # Not an admin, or a write that failed: one message for "not you", never a claim of a partial
      # empty — the reload shows the untouched trash.
      _ ->
        socket =
          socket
          |> assign(
            confirm_empty: false,
            emptied: nil,
            error: "The trash could not be emptied."
          )
          |> load(org_id)

        {:noreply, socket}
    end
  end

  def handle_event("purge_page", %{"id" => id}, socket) do
    %{samen_mount: mount, org_id: org_id} = socket.assigns

    case is_binary(org_id) && Writes.purge_page(mount, purge_scope(mount, org_id), id) do
      {:ok, doc} ->
        # An editor open on the page learns it is gone the way every structural change travels: an
        # id-only envelope whose own read answers `:not_found`. Best-effort, like every notes
        # broadcast.
        PubSub.broadcast_page_structure_changed(
          mount,
          to_string(doc.id),
          doc.id,
          Map.get(doc, :revision)
        )

        socket =
          socket
          |> assign(purged: %{title: doc.title}, confirm: nil, emptied: nil, error: nil)
          |> load(org_id)

        {:noreply, socket}

      # 404-safe: a stale tab (someone restored or purged it first) settles into a message about
      # the row that is no longer there, never a crash or a confirm box on a missing row.
      {:error, :not_found} ->
        socket =
          socket
          |> assign(
            confirm: nil,
            purged: nil,
            emptied: nil,
            error: "That page is no longer in the trash."
          )
          |> load(org_id)

        {:noreply, socket}

      {:error, :too_many_blocks} ->
        {:noreply,
         assign(socket,
           confirm: nil,
           purged: nil,
           emptied: nil,
           error: "This page is too large to delete permanently in one step."
         )}

      # A LIVE subpage under this one: the subtree cannot be destroyed whole, so nothing was. The
      # fix is the user's (delete it into the trash first), and the page is still there to do it to.
      {:error, :live_descendants} ->
        socket =
          socket
          |> assign(
            confirm: nil,
            purged: nil,
            emptied: nil,
            error:
              "This page still has live subpages. Delete those first, then delete this page " <>
                "permanently."
          )
          |> load(org_id)

        {:noreply, socket}

      # The model refused (not an admin, or a page that is not archived after all). One message for
      # "not you": the surface never explains WHICH rule refused, and never claims the delete.
      _ ->
        socket =
          socket
          |> assign(
            confirm: nil,
            purged: nil,
            emptied: nil,
            error: "The page could not be deleted permanently."
          )
          |> load(org_id)

        {:noreply, socket}
    end
  end

  def handle_event("purge_page", _params, socket) do
    {:noreply, assign(socket, confirm: nil, error: "The page could not be deleted permanently.")}
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
    <div id="notes-trash">
      <.topbar title="Trash" crumbs={crumbs(@samen_mount, @org_id)} />

      <.acting_as_banner mount={@samen_mount} org_id={@org_id} acting_as={@samen_acting_as} />

      <%= if @no_org do %>
        <.no_org_card mount={@samen_mount} />
      <% else %>
        <div class="wrap">
          <div :if={@error} id="notes-trash-error" class="note-error" role="alert">{@error}</div>

          <%!-- The restore is announced, and the announcement carries the way to the page: the
               row it came from is gone from this list, so naming it without a link would leave the
               user to find it again on their own. --%>
          <div
            :if={@restored}
            id="notes-restored-notice"
            class="note-undo-notice"
            role="status"
          >
            <span>Page restored.</span>
            <a
              id="notes-restored-open"
              class="note-undo"
              href={page_href(@samen_mount, @org_id, @restored.id)}
            >
              Open “{@restored.title}”
            </a>
          </div>

          <%!-- The terminal delete is announced WITHOUT a link: there is nothing left to open, and
               offering one would be the surface claiming a page it just removed still exists. --%>
          <div :if={@purged} id="notes-purged-notice" class="note-undo-notice" role="status">
            <span>Page deleted permanently.</span>
            <span class="note-tree-meta">{@purged.title}</span>
          </div>

          <%!-- The bulk empty reports the COUNT that actually went. It never says "the trash is
               empty": the empty state below is the only thing entitled to claim that. --%>
          <div
            :if={@emptied}
            id="notes-trash-emptied-notice"
            class="note-undo-notice"
            role="status"
          >
            <span>{pages_phrase(@emptied)} deleted permanently.</span>
          </div>

          <div class="note-trash-head">
            <a id="notes-trash-back" class="note-trash-back" href={index_href(@samen_mount, @org_id)}>
              ← All pages
            </a>

            <%!-- Offered only where the write could be admitted (an ADMIN on the tenant plane,
                 with at least one page to empty), and it asks before it writes: the bulk empty is
                 the one action here that cannot be undone. --%>
            <%= if @purgeable and @pages != [] do %>
              <%= if @confirm_empty do %>
                <div
                  id="note-trash-empty-confirm"
                  class="note-confirm"
                  role="group"
                  aria-label="Empty the trash"
                >
                  <span class="note-confirm-question">
                    Delete all {length(@pages)} deleted pages forever?
                  </span>
                  <button
                    type="button"
                    id="note-trash-empty-yes"
                    class="note-confirm-yes"
                    phx-click="empty_trash"
                  >
                    Empty the trash
                  </button>
                  <button
                    type="button"
                    id="note-trash-empty-cancel"
                    class="note-control"
                    phx-click="cancel_empty_trash"
                    aria-label="Keep the trash"
                  >
                    Cancel
                  </button>
                </div>
              <% else %>
                <button
                  type="button"
                  id="note-trash-empty"
                  class="note-control"
                  phx-click="confirm_empty_trash"
                >
                  Empty the trash
                </button>
              <% end %>
            <% end %>
          </div>

          <p id="notes-trash-note" class="note-search-note">
            Deleted pages stay here until they are restored — or until an admin deletes one
            forever. Restoring brings back the page, its blocks and its place in the tree.
          </p>

          <div id="notes-trash-list" class="notes-tree" aria-label="Deleted pages">
            <%= if @pages == [] do %>
              <div id="notes-trash-empty" class="note-empty">
                <p class="note-empty-title">The trash is empty.</p>
                <p class="note-empty-body">
                  Pages you delete land here, so a mis-click is never the end of a page.
                </p>
              </div>
            <% else %>
              <div
                :for={page <- @pages}
                id={"note-trash-item-" <> to_string(page.id)}
                class="note-trash-item"
              >
                <span class="note-tree-icon" aria-hidden="true">{page.icon || "▤"}</span>
                <span class="note-tree-title">{page.title}</span>
                <span class="note-tree-meta">{deleted_line(page, @viewer_id)}</span>

                <button
                  :if={editable?(@samen_mount, @org_id)}
                  type="button"
                  id={"note-trash-restore-" <> to_string(page.id)}
                  class="note-control"
                  phx-click="restore_page"
                  phx-value-id={page.id}
                  aria-label={"Restore " <> to_string(page.title)}
                >
                  Restore
                </button>

                <%!-- Offered only where the write could be admitted (an ADMIN on the tenant
                     plane), and it asks before it writes: emptying the trash is the one action here
                     that cannot be undone. --%>
                <%= if @purgeable do %>
                  <%= if @confirm == page.id do %>
                    <div
                      id={"note-purge-confirm-" <> to_string(page.id)}
                      class="note-confirm"
                      role="group"
                      aria-label="Delete page permanently"
                    >
                      <span class="note-confirm-question">Delete “{page.title}” forever?</span>
                      <button
                        type="button"
                        id={"note-purge-yes-" <> to_string(page.id)}
                        class="note-confirm-yes"
                        phx-click="purge_page"
                        phx-value-id={page.id}
                      >
                        Delete forever
                      </button>
                      <button
                        type="button"
                        id={"note-purge-cancel-" <> to_string(page.id)}
                        class="note-control"
                        phx-click="cancel_purge"
                        aria-label="Keep the page"
                      >
                        Cancel
                      </button>
                    </div>
                  <% else %>
                    <button
                      type="button"
                      id={"note-trash-purge-" <> to_string(page.id)}
                      class="note-control"
                      phx-click="confirm_purge"
                      phx-value-id={page.id}
                      aria-label={"Delete " <> to_string(page.title) <> " forever"}
                    >
                      Delete forever
                    </button>
                  <% end %>
                <% end %>
              </div>

              <p :if={!editable?(@samen_mount, @org_id)} id="notes-trash-readonly" class="note-search-note">
                Restoring a deleted page is a write in the page's workspace — it is not offered
                from this plane.
              </p>

              <p
                :if={editable?(@samen_mount, @org_id) and not @purgeable}
                id="notes-trash-purge-admin-only"
                class="note-search-note"
              >
                Deleting a page forever (emptying the trash) is an admin action in this workspace.
              </p>
            <% end %>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  defp crumbs(mount, org_id) do
    [Crumbs.org(mount, org_id), Crumbs.section(mount, org_id, :pages), "Trash"]
  end

  # `mount/3` and `handle_params/3` set these; a direct caller (a render test) may hand in a bare
  # socket, so they are defaulted here rather than read unconditionally by the template.
  defp defaults(socket) do
    socket
    |> assign_new(:return_to, fn -> nil end)
    |> assign_new(:error, fn -> nil end)
    |> assign_new(:restored, fn -> nil end)
    |> assign_new(:viewer_id, fn -> nil end)
    |> assign_new(:confirm, fn -> nil end)
    |> assign_new(:confirm_empty, fn -> false end)
    |> assign_new(:emptied, fn -> nil end)
    |> assign_new(:purged, fn -> nil end)
    |> assign_new(:purgeable, fn -> false end)
  end

  defp no_org?(socket), do: CurrentOrg.no_org?(socket.assigns[:samen_mount], nil)

  # POSTURE only, the sibling surfaces' rule: the affordance is offered where the write it leads to
  # could be admitted, and the model refuses it everywhere else.
  defp editable?(mount, org_id), do: writable?(mount) and is_binary(org_id)

  # The purge is an ADMIN write ATTRIBUTED to a person, and neither `TenantRole` helper is both:
  # `admin_scope/3` supplies the ROLE (the disarmed dev posture's `:admin`, otherwise the caller's
  # real `Identity.Membership` rank) and `identity_scope/2` supplies the ATTRIBUTION (the
  # authenticated principal's `Identity.User` id instead of the workspace pseudo-principal). The
  # `record_purged` row wants both — who did it, and that they were entitled to — so the two are
  # composed here, once, and the OFFER below reads the very same role the model's gate will read.
  defp purge_scope(mount, org_id) do
    %Samen.Scope{actor: entitled} = TenantRole.admin_scope(mount, org_id)
    %Samen.Scope{actor: attributed} = TenantRole.identity_scope(mount, org_id)
    %Samen.Scope{actor: Map.put(entitled, :id, Map.get(attributed, :id))}
  end

  defp purgeable?(mount, org_id) do
    editable?(mount, org_id) and
      Samen.Scope.Role.at_least?(Map.get(purge_scope(mount, org_id).actor, :role), :admin)
  end

  defp pages_phrase(1), do: "1 page"
  defp pages_phrase(count), do: "#{count} pages"

  defp deleted_at(%DateTime{} = at), do: "deleted " <> Calendar.strftime(at, "%Y-%m-%d %H:%M")
  defp deleted_at(_), do: ""

  # WHEN, and WHO when the trail can name them. The label is a claim about identity, so each leg is
  # one the surface can stand behind — see the moduledoc; there is no "unknown person" wording,
  # because silence is the honest rendering of an absent audit row.
  defp deleted_line(page, viewer_id) do
    case deleted_by(page, viewer_id) do
      nil -> deleted_at(page.archived_at)
      who -> deleted_at(page.archived_at) <> " · by " <> render_who(who)
    end
  end

  # WHO, in order of specificity — see the moduledoc. The middle leg is the PII one: the name is
  # whatever the READ resolved on the acting plane, so a `%Samen.Masked{}` is rendered AS-IS
  # (`••••`) rather than compared, inspected, or unwrapped. A `%Samen.Masked{}` is truthy, so a
  # masked name always WINS over the coarse label: the operator plane renders the mask, and never
  # quietly substitutes a description of who the actor might be instead. The label legs are for the
  # case where no name is reachable at all — no audit actor, no Identity seam, no user row.
  defp deleted_by(page, viewer_id) do
    actor = Map.get(page, :deleted_by)

    cond do
      is_binary(viewer_id) and is_binary(actor) and actor == viewer_id -> "you"
      true -> Map.get(page, :deleted_by_name) || deleted_by_label(actor)
    end
  end

  defp render_who(%Samen.Masked{} = masked), do: to_string(masked)
  defp render_who(who), do: who

  defp deleted_by_label(nil), do: nil

  # `Mount.scope/2`'s fabricated per-org pseudo-principal: the trail records that the WORKSPACE
  # acted, which is exactly what it means.
  defp deleted_by_label("broker:" <> _org_id), do: "a workspace member"

  defp deleted_by_label(actor_id) when is_binary(actor_id), do: "another member"
  defp deleted_by_label(_actor_id), do: nil
end
