defmodule Samen.Web.Settings.Live do
  @moduledoc """
  Shared chrome for the framework SETTINGS LiveViews (WS-E E5; ADR-029) — the sidebar
  nav across the settings sub-surfaces (Profile · API keys · HuggingFace · Security ·
  Invitations · Reveal approvals) and the small plane helpers each surface reads.
  Mirrors `Samen.Web.Files.Live`.
  """
  use Phoenix.Component

  import Samen.UI, only: [sidebar: 1, logout_form: 1]

  alias Samen.Web.CurrentOrg
  alias Samen.Web.Mount

  @doc "Is this mount rendering on the operator (impersonation) plane?"
  def operator_plane?(%Mount{plane: %{kind: :operator}}), do: true
  def operator_plane?(_), do: false

  attr :mount, Mount, default: nil
  attr :org_id, :string, default: nil
  attr :active, :atom, default: :profile
  attr :user_id, :string, default: nil

  @doc "The settings sidebar with the settings sub-surface nav links."
  def settings_sidebar(assigns) do
    ~H"""
    <.sidebar
      title={CurrentOrg.name(@mount, @org_id)}
      subtitle="Settings"
      logo={Mount.label(@mount, :glyph, "S")}
    >
      <div class="grp">Settings</div>
      <nav class="nav settings-nav" aria-label="Settings">
        <a href={href("/settings", @org_id, @user_id)} class={nav_class(@active, :profile)} id="settings-nav-profile">
          Profile
        </a>
        <a href={href("/settings/api-keys", @org_id, @user_id)} class={nav_class(@active, :api_keys)} id="settings-nav-api-keys">
          API keys
        </a>
        <a href={href("/settings/huggingface", @org_id, @user_id)} class={nav_class(@active, :huggingface)} id="settings-nav-huggingface">
          HuggingFace
        </a>
        <a href={href("/settings/security", @org_id, @user_id)} class={nav_class(@active, :security)} id="settings-nav-security">
          Security
        </a>
        <a
          href={href("/settings/invitations", @org_id, @user_id)}
          class={nav_class(@active, :invitations)}
          id="settings-nav-invitations"
        >
          Invitations
        </a>
        <a
          href={href("/settings/reveal-approvals", @org_id, @user_id)}
          class={nav_class(@active, :reveal_approvals)}
          id="settings-nav-reveal-approvals"
        >
          Reveal approvals
        </a>
      </nav>

      <:footer>
        <div class="foot">
          <div class="av" style="background:#DDE2F5;color:#3B4CCA">{Mount.label(@mount, :user_initials, "S")}</div>
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

  # The stylesheet's sidebar-link vocabulary is `.nav a` / `.nav a.on` (`samen_ui.css`,
  # the same pair `Samen.UI.Nav.nav_group/1` emits), plus the `.settings-nav` hook the
  # product tour highlights. `module-nav` / `module-nav-item` are defined NOWHERE in the
  # sheet, so the links rendered as unstyled anchors and the active item never lit up.
  defp nav_class(active, active), do: "on"
  defp nav_class(_active, _item), do: nil

  defp href(path, org_id, user_id) do
    query =
      [org: org_id, user: user_id]
      |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)
      |> URI.encode_query()

    if query == "", do: path, else: "#{path}?#{query}"
  end
end
