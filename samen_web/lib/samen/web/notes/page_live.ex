defmodule Samen.Web.Notes.PageLive do
  @moduledoc """
  The tenant **page editor** (WS-Notes Phase 3 unit 3.2; ADR-053 §2 D3/§4, §8 O2/O4).

  Mounted at `/pages/:id` by `Samen.Web.Router.samen_notes_routes/3`, through
  `Samen.Web.Tenant.Live` (a page-owned `render/1` is a compile error there, so this surface
  cannot render outside the chrome).

  ## The editor is server-rendered — no `contenteditable`, no client editor

  Each block is one `<textarea>` (a native control: the browser owns its value, LiveView
  value-diffs it, IME/paste/caret are the platform's). Every structural intent — split at a caret
  offset, merge, indent, move, open the palette — is a SERVER event carrying a block id and a
  bounded token; the `NoteBlock` hook reports intent and nothing else. Stored text is never HTML.

  ## Masking (INV-1)

  Everything rendered here comes from `Samen.Web.Notes.Reads`, which resolves each block's
  `text`/`text_secure` through `Samen.Api.PiiResolution` on the acting plane. A read-only render on
  a masked plane prints a `%Samen.Masked{}` value AS-IS (`••••` via its `Phoenix.HTML.Safe` impl) —
  the page never unwraps a mask, never reveals a `vt_*` token, and has no "show plaintext" branch.
  A masked WRITE is refused at the seam (a split/merge that would write `••••` into content), and
  the page shows that refusal instead of pretending the edit landed.

  ## The vault exit (ADR-053 §2 D5 / R17) is an ADMIN affordance, and it is a FORM

  A 🔒 block's text moves out of the vault only through `:declassify_text`, which is `RoleAtLeast
  :admin` and tenant-plane only. The editor surfaces that as ONE control per vaulted block
  (`Move out of the vault`) that opens a reason form and posts `declassify_block`; the write goes
  through `Writes.declassify/4` with `Samen.Web.TenantRole.admin_scope/2` — the REAL membership
  role on an armed host, never `Mount.scope/2`'s fabricated `:member`, which would make any role
  check here vacuous. A member's crafted event is therefore refused by the MODEL (policy), and
  the page shows the refusal instead of pretending it landed; the operator plane never offers the
  control at all (its text is `••••`, and a reveal grant is temporary while this is permanent).

  ## Concurrency

  Every text write carries the block `revision` the client last saw (a hidden field inside that
  block's own form), so a stale tab is refused with `{:error, :stale}` and the page shows the
  conflict banner (R9's UX half) rather than overwriting.

  ## Realtime: id-only envelopes, re-read per plane, never patch a focused control

  The editor subscribes to `Samen.Web.Notes.PubSub`'s per-page topic and every write broadcasts
  an ID-ONLY envelope (`{:block_changed, %{block_id, revision}}` /
  `{:page_structure_changed, %{doc_id, revision}}` — R8). A subscriber RE-READS through
  `Samen.Web.Notes.Reads` with its OWN scope, so a remote change resolves on the receiving
  viewer's plane; the broadcast itself never carries text and never carries a `vt_*` token.

  Two rules make that re-read safe for someone who is typing (R10):

    * the ONE exception to re-rendering is `editing_block_id` — the block whose `<textarea>` the
      user has focused is NOT patched, because a remote value would overwrite the caret the
      browser owns. The incoming id is remembered as `deferred_block_id` instead, and the block is
      re-read when that control BLURS; sabotage **357** removes the skip and the focused value
      changes under the user.
    * a structure change (split/merge/insert/move/archive) reloads the page; that is a list change
      the user is not editing inside a single control, and the block they ARE in is value-diffed
      against its unchanged text.

  ## Copy (R6's clipboard half)

  ## Deleting the page

  "Delete page" in the editor's action row is the SAME write the Pages index's row ✕ performs —
  `Samen.Web.Notes.Writes.archive_page/3`, a SOFT delete — and it asks the same one question first,
  with the confirm state on the socket rather than in the DOM. It is offered on the tenant plane
  only (`editable?/2`, this page's own posture for every write control); the model is what refuses.
  On success the editor leaves for the index, carrying `?deleted=<id>` so the page that was just
  removed is offered an UNDO there (`Notes.Live.deleted_href/3`) — the delete stays one click from
  being reversed. An id-only structure broadcast tells anyone else viewing this page that it is
  gone.

  ## Copy (R6's clipboard half)

  "Copy page" is the third export ADR-053 §5 D5 names, and the shortest path out of the app: the
  server renders `Samen.Web.Notes.Export.copy_text/3` (the same `Reads` seam, so the same plane
  decision) and PUSHES it to the requesting socket, where the `CopyText` hook hands it to
  `navigator.clipboard`. Nothing is embedded in the DOM and nothing is broadcast — a masked plane's
  copy is `••••`, so the clipboard can hold no more than the screen showed. The page only says
  "Copied" after the client reports it actually happened.
  """

  use Samen.Web.Tenant.Live

  import Samen.Web.CurrentOrg, only: [acting_as_banner: 1, no_org_card: 1, return_path: 1]

  import Samen.Web.Notes.Live,
    only: [
      assign_mount: 2,
      deleted_href: 3,
      export_href: 4,
      notes_sidebar: 1,
      page_href: 3,
      writable?: 1
    ]

  alias Samen.Web.{Crumbs, CurrentOrg, Mount, TenantRole}
  alias Samen.Web.Notes.{Export, PubSub, Reads, Writes}

  @list_types [:bulleted_list_item, :numbered_list_item, :to_do]

  @impl true
  def mount(params, session, socket) do
    socket = assign_mount(socket, session)
    org_id = CurrentOrg.resolve(socket.assigns[:samen_mount], params, session)

    {:ok,
     assign(socket,
       org_id: org_id,
       doc_id: nil,
       page: nil,
       no_org: false,
       not_found?: false,
       return_to: nil,
       palette_for: nil,
       conflict: nil,
       error: nil,
       editing_block_id: nil,
       deferred_block_id: nil,
       declassify_for: nil,
       declassify_allowed?: false,
       focus_request: nil,
       copy_state: nil,
       confirm_delete: false,
       backlinks: [],
       unresolved: []
     )}
  end

  @impl true
  def handle_params(%{"id" => doc_id} = params, uri, socket) do
    org_id = CurrentOrg.reresolve(socket, params)

    {:noreply,
     socket
     |> assign(
       org_id: org_id,
       return_to: return_path(uri),
       palette_for: nil,
       conflict: nil,
       error: nil,
       declassify_for: nil,
       focus_request: nil,
       copy_state: nil,
       confirm_delete: false
     )
     |> subscribe(doc_id)
     |> load(org_id, doc_id)}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @doc false
  def load(socket, org_id, doc_id) do
    mount = socket.assigns.samen_mount

    socket =
      socket
      |> defaults()
      |> assign(org_id: org_id, doc_id: doc_id)
      |> assign(declassify_allowed?: can_declassify?(mount, org_id))

    cond do
      is_nil(org_id) ->
        assign(socket,
          page: nil,
          no_org: no_org?(socket),
          not_found?: false,
          backlinks: [],
          unresolved: []
        )

      true ->
        scope = Mount.scope(mount, org_id)

        case Reads.page(mount, scope, doc_id) do
          {:ok, page} ->
            assign(socket,
              page: page,
              no_org: false,
              not_found?: false,
              backlinks: Reads.backlinks(mount, scope, doc_id),
              unresolved: Reads.unresolved(mount, scope, doc_id)
            )

          {:error, :not_found} ->
            assign(socket,
              page: nil,
              no_org: false,
              not_found?: true,
              backlinks: [],
              unresolved: []
            )
        end
    end
  end

  # ── text (the debounced write) ─────────────────────────────────────────────

  @impl true
  def handle_event("block_text", %{"block_id" => id, "text" => text} = params, socket) do
    with_scope(socket, fn mount, scope ->
      revision = integer(params["block_revision"])

      case Writes.update_text(mount, scope, id, text, revision: revision) do
        {:ok, block} ->
          {:noreply,
           socket
           |> publish_block(block)
           |> reload(conflict: nil, error: nil)}

        {:error, :stale} ->
          {:noreply, assign(socket, conflict: id, error: nil)}

        {:error, :masked} ->
          {:noreply, assign(socket, error: masked_message())}

        {:error, reason} ->
          {:noreply, assign(socket, error: write_error(reason))}
      end
    end)
  end

  # ── structure (the hook's intents) ─────────────────────────────────────────

  def handle_event("split_block", %{"id" => id, "offset" => offset}, socket) do
    with_scope(socket, fn mount, scope ->
      case Writes.split(mount, scope, id, offset) do
        {:ok, %{left: left, right: right}} ->
          socket =
            socket
            |> publish_block(left)
            |> publish_block(right)
            |> reload(error: nil)
            |> publish_structure()

          {:noreply, focus(socket, right.id)}

        {:ok, _other} ->
          {:noreply, socket |> reload(error: nil) |> publish_structure()}

        {:error, :stale} ->
          {:noreply, assign(socket, conflict: id)}

        {:error, reason} ->
          {:noreply, assign(socket, error: write_error(reason))}
      end
    end)
  end

  def handle_event("merge_block", %{"id" => id}, socket) do
    with_scope(socket, fn mount, scope ->
      case Writes.merge(mount, scope, id) do
        {:ok, %{block: survivor}} ->
          socket =
            socket
            |> publish_block(survivor)
            |> reload(error: nil)
            |> publish_structure()

          {:noreply, focus(socket, survivor.id)}

        {:ok, _noop} ->
          {:noreply, socket}

        {:error, :stale} ->
          {:noreply, assign(socket, conflict: id)}

        {:error, :masked} ->
          {:noreply, assign(socket, error: masked_message())}

        {:error, reason} ->
          {:noreply, assign(socket, error: write_error(reason))}
      end
    end)
  end

  def handle_event("indent_block", %{"id" => id, "direction" => direction}, socket) do
    direction = direction_atom(direction, [:in, :out])

    with_scope(socket, fn mount, scope ->
      case Writes.indent(mount, scope, id, direction) do
        {:ok, :noop} ->
          {:noreply, socket}

        {:ok, block} ->
          {:noreply,
           socket
           |> publish_block(block)
           |> reload(error: nil)
           |> publish_structure()}

        # A non-list block: the hook only reports indent for list types, so this is the server
        # refusing to widen what the client may ask for. Not a user-facing error.
        {:error, :not_indentable} ->
          {:noreply, socket}

        {:error, reason} ->
          {:noreply, assign(socket, error: write_error(reason))}
      end
    end)
  end

  def handle_event("move_block", %{"id" => id, "direction" => direction}, socket) do
    direction = direction_atom(direction, [:up, :down])

    with_scope(socket, fn mount, scope ->
      case Writes.move(mount, scope, id, direction) do
        {:ok, :noop} ->
          {:noreply, socket}

        {:ok, block} ->
          {:noreply,
           socket
           |> publish_block(block)
           |> reload(error: nil)
           |> publish_structure()}

        {:error, reason} ->
          {:noreply, assign(socket, error: write_error(reason))}
      end
    end)
  end

  def handle_event("toggle_checked", %{"id" => id}, socket) do
    with_scope(socket, fn mount, scope ->
      case Writes.toggle_checked(mount, scope, id) do
        {:ok, block} ->
          {:noreply,
           socket
           |> publish_block(block)
           |> reload(error: nil)
           |> publish_structure()}

        {:error, :not_checkable} ->
          {:noreply, socket}

        {:error, :stale} ->
          {:noreply, assign(socket, conflict: id)}

        {:error, reason} ->
          {:noreply, assign(socket, error: write_error(reason))}
      end
    end)
  end

  def handle_event("archive_block", %{"id" => id}, socket) do
    with_scope(socket, fn mount, scope ->
      case Writes.archive(mount, scope, id) do
        {:ok, _block} ->
          {:noreply, socket |> reload(error: nil) |> publish_structure()}

        {:error, reason} ->
          {:noreply, assign(socket, error: write_error(reason))}
      end
    end)
  end

  # ── palette ────────────────────────────────────────────────────────────────

  def handle_event("open_palette", %{"id" => id}, socket) do
    {:noreply, assign(socket, palette_for: id, conflict: nil)}
  end

  def handle_event("close_palette", _params, socket) do
    {:noreply, assign(socket, palette_for: nil)}
  end

  def handle_event("insert_block", %{"type" => type, "after" => after_id}, socket) do
    with_scope(socket, fn mount, scope ->
      doc_id = socket.assigns.doc_id
      attrs = insert_attrs(socket, type, after_id)

      case Writes.insert_block(mount, scope, doc_id, attrs) do
        {:ok, block} ->
          socket =
            socket
            |> publish_block(block)
            |> assign(palette_for: nil)
            |> reload(error: nil)
            |> publish_structure()

          {:noreply, focus(socket, block.id)}

        {:error, reason} ->
          {:noreply, assign(socket, error: write_error(reason), palette_for: nil)}
      end
    end)
  end

  # ── unresolved links (the "create this page" affordance) ───────────────────

  def handle_event("create_linked_page", %{"title" => title}, socket) when is_binary(title) do
    with_scope(socket, fn mount, scope ->
      # Creating the page persists nothing about the LINK: the affordance only becomes a real
      # `DocLink` when this page's text is re-resolved against the new title.
      with {:ok, _doc} <- Writes.create_page(mount, scope, %{title: title}),
           {:ok, _links} <- Writes.sync_links(mount, scope, socket.assigns.doc_id) do
        # The new page is elsewhere; what changed HERE is the unresolved-links list and (possibly)
        # a `DocLink` row — a structure signal for anyone viewing this page.
        {:noreply, socket |> reload(error: nil) |> publish_structure()}
      else
        {:error, reason} -> {:noreply, assign(socket, error: write_error(reason))}
      end
    end)
  end

  # ── the named door out of the vault (R17) ──────────────────────────────────

  def handle_event("open_declassify", %{"id" => id}, socket) do
    # The control is only rendered to an admin on the tenant plane; a crafted event opens the form
    # for anyone, and the WRITE below is what refuses (policy, not posture).
    {:noreply, assign(socket, declassify_for: id, palette_for: nil, conflict: nil, error: nil)}
  end

  def handle_event("cancel_declassify", _params, socket) do
    {:noreply, assign(socket, declassify_for: nil)}
  end

  def handle_event("declassify_block", %{"block_id" => id, "reason" => reason}, socket) do
    with_scope(socket, fn mount, _scope ->
      # ADMIN-ranked, and derived through the ONE tenant-role helper (see the moduledoc): on an
      # armed host this is the authenticated principal's real membership role, and `Writes.
      # declassify/4`'s action re-checks it against the model's policy.
      admin_scope = TenantRole.admin_scope(mount, socket.assigns.org_id)

      case Writes.declassify(mount, admin_scope, id, reason) do
        {:ok, block} ->
          {:noreply,
           socket
           |> assign(declassify_for: nil)
           |> publish_block(block)
           |> reload(error: nil)}

        {:error, :forbidden} ->
          {:noreply, assign(socket, error: declassify_forbidden_message())}

        {:error, :no_reason} ->
          {:noreply, assign(socket, error: declassify_reason_message())}

        {:error, reason} ->
          {:noreply, assign(socket, error: write_error(reason))}
      end
    end)
  end

  # ── conflict / focus ───────────────────────────────────────────────────────

  def handle_event("reload_block", %{"id" => _id}, socket) do
    {:noreply, reload(socket, conflict: nil, error: nil)}
  end

  def handle_event("dismiss_conflict", _params, socket) do
    {:noreply, assign(socket, conflict: nil)}
  end

  def handle_event("focus_block", %{"id" => id}, socket) do
    {:noreply, assign(socket, editing_block_id: id)}
  end

  def handle_event("blur_block", %{"id" => id}, socket) do
    socket = assign(socket, editing_block_id: nil)

    # Leaving the control is when a change that arrived WHILE it was focused is finally applied
    # (R10's second half): the skip above is a deferral, never a drop.
    if to_string(socket.assigns[:deferred_block_id]) == to_string(id) do
      {:noreply, socket |> assign(deferred_block_id: nil) |> refresh_block(id)}
    else
      {:noreply, socket}
    end
  end

  # ── the copy (R6's clipboard half) ─────────────────────────────────────────

  # The payload is the `Export.copy_text/3` artifact — the SAME read seam the render uses — pushed
  # to the requesting socket, where the `CopyText` hook hands it to the clipboard. Nothing is
  # broadcast and nothing is pre-rendered into the DOM: a masked plane's copy is `••••`, so the
  # clipboard can hold no more than the screen showed.
  def handle_event("copy_page", _params, socket) do
    with_scope(socket, fn mount, scope ->
      case Export.copy_text(mount, scope, socket.assigns.doc_id) do
        {:ok, %{body: text}} ->
          {:noreply,
           socket
           |> assign(copy_state: nil)
           |> push_event("copy_text", %{text: text})}

        {:error, _reason} ->
          {:noreply, assign(socket, copy_state: :unavailable)}
      end
    end)
  end

  # The client reports what actually happened to the clipboard. The page never claims "Copied" on
  # its own: with no JS, no permission or no `navigator.clipboard` there is no ack, and the row
  # stays quiet rather than lying (the fail-honest posture, applied to an affordance).
  def handle_event("copied", _params, socket), do: {:noreply, assign(socket, copy_state: :copied)}

  # ── deleting the page (the index row's ✕, from the editor) ────────────────

  # Two-step, server-side, exactly like the index: the button only NAMES the page it would remove,
  # so the confirmation works with no JavaScript and a mis-click removes nothing.
  def handle_event("confirm_delete", _params, socket) do
    {:noreply, assign(socket, confirm_delete: true, error: nil)}
  end

  def handle_event("cancel_delete", _params, socket) do
    {:noreply, assign(socket, confirm_delete: false)}
  end

  def handle_event("delete_page", _params, socket) do
    with_identity_scope(socket, fn mount, scope ->
      case Writes.archive_page(mount, scope, socket.assigns.doc_id) do
        {:ok, doc} ->
          # Anyone else viewing this page learns it is gone the way every structural change
          # travels: an id-only envelope their own read answers with `:not_found`.
          PubSub.broadcast_page_structure_changed(
            mount,
            to_string(doc.id),
            doc.id,
            Map.get(doc, :revision)
          )

          # Leave for the index WITH the undo carrier: the page the user just removed is the one
          # the notice offers back, and nothing about that needs a second state store.
          {:noreply,
           push_navigate(
             socket,
             to: deleted_href(mount, socket.assigns.org_id, doc.id)
           )}

        {:error, :not_found} ->
          # Already gone (another tab, or an operator): say so rather than claim a delete that
          # did not happen here.
          {:noreply,
           assign(socket,
             confirm_delete: false,
             error: "This page is already gone — it was deleted or archived elsewhere."
           )}

        {:error, reason} ->
          {:noreply, assign(socket, confirm_delete: false, error: write_error(reason))}
      end
    end)
  end

  def handle_event("copy_unavailable", _params, socket),
    do: {:noreply, assign(socket, copy_state: :unavailable)}

  # ── realtime (the id-only broadcast, re-read per THIS viewer's plane) ──────

  @impl true
  def handle_info({:block_changed, %{block_id: block_id}}, socket) do
    cond do
      is_nil(socket.assigns[:page]) ->
        {:noreply, socket}

      # THE GUARD (R10): the control the user is typing into is never patched from a broadcast —
      # the browser owns that value and its caret. Defer it until the control blurs.
      editing?(socket, block_id) ->
        {:noreply, assign(socket, deferred_block_id: to_string(block_id))}

      true ->
        {:noreply, refresh_block(socket, block_id)}
    end
  end

  def handle_info({:page_structure_changed, %{doc_id: doc_id}}, socket) do
    if to_string(doc_id) == to_string(socket.assigns[:doc_id]) do
      {:noreply, reload(socket, [])}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # The subscription dies with the process, but unsubscribing explicitly keeps the contract in one
  # place (and a future `handle_params` re-subscribe cannot leak a topic per navigation).
  @impl true
  def terminate(_reason, socket) do
    case socket.assigns[:doc_id] do
      doc_id when is_binary(doc_id) -> PubSub.unsubscribe(socket.assigns.samen_mount, doc_id)
      _ -> :ok
    end

    :ok
  end

  # ── render ─────────────────────────────────────────────────────────────────

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
    <div id="notes-page">
      <.topbar title={page_title(@page)} crumbs={crumbs(@samen_mount, @org_id, @page)} />

      <.acting_as_banner mount={@samen_mount} org_id={@org_id} acting_as={@samen_acting_as} />

      <%= cond do %>
        <% @no_org -> %>
          <.no_org_card mount={@samen_mount} />
        <% @not_found? -> %>
          <div class="wrap">
            <div id="notes-not-found">
              <.empty_state
                title="Page not found"
                body="This page is not in your workspace. It may have been archived, or it belongs to another organization."
                icon="▤"
              />
            </div>
          </div>
        <% @page -> %>
          <div class="wrap">
            <div :if={@error} id="notes-page-error" class="note-error" role="alert">{@error}</div>

            <.note_conflict_banner :if={@conflict} block_id={@conflict} />

            <.note_palette :if={@palette_for} block_id={@palette_for} />

            <%!-- The reason form is the vault exit's whole surface: it collects WHY and posts
                 `declassify_block`. Rendered only where the write it leads to could be admitted. --%>
            <.note_declassify_form
              :if={@declassify_for && @declassify_allowed?}
              block_id={@declassify_for}
            />

            <div
              id="note-blocks"
              class="note-editor"
              data-editing={@editing_block_id || ""}
              data-focus-request={@focus_request || ""}
            >
              <.note_block_row
                :for={block <- @page.blocks}
                block={block}
                editable={editable?(@samen_mount, @org_id)}
                editing={@editing_block_id == block.id}
              >
                <:controls>
                  <button
                    type="button"
                    id={"note-move-up-" <> block.id}
                    class="note-control"
                    phx-click="move_block"
                    phx-value-id={block.id}
                    phx-value-direction="up"
                    aria-label="Move block up"
                  >↑</button>
                  <button
                    type="button"
                    id={"note-move-down-" <> block.id}
                    class="note-control"
                    phx-click="move_block"
                    phx-value-id={block.id}
                    phx-value-direction="down"
                    aria-label="Move block down"
                  >↓</button>
                  <button
                    :if={list_type?(block.type)}
                    type="button"
                    id={"note-indent-" <> block.id}
                    class="note-control"
                    phx-click="indent_block"
                    phx-value-id={block.id}
                    phx-value-direction="in"
                    aria-label="Indent block"
                  >⇥</button>
                  <button
                    :if={list_type?(block.type)}
                    type="button"
                    id={"note-outdent-" <> block.id}
                    class="note-control"
                    phx-click="indent_block"
                    phx-value-id={block.id}
                    phx-value-direction="out"
                    aria-label="Outdent block"
                  >⇤</button>
                  <button
                    :if={block.type == :to_do}
                    type="button"
                    id={"note-check-" <> block.id}
                    class="note-control"
                    phx-click="toggle_checked"
                    phx-value-id={block.id}
                    aria-pressed={to_string(block.checked == true)}
                    aria-label="Toggle done"
                  >{if block.checked, do: "☑", else: "☐"}</button>
                  <button
                    type="button"
                    id={"note-archive-" <> block.id}
                    class="note-control"
                    phx-click="archive_block"
                    phx-value-id={block.id}
                    aria-label="Archive block"
                  >✕</button>

                  <%!-- ADR-053 §2 D5 / R17 — the ONLY affordance that can clear a classification.
                       ADMIN on the tenant plane only: the operator plane reads `••••` here and
                       never gets the control (a reveal is temporary; this is permanent). --%>
                  <button
                    :if={@declassify_allowed? and block.secure?}
                    type="button"
                    id={"note-declassify-" <> block.id}
                    class="note-control"
                    phx-click="open_declassify"
                    phx-value-id={block.id}
                    aria-label="Move this block out of the vault"
                  >🔓</button>
                </:controls>
              </.note_block_row>
            </div>

            <.note_empty_state :if={@page.blocks == [] and is_nil(@page.legacy)} />

            <div :if={@backlinks != []} id="note-backlinks" class="note-links">
              <h2 class="note-links-title">Linked from</h2>
              <a
                :for={link <- @backlinks}
                id={"note-backlink-" <> link.source_id}
                class="note-backlink"
                href={page_href(@samen_mount, @org_id, link.source_id)}
              >
                <span class="note-backlink-title">{link.source_title}</span>
                <span class="note-backlink-anchor">“{link.anchor_text}”</span>
                <span :if={link.stale?} class="note-link-stale">
                  link may point at an older title
                </span>
              </a>
            </div>

            <div :if={@unresolved != []} id="note-unresolved" class="note-links">
              <h2 class="note-links-title">Unresolved links</h2>
              <div
                :for={{title, index} <- Enum.with_index(@unresolved)}
                id={"note-unresolved-" <> to_string(index)}
                class="note-unresolved-row"
              >
                <span class="note-unresolved-title">{title}</span>
                <button
                  :if={editable?(@samen_mount, @org_id)}
                  type="button"
                  id={"note-create-link-" <> to_string(index)}
                  class="btn"
                  phx-click="create_linked_page"
                  phx-value-title={title}
                >Create page</button>
              </div>
            </div>

            <div :if={@page.legacy} id="note-legacy" class="note-legacy">
              <p class="note-legacy-note">
                This page has no blocks yet, so it shows its original body — read-only. Add a
                block to start editing it paragraph by paragraph.
              </p>
              <div class="note-legacy-body" id="note-legacy-body">
                <%= if is_binary(@page.legacy.text) do %>
                  {Samen.Web.Notes.Inline.render(@page.legacy.text)}
                <% else %>
                  {@page.legacy.text}
                <% end %>
              </div>
            </div>

            <div class="note-editor-actions">
              <button
                :if={editable?(@samen_mount, @org_id)}
                type="button"
                id="note-add-block"
                class="btn"
                phx-click="open_palette"
                phx-value-id="end"
              >Add a block</button>

              <%!-- WS-Notes unit 2.4 (ADR-053 §6 R6) — the page download. Offered on EVERY
                   plane: the export renders through `Notes.Reads`, so a masked plane downloads
                   masks (hiding the link would be posture, not protection). --%>
              <a
                id="note-export-md"
                class="btn"
                href={export_href(@samen_mount, @org_id, @page.doc.id, :md)}
                download
              >Download Markdown</a>
              <a
                id="note-export-csv"
                class="btn"
                href={export_href(@samen_mount, @org_id, @page.doc.id, :csv)}
                download
              >Download CSV</a>

              <%!-- WS-Notes unit 2.4 (ADR-053 §5 D5, §6 R6) — the page COPY. The server pushes the
                   `Export.copy_text/3` artifact (same read seam, same plane) and the `CopyText`
                   hook writes it to the clipboard; nothing is rendered into an attribute, so a
                   masked plane's copy is `••••` and the clipboard cannot out-see the screen. --%>
              <button
                id="note-copy-page"
                type="button"
                class="btn"
                phx-click="copy_page"
                phx-hook="CopyText"
              >Copy page</button>

              <span :if={@copy_state == :copied} id="note-copy-status" class="note-copy-status">
                Copied
              </span>              <span
                :if={@copy_state == :unavailable}
                id="note-copy-status"
                class="note-copy-status"
                role="status"
              >
                Copy is unavailable in this browser — use Download Markdown.
              </span>

              <%!-- The editor's page delete: the SAME seam (and the same one-question confirm) as
                   the Pages index row's ✕. Tenant-plane posture only; the model's `OrgScope` +
                   `RoleAtLeast :member` decide, and the write is a SOFT delete. --%>
              <%= if editable?(@samen_mount, @org_id) do %>
                <%= if @confirm_delete do %>
                  <div
                    id="note-delete-page-confirm"
                    class="note-confirm"
                    role="group"
                    aria-label="Delete page"
                  >
                    <span class="note-confirm-question">Delete “{page_title(@page)}”?</span>
                    <%!-- The delete takes the subtree too (`CascadeArchive`), and this editor does
                         not load a child count, so the copy states the RULE rather than a number
                         it does not have. --%>
                    <span class="note-confirm-detail">Its subpages are deleted with it.</span>
                    <button
                      type="button"
                      id="note-delete-page-yes"
                      class="note-confirm-yes"
                      phx-click="delete_page"
                    >Delete page</button>
                    <button
                      type="button"
                      id="note-delete-page-cancel"
                      class="note-control"
                      phx-click="cancel_delete"
                      aria-label="Keep the page"
                    >Cancel</button>
                  </div>
                <% else %>
                  <button
                    type="button"
                    id="note-delete-page"
                    class="btn"
                    phx-click="confirm_delete"
                    aria-label={"Delete " <> page_title(@page)}
                  >✕ Delete page</button>
                <% end %>
              <% end %>
            </div>
          </div>
      <% end %>
    </div>
    """
  end

  # ── internals ──────────────────────────────────────────────────────────────

  # Every mutating handler runs through here: no org ⇒ no scope ⇒ no write, and the page answers
  # exactly as it does on a read (nothing happened, nothing is claimed).
  #
  defp with_scope(%{assigns: %{samen_mount: %Mount{} = mount, org_id: org_id}}, fun)
       when is_binary(org_id) do
    fun.(mount, Mount.scope(mount, org_id))
  end

  defp with_scope(socket, _fun), do: {:noreply, socket}

  # The DELETE (and only the delete) runs on `TenantRole.identity_scope/2` — `Mount.scope/2`'s
  # authority with the acting principal's id when the host can resolve one. Its governance row is
  # the one the Trash view reads back as "who deleted this page", so it is the one write that must
  # name a person; the block writes above keep the plain scope (attribution is not what they are
  # for, and they run on every keystroke).
  defp with_identity_scope(%{assigns: %{samen_mount: %Mount{} = mount, org_id: org_id}}, fun)
       when is_binary(org_id) do
    fun.(mount, TenantRole.identity_scope(mount, org_id))
  end

  defp with_identity_scope(socket, _fun), do: {:noreply, socket}

  # Reload the CURRENT document, preserving the navigation assigns; callers pass the transient
  # assigns this write settled (a cleared conflict, a fresh error).
  defp reload(socket, extra) when is_list(extra) do
    %{org_id: org_id, doc_id: doc_id} = socket.assigns
    socket = assign(socket, extra)

    load(socket, org_id, doc_id)
  end

  defp focus(socket, block_id) do
    socket
    |> assign(focus_request: block_id)
    |> push_event("focus_block", %{id: to_string(block_id)})
  end

  # ── realtime internals ─────────────────────────────────────────────────────

  defp subscribe(socket, doc_id) when is_binary(doc_id) do
    if connected?(socket), do: PubSub.subscribe(socket.assigns.samen_mount, doc_id)
    socket
  end

  defp subscribe(socket, _doc_id), do: socket

  # An id-only broadcast becomes a plane-correct block because this is the SAME read seam the
  # page rendered through — never the value that rode the wire (there is none).
  defp refresh_block(%{assigns: %{page: nil}} = socket, _block_id), do: socket

  defp refresh_block(socket, block_id) do
    mount = socket.assigns.samen_mount
    scope = Mount.scope(mount, socket.assigns.org_id)

    case Reads.block(mount, scope, block_id) do
      {:ok, block} ->
        assign(socket, page: replace_block(socket.assigns.page, block))

      # Removed (or archived) remotely: the authoritative list is the page read.
      {:error, :not_found} ->
        reload(socket, [])
    end
  end

  defp replace_block(%{blocks: blocks} = page, block) do
    %{
      page
      | blocks:
          Enum.map(blocks, fn existing ->
            if existing.id == block.id, do: block, else: existing
          end)
    }
  end

  defp editing?(socket, block_id) do
    case socket.assigns[:editing_block_id] do
      nil -> false
      editing -> to_string(editing) == to_string(block_id)
    end
  end

  # Broadcasts are best-effort (see `Samen.Web.Notes.PubSub`): the write already committed, so a
  # missing PubSub server changes nothing the writer sees.
  defp publish_block(socket, block) do
    PubSub.broadcast_block_changed(socket.assigns.samen_mount, socket.assigns.doc_id, block)
    socket
  end

  # The page revision is read AFTER the reload, so the envelope carries the value a subscriber's
  # own page read will see rather than a guess.
  defp publish_structure(%{assigns: %{page: %{doc: doc}}} = socket) do
    PubSub.broadcast_page_structure_changed(
      socket.assigns.samen_mount,
      socket.assigns.doc_id,
      doc.id,
      Map.get(doc, :revision)
    )

    socket
  end

  defp publish_structure(socket), do: socket

  defp insert_attrs(socket, type, after_id) do
    base = %{type: type, text: ""}

    case after_id do
      "start" ->
        case first_block_id(socket) do
          nil -> base
          id -> Map.put(base, :before_block_id, id)
        end

      id when id in [nil, "", "end"] ->
        base

      id ->
        Map.put(base, :after_block_id, id)
    end
  end

  defp first_block_id(%{assigns: %{page: %{blocks: [block | _]}}}), do: block.id
  defp first_block_id(_), do: nil

  defp direction_atom(direction, allowed) when is_binary(direction) do
    Enum.find(allowed, :unknown, &(Atom.to_string(&1) == direction))
  end

  defp direction_atom(direction, allowed) when is_atom(direction),
    do: if(direction in allowed, do: direction, else: :unknown)

  defp direction_atom(_direction, _allowed), do: :unknown

  defp integer(value) when is_integer(value), do: value

  defp integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp integer(_), do: nil

  defp editable?(mount, org_id), do: writable?(mount) and is_binary(org_id)

  # The vault exit is offered only where the write could be admitted: tenant plane + a real
  # admin-rank membership role (ADR-053 §2 D5). The model re-checks both — this decides whether
  # the affordance is OFFERED, never whether the write lands.
  defp can_declassify?(%Mount{} = mount, org_id) when is_binary(org_id) do
    writable?(mount) and
      Samen.Scope.Role.at_least?(TenantRole.admin_scope(mount, org_id).actor.role, :admin)
  end

  defp can_declassify?(_mount, _org_id), do: false

  defp list_type?(type), do: type in @list_types

  defp page_title(%{doc: %{title: title}}) when is_binary(title), do: title
  defp page_title(_), do: "Page"

  defp crumbs(mount, org_id, nil) do
    [Crumbs.org(mount, org_id), Crumbs.section(mount, org_id, :pages)]
  end

  defp crumbs(mount, org_id, %{doc: doc}) do
    [
      Crumbs.org(mount, org_id),
      Crumbs.section(mount, org_id, :pages),
      doc.title
    ]
  end

  # `mount/3` and `handle_params/3` set these; a direct caller (a render test) may hand in a bare
  # socket, so they are defaulted here rather than read unconditionally by the template.
  defp defaults(socket) do
    socket
    |> assign_new(:return_to, fn -> nil end)
    |> assign_new(:palette_for, fn -> nil end)
    |> assign_new(:conflict, fn -> nil end)
    |> assign_new(:error, fn -> nil end)
    |> assign_new(:declassify_for, fn -> nil end)
    |> assign_new(:declassify_allowed?, fn -> false end)
    |> assign_new(:editing_block_id, fn -> nil end)
    |> assign_new(:deferred_block_id, fn -> nil end)
    |> assign_new(:focus_request, fn -> nil end)
    |> assign_new(:backlinks, fn -> [] end)
    |> assign_new(:unresolved, fn -> [] end)
    |> assign_new(:copy_state, fn -> nil end)
    |> assign_new(:confirm_delete, fn -> false end)
  end

  defp no_org?(socket), do: CurrentOrg.no_org?(socket.assigns[:samen_mount], nil)

  defp masked_message do
    "This block is masked on this plane — writing it would put the mask into the page's content."
  end

  defp declassify_forbidden_message do
    "Only an admin can move content out of the vault. This block is unchanged — if you need it " <>
      "in the clear, an admin has to do it and record a reason."
  end

  defp declassify_reason_message do
    "Give a reason: the audit entry is the record of why this text is no longer confidential, and " <>
      "it cannot be empty."
  end

  defp write_error(%Ash.Error.Invalid{}), do: "That change was refused by the page's write rules."
  defp write_error(reason) when is_atom(reason), do: "The change was not applied (#{reason})."
  defp write_error(_reason), do: "The change was not applied."
end
