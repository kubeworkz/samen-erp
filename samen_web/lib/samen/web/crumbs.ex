defmodule Samen.Web.Crumbs do
  @moduledoc """
  Live breadcrumb trails for the tenant main panel (`Samen.UI.topbar/1`).

  A crumb is one of:

    * a `{label, href}` tuple — the topbar renders it as a LIVE link;
    * a plain string — rendered as inert text. The trail's leaf (the page you
      are already on) is always a string, so the current page never links to
      itself.

  Trails therefore read:

      [Crumbs.org(mount, org_id), Crumbs.section(mount, org_id, :work), leaf]

  `org/2` is the workspace crumb every tenant trail shares: the resolved org
  name (falling back to the mount `:title` label, then "Workspace") linked to
  the tenant's Dashboard — `:crm_path` label + `/dashboard` — so "back to my
  workspace" is ONE click from any page in the main panel.

  `section/4` links a mid-trail section root with the same `?org=` threading
  the sidebar uses (`?org=` is omitted when `org_id` is not resolved — the
  session-pinned org still resolves server-side, same as the wizard's
  `:tenant_landing` CTA).

  Paths read the SAME whitelisted mount labels the rest of the framework uses
  (`:crm_path`, `:support_path`, `:marketing_path`, `:settings_path`,
  `:chat_path` — `Mount.@label_keys`), with the router's `default_path/1`
  literal as the fallback for sections that have no path label of their own.
  Only sections whose root is a DISTINCT route are linked — a section whose
  root would equal the preceding crumb (e.g. CRM, whose landing IS the
  dashboard) stays a plain string at the call site.
  """

  alias Samen.Web.{CurrentOrg, Mount}

  @sections %{
    work: "Work",
    support: "Support",
    billing: "Billing",
    marketing: "Marketing",
    settings: "Settings",
    chat: "Chat",
    inbox: "Inbox",
    files: "Files",
    companies: "Companies",
    contacts: "Contacts"
  }

  @doc """
  The first crumb: `{org name, workspace home}` — the org display name
  linked to the tenant Dashboard (`/crm/dashboard?org=…`, `:crm_path` label).
  """
  @spec org(Mount.t(), String.t() | nil) :: {String.t(), String.t()}
  def org(mount, org_id), do: {CurrentOrg.name(mount, org_id), home(mount, org_id)}

  @doc "The workspace home href — the tenant's Dashboard — for `org_id`."
  @spec home(Mount.t(), String.t() | nil) :: String.t()
  def home(mount, org_id),
    do: threaded("#{Mount.label(mount, :crm_path, "/crm")}/dashboard", org_id)

  @doc """
  A mid-trail section crumb `{label, section root href}` for a known section
  key (`:work`, `:support`, `:billing`, `:marketing`, `:settings`, `:chat`,
  `:inbox`, `:files`, `:companies`, `:contacts`).
  """
  @spec section(Mount.t(), String.t() | nil, atom()) :: {String.t(), String.t()}
  def section(mount, org_id, key) when is_map_key(@sections, key) do
    {Map.fetch!(@sections, key), threaded(section_path(key, mount), org_id)}
  end

  defp section_path(:work, _mount), do: "/work"
  defp section_path(:support, mount), do: Mount.label(mount, :support_path, "/support")
  defp section_path(:billing, _mount), do: "/billing"

  defp section_path(:marketing, mount),
    do: "#{Mount.label(mount, :marketing_path, "/marketing")}/campaigns"

  defp section_path(:settings, mount), do: Mount.label(mount, :settings_path, "/settings")
  defp section_path(:chat, mount), do: Mount.label(mount, :chat_path, "/chat")
  defp section_path(:inbox, _mount), do: "/notifications"
  defp section_path(:files, _mount), do: "/files"
  defp section_path(:companies, mount), do: "#{Mount.label(mount, :crm_path, "/crm")}/companies"
  defp section_path(:contacts, mount), do: "#{Mount.label(mount, :crm_path, "/crm")}/contacts"

  defp threaded(path, org_id) when is_binary(org_id) and org_id != "", do: "#{path}?org=#{org_id}"
  defp threaded(path, _org_id), do: path
end
