defmodule Samen.Web.Erp.Live do
  @moduledoc """
  Shared ERP LiveView helpers: mount assignment + the host-agnostic ERP sidebar
  (workspace branding from `mount.labels`, defaults neutral). Same ADR-009 pattern as
  `Samen.Web.Billing.Live`.

  The sidebar exists so an ERP page is a SHELL page like every other module page: the
  `Samen.UI.module_nav/1` ERP group (and every inherited group) is reachable FROM a
  `/erp/:surface` render, instead of the bare table-with-no-navigation the surface used
  to serve.
  """
  use Phoenix.Component

  import Samen.UI
  import Samen.Web.CurrentOrg, only: [switcher: 1]

  alias Samen.Web.CurrentOrg
  alias Samen.Web.Mount

  defdelegate assign_mount(socket, session), to: Samen.Web.Live

  @doc """
  The UI write posture — write affordances are offered on the TENANT plane only
  (the same `writable?/1` CRM and Billing carry). The kernel enforces
  `OrgScope` + `RoleAtLeast :member` on every write regardless; this only
  keeps the operator/impersonation DOM free of forms an operator must never
  author into a tenant's books.
  """
  @spec writable?(Mount.t()) :: boolean()
  def writable?(%Mount{plane: %{kind: :operator}}), do: false
  def writable?(_), do: true

  attr :mount, Mount, required: true
  attr :org_id, :string, default: nil
  attr :active, :atom, default: nil
  attr :return_to, :string, default: nil

  @doc """
  The ERP sidebar — resolved current-org header + switcher + the inherited `module_nav`
  with the ERP group threaded from the mount's `:erp_path` label.

  `erp_path` falls back to `/erp` (the `samen_erp_routes/3` default path): this sidebar
  only renders ON an ERP surface, which only exists when the host mounted that macro, so
  the group is correct here even without the label — while every OTHER framework sidebar
  reads `Mount.label(@mount, :erp_path, nil)` and hides the group unless the host opts in
  (the X1 dead-link guard: a host that never mounts `/erp/*` never links it).
  """
  def erp_sidebar(assigns) do
    ~H"""
    <.sidebar
      title={CurrentOrg.name(@mount, @org_id)}
      subtitle="ERP"
      logo={Mount.label(@mount, :glyph, "S")}
      logo_style={Mount.label(@mount, :erp_logo_style, "background:linear-gradient(150deg,#065F46,#047857)")}
    >
      <:switcher>
        <.switcher mount={@mount} org_id={@org_id} return_to={@return_to} compact />
      </:switcher>
      <:search>
        <.search_box org_id={@org_id} placeholder="Search accounts, invoices, stock…" />
      </:search>

      <.module_nav
        org_id={@org_id}
        active={@active}
        erp_path={Mount.label(@mount, :erp_path, "/erp")}
        banking_path={Mount.label(@mount, :banking_path, nil)}
        work_path={Mount.label(@mount, :work_path, nil)}
      >
        <:extra><.host_nav_extra mount={@mount} org_id={@org_id} /></:extra>
      </.module_nav>

      <:footer>
        <div class="foot">
          <div class="av" style="background:#D1FAE5;color:#065F46">{Mount.label(@mount, :user_initials, "S")}</div>
          <div class="m">
            <b>{Mount.label(@mount, :user_name, "Signed in")}</b><span>{Mount.label(@mount, :user_role, "member")}</span>
          </div>
          <.logout_form />
        </div>
      </:footer>
    </.sidebar>
    """
  end
end
