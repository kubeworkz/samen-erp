defmodule Samen.Web.Notes.Live do
  @moduledoc """
  Shared helpers for the two WS-Notes TENANT surfaces — `Samen.Web.Notes.IndexLive` (the page
  list) and `Samen.Web.Notes.PageLive` (the block editor) — kept in one module so the sidebar,
  the write POSTURE and the page-href threading cannot drift between them (ADR-053 §8 O4;
  WS-Notes Phase 3).

  Nothing here reads a value: the pages render blocks that `Samen.Web.Notes.Reads` already
  resolved through `Samen.Api.PiiResolution` on the acting plane, and this module only composes
  chrome around them (the same posture `Samen.Web.Files.Live` and `Samen.Web.Notifications.Live`
  take for their surfaces).
  """

  use Phoenix.Component

  import Samen.UI
  import Samen.Web.CurrentOrg, only: [switcher: 1]

  alias Samen.Web.CurrentOrg
  alias Samen.Web.Mount

  @doc "Read the mount out of the session (see `Samen.Web.Live.assign_mount/2`)."
  defdelegate assign_mount(socket, session), to: Samen.Web.Live

  @doc """
  Whether the editing affordances are OFFERED on this mount — tenant plane only.

  POSTURE only, exactly as the sibling modules state it: the kernel (`OrgScope` +
  `RoleAtLeast role: :member` on `Doc`/`DocBlock`) is what refuses a write, and a masked
  operator-plane read is refused at the `Reads` seam. The page does not enforce anything by
  hiding a button.
  """
  def writable?(%Mount{plane: %{kind: :operator}}), do: false
  def writable?(_), do: true

  @doc """
  One page's href under this mount — the `:pages_path` label the route macro set, with the
  `?org=` thread every tenant link in the framework carries.

  `org_id` is omitted when unresolved (the session-pinned org still resolves server-side, the
  same fallback the wizard's `:tenant_landing` CTA uses).
  """
  @spec page_href(Mount.t(), String.t() | nil, term()) :: String.t()
  def page_href(mount, org_id, doc_id) do
    base = "#{Mount.label(mount, :pages_path, "/pages")}/#{doc_id}"

    case org_id do
      org_id when is_binary(org_id) and org_id != "" -> "#{base}?org=#{org_id}"
      _ -> base
    end
  end

  @doc """
  One page's DOWNLOAD href under this mount — `/pages/:id/export.md` or `/export.csv`, the
  `Samen.Web.Notes.ExportController` routes `samen_notes_routes/3` mounts beside the editor
  (WS-Notes Phase 2 unit 2.4).

  Threaded with the same `?org=` the page links carry, so the download resolves the same org the
  viewer is in. Export is safe on every plane (the renderer reads through `Notes.Reads`), which is
  why this helper has no plane branch — hiding the link would be posture, not protection.
  """
  @spec export_href(Mount.t(), String.t() | nil, term(), :md | :csv) :: String.t()
  def export_href(mount, org_id, doc_id, format) when format in [:md, :csv] do
    base = "#{Mount.label(mount, :pages_path, "/pages")}/#{doc_id}/export.#{format}"

    case org_id do
      org_id when is_binary(org_id) and org_id != "" -> "#{base}?org=#{org_id}"
      _ -> base
    end
  end

  @doc "The index href for this mount."
  @spec index_href(Mount.t(), String.t() | nil) :: String.t()
  def index_href(mount, org_id) do
    base = Mount.label(mount, :pages_path, "/pages")

    case org_id do
      org_id when is_binary(org_id) and org_id != "" -> "#{base}?org=#{org_id}"
      _ -> base
    end
  end

  attr :mount, Mount, required: true
  attr :org_id, :string, default: nil
  attr :active, :atom, default: :pages
  attr :return_to, :string, default: nil

  @doc """
  The Pages sidebar — workspace header + the inherited `module_nav` with the Documents group's
  Pages item active.

  `module_nav/1` renders the Documents group ONLY when the host threads `:files_path` or
  `:pages_path`, so a host that mounted neither never sees a link to a route it does not have
  (X1 / ADR-045 §4.1).
  """
  def notes_sidebar(assigns) do
    ~H"""
    <.sidebar
      title={CurrentOrg.name(@mount, @org_id)}
      subtitle="Pages"
      logo={Mount.label(@mount, :glyph, "S")}
      logo_style={Mount.label(@mount, :crm_logo_style, "background:linear-gradient(150deg,#0F766E,#14B8A6)")}
    >
      <:switcher>
        <.switcher mount={@mount} org_id={@org_id} return_to={@return_to} compact />
      </:switcher>

      <.module_nav {Samen.UI.nav_paths(@mount)} org_id={@org_id} active={@active}>
        <:extra><.host_nav_extra mount={@mount} org_id={@org_id} /></:extra>
      </.module_nav>

      <:footer>
        <div class="foot">
          <div class="av" style="background:#CCFBF1;color:#0F766E">{Mount.label(@mount, :user_initials, "S")}</div>
          <div class="m">
            <b>{Mount.label(@mount, :user_name, "Signed in")}</b>
            <span>{Mount.label(@mount, :user_role, "member")}</span>
          </div>
          <.logout_form />
        </div>
      </:footer>
    </.sidebar>
    """
  end
end
