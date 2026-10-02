defmodule Samenerp.Directory do
  @moduledoc """
  The Samenerp tenant DIRECTORY — the `{org_id, name}` list the framework's
  workspace switcher + name resolution (`Samen.Web.CurrentOrg.list_orgs/1`)
  read off a plain tenant/shared mount (CRM/Billing/Settings/…), which cannot
  see the Identity namespace itself. Wired onto every tenant mount through the
  `org_directory: {Samenerp.Directory, :orgs, []}` label in
  `SamenerpWeb.Router`'s `@current_org_labels`.

  Each row is an `Identity.Org` (the `eoo_org` table) projected to the minimal
  non-PII directory shape the switcher needs: `{org.id, org.name}`. What is
  EXCLUDED, and why:

    * the OPERATOR org (driftwood/pawchart's `id != operator` posture) — the
      SaaS's own bookkeeping seat is not a tenant workspace;
    * the operator-plan DEBRIS older seed runs left on this host — every
      non-tenant row carries `plan: "operator"` (the operator org seeds with
      `plan: "operator"`, slug `"samenerp"`), so a single plan predicate
      excludes the operator seat AND the debris together. Tenant orgs seed
      `plan: "free"` (the blueprint default) or another tenant plan.

  Fail-safe: any error → `[]` — the switcher hides and `name/2` falls back to
  the static `:title` label / "Workspace", never a crash (the driftwood/pawchart
  directory posture).

  Consumed by `Samen.Web.CurrentOrg.list_orgs/1`, which feeds the workspace
  switcher, the first-listable default (dev/dogfood convenience path only — the
  ARMED prod path resolves strictly from the principal's memberships), and the
  resolved display name rendered in every sidebar header and topbar breadcrumb.
  """
  require Ash.Query

  @operator_plan "operator"

  @doc """
  The tenant directory: `[{org_id, name}, …]` over this host's tenant orgs,
  sorted by name — operator seat and operator-plan debris excluded.
  """
  @spec orgs() :: [{String.t(), String.t()}]
  def orgs do
    Samenerp.Operator.Org
    |> Ash.Query.filter(
      (is_nil(plan) or plan != ^@operator_plan) and id != ^Samenerp.Seeds.operator_org_id()
    )
    |> Ash.Query.sort(name: :asc)
    |> Ash.read!(authorize?: false)
    |> Enum.map(fn org -> {org.id, org.name} end)
  rescue
    _ -> []
  end
end
