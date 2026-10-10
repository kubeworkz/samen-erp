defmodule Samen.Web.Banking.Live do
  @moduledoc """
  Shared Banking LiveView helpers: mount assignment + the host-agnostic Banking
  sidebar (workspace branding from `mount.labels`, defaults neutral). Same ADR-009
  pattern as `Samen.Web.CRM.Live` / `Samen.Web.Billing.Live`.
  """
  use Phoenix.Component

  import Samen.UI
  import Samen.Web.CurrentOrg, only: [switcher: 1]

  alias Samen.Web.CurrentOrg
  alias Samen.Web.Mount

  defdelegate assign_mount(socket, session), to: Samen.Web.Live

  @doc """
  Whether write AFFORDANCES (New account/rule, match submit) are OFFERED on this
  mount — tenant plane only (the ADR-011 §6.3 posture, same as
  `Samen.Web.CRM.Live.writable?/1`). UX, not enforcement: the kernel's OrgScope +
  `RoleAtLeast` policies gate every banking write regardless.
  """
  def writable?(%Mount{plane: %{kind: :operator}}), do: false
  def writable?(_), do: true

  attr :mount, Mount, required: true
  attr :org_id, :string, default: nil
  attr :active, :atom, default: nil
  attr :return_to, :string, default: nil

  def banking_sidebar(assigns) do
    ~H"""
    <.sidebar
      title={CurrentOrg.name(@mount, @org_id)}
      subtitle="Banking"
      logo={Mount.label(@mount, :glyph, "S")}
      logo_style={Mount.label(@mount, :banking_logo_style, "background:linear-gradient(150deg,#0E7C5A,#0A5C42)")}
    >
      <:switcher>
        <.switcher mount={@mount} org_id={@org_id} return_to={@return_to} compact />
      </:switcher>
      <:search>
        <.search_box org_id={@org_id} placeholder="Search accounts, statements…" />
      </:search>

      <.module_nav {Samen.UI.nav_paths(@mount)} org_id={@org_id} active={@active}>
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
