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
  `:chat_path`, `:ai_path` — `Mount.@label_keys`), with the router's
  `default_path/1` literal as the fallback for sections that have no path label
  of their own.
  Only sections whose root is a DISTINCT route are linked — a section whose
  root would equal the preceding crumb (e.g. CRM, whose landing IS the
  dashboard) stays a plain string at the call site.

  ## The operator plane (ADR-010) rides the SAME topbar

  `operator/0` and `operator_section/1` are the operator workspace's crumb seam. The operator
  plane declares NO index route at its prefix: `samen_operator_routes/2` mounts
  `\#{path}/accounts`, `…/billing`, `…/desk`, … but never `\#{path}` itself. So a crumb labelled
  "Operator plane" had nowhere real to point, every operator page passed it as a PLAIN STRING,
  and the plane's trails had no live crumb in them at all — an operator three screens deep had
  no breadcrumb path back (the reported "breadcrumbs don't work"). `operator/0` links that
  crumb at the plane's ENTRY, `/operator/accounts` — the first item of `operator_sidebar/1` and
  the only top-level index the plane has.
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
    pages: "Pages",
    ai: "AI",
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
  `:inbox`, `:files`, `:ai`, `:companies`, `:contacts`).

  `:ai` resolves the mount's own AI prefix (`:ai_path`, the label
  `samen_ai_routes/3` sets), so the crumb follows a host that mounts the AI kit
  somewhere other than `/ai` rather than hardcoding the framework default.
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
  # WS-Notes Phase 3 — the `:pages_path` label `samen_notes_routes/3` sets itself (so a host that
  # mounts the surface at `/docs/pages` gets a crumb that follows it, not a dead `/pages`).
  defp section_path(:pages, mount), do: Mount.label(mount, :pages_path, "/pages")
  defp section_path(:ai, mount), do: Mount.label(mount, :ai_path, "/ai")
  defp section_path(:companies, mount), do: "#{Mount.label(mount, :crm_path, "/crm")}/companies"
  defp section_path(:contacts, mount), do: "#{Mount.label(mount, :crm_path, "/crm")}/contacts"

  defp threaded(path, org_id) when is_binary(org_id) and org_id != "", do: "#{path}?org=#{org_id}"
  defp threaded(path, _org_id), do: path

  # ===========================================================================
  # The OPERATOR plane (ADR-010)
  # ===========================================================================

  # The plane's ENTRY. Not `"/operator"` — the macro declares no route there (see the moduledoc),
  # so linking the prefix would trade an inert crumb for a dead one. Accounts is where the
  # operator workspace actually starts: the sidebar's first item, the only top-level index.
  @operator_home "/operator/accounts"

  @doc """
  The operator plane's entry crumb — `{"Operator plane", "/operator/accounts"}`.

  The first crumb of EVERY operator trail, and the plane's one way "back to the top": the
  destination is the same href `operator_sidebar/1`'s Accounts item carries, so the crumb and
  the nav item can never disagree about where the plane begins (and `samen.verify.nav_links`
  already dead-link-checks that href against the host router).
  """
  @spec operator() :: {String.t(), String.t()}
  def operator, do: {"Operator plane", @operator_home}

  @doc """
  A mid-trail operator SECTION crumb `{label, section index href}` for a top-level operator
  index an operator can stand BETWEEN (`:desk`, `:fleet`) — the drill-in/detail pages have a
  real index above them, so the step is a live link, not inert text.

  Only sections whose index is a DISTINCT route from the plane entry are here, the same rule
  the tenant `section/3` follows: `:accounts` is deliberately absent because it IS
  `operator/0`'s destination — the trail already links there, twice would be noise.
  """
  @spec operator_section(:desk | :fleet) :: {String.t(), String.t()}
  def operator_section(key), do: {operator_section_label(key), operator_section_path(key)}

  defp operator_section_label(:desk), do: "Desk"
  defp operator_section_label(:fleet), do: "Fleet"

  defp operator_section_path(:desk), do: "/operator/desk"
  defp operator_section_path(:fleet), do: "/operator/fleet"
end
