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

  ## Honest states

    * no org resolvable → `.no_org_card` (the framework's "you are not acting in an org" card);
    * an org with no pages → the `note_empty_state/1` kit card, which offers the first block
      instead of a blank tree;
    * a failed create → an alert banner; the page never redirects as if it had succeeded.
  """

  use Samen.Web.Tenant.Live

  import Samen.Web.CurrentOrg, only: [acting_as_banner: 1, no_org_card: 1, return_path: 1]
  import Samen.Web.Notes.Live, only: [assign_mount: 2, notes_sidebar: 1, page_href: 3]

  alias Samen.Web.{Crumbs, CurrentOrg, Mount}
  alias Samen.Web.Notes.{Reads, Search, Writes}

  @impl true
  def mount(params, session, socket) do
    socket = assign_mount(socket, session)
    org_id = CurrentOrg.resolve(socket.assigns[:samen_mount], params, session)

    {:ok,
     socket
     |> assign(org_id: org_id, return_to: nil, error: nil)
     |> load(org_id, q(params))}
  end

  @impl true
  def handle_params(params, uri, socket) do
    org_id = CurrentOrg.reresolve(socket, params)

    {:noreply,
     socket
     |> assign(org_id: org_id, return_to: return_path(uri))
     |> load(org_id, q(params))}
  end

  @doc false
  def load(socket, org_id, q \\ "")

  def load(socket, nil, q) do
    socket
    |> defaults()
    |> assign(pages: [], results: [], q: q, no_org: no_org?(socket), org_id: nil)
  end

  def load(socket, org_id, q) do
    socket = defaults(socket)
    mount = socket.assigns.samen_mount
    scope = Mount.scope(mount, org_id)

    {:ok, pages} = Reads.index(mount, scope)
    results = if q == "", do: [], else: Search.search(mount, scope, q)

    assign(socket, pages: pages, results: results, q: q, no_org: false, org_id: org_id)
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

    case is_binary(org_id) && Writes.create_page(mount, Mount.scope(mount, org_id), %{title: title}) do
      {:ok, doc} ->
        {:noreply, push_navigate(socket, to: page_href(mount, org_id, doc.id))}

      _ ->
        {:noreply, assign(socket, error: "The page could not be created.")}
    end
  end

  def handle_event("create_page", _params, socket) do
    {:noreply, assign(socket, error: "The page could not be created.")}
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
                <a
                  :for={page <- @pages}
                  id={"note-tree-row-" <> page.id}
                  class="note-tree-row"
                  href={page_href(@samen_mount, @org_id, page.id)}
                  data-parent={page.parent_doc_id || ""}
                >
                  <span class="note-tree-icon" aria-hidden="true">{page.icon || "▤"}</span>
                  <span class="note-tree-title">{page.title}</span>
                  <span class="note-tree-meta">{edited_at(page.updated_at)}</span>
                </a>
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
  end

  defp no_org?(socket), do: CurrentOrg.no_org?(socket.assigns[:samen_mount], nil)

  defp edited_at(%DateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M")
  defp edited_at(_), do: ""
end
