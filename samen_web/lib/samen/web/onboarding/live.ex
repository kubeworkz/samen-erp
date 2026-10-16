defmodule Samen.Web.Onboarding.Live do
  @moduledoc """
  Shared chrome for the framework ONBOARDING surfaces (ADR-035 §5 A8) — the sidebar the
  first-run wizard renders inside the shared app shell. Mirrors `Samen.Web.Settings.Live`
  (and `Samen.Web.Files.Live`): the vertical's chrome lives in one module, every surface of
  the flow composes it.

  ## The wizard's sidebar is its OWN steps — never the workspace `module_nav/1`

  `Samen.UI.Nav.module_nav/1`'s inherited groups (CRM · Billing · Support · Marketing · the
  Workspace group) fall back to the framework's DEFAULT paths (`/crm`, `/billing`, `/support`,
  `/settings`, …) and render them whenever `surfaces` allows the group. A first-run host may
  mount NONE of those: the generated app (`samen_core/priv/templates/router_ex.eex`) mounts
  billing + notifications + the auth spine + this wizard only, and its own landing page passes
  `surfaces={…}` to `module_nav/1` precisely so it never emits a link to a route it did not
  mount (X1 / ADR-045 §4.1 — a dead link raises `Phoenix.Router.NoRouteError` on the first
  click). The wizard has no such list to consult: `samen_onboarding_routes/2` builds a
  `:settings`-kind mount whose labels carry no surface inventory, so rendering `module_nav/1`
  here would put a NoRouteError one click away on every host that mounts onboarding and not
  the workspace modules.

  Every link this sidebar renders therefore points at THIS LiveView's own route (`?step=`),
  which exists wherever the wizard exists — and while the wizard is running, its three steps
  ARE the page's navigation. No link, no dead link. A host that wants its own vertical nav in
  here can still add it: the wizard is ordinary framework code, not a fork.
  """
  use Phoenix.Component

  import Samen.UI, only: [logout_form: 1, nav_group: 1, nav_item: 1, sidebar: 1]

  alias Samen.Web.CurrentOrg
  alias Samen.Web.Mount

  @doc "The wizard's three steps, in order: `{step, label}`."
  def steps,
    do: [org: "Name your workspace", plan: "Choose a plan", invite: "Invite your team"]

  attr :mount, Mount, default: nil
  attr :org_id, :string, default: nil
  attr :user_id, :string, default: nil
  attr :path, :string, default: "/onboarding"
  attr :step, :atom, default: :org
  attr :complete?, :boolean, default: false

  @doc """
  The onboarding sidebar: the workspace header, the wizard's own steps as the nav, and the
  user footer every tenant sidebar carries. The step nav is hidden once setup is complete —
  there is nothing left to navigate, and the completed card's button leads on.
  """
  def onboarding_sidebar(assigns) do
    ~H"""
    <.sidebar
      title={CurrentOrg.name(@mount, @org_id)}
      subtitle="Setup"
      logo={Mount.label(@mount, :glyph, "S")}
    >
      <.nav_group :if={@complete? == false} label="Get started">
        <.nav_item
          :for={{step, label} <- steps()}
          label={label}
          href={step_href(@path, @org_id, @user_id, step)}
          active={@step == step}
        />
      </.nav_group>

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

  @doc """
  The wizard's `?step=` link — the URL its own `handle_params/3` reads to advance
  (`WizardLive.step_link/4`'s sidebar twin; nil/empty parts are dropped, so a no-JS GET works).
  """
  def step_href(path, org_id, user_id, step) do
    query =
      [org: org_id, user: user_id, step: Atom.to_string(step)]
      |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)
      |> URI.encode_query()

    if query == "", do: path, else: "#{path}?#{query}"
  end
end
