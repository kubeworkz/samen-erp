defmodule Samen.Web.Erp.ApApprovalLive do
  @moduledoc """
  The AP approval-chain settings page (`<erp>/ap-approval`) — the admin
  settings surface over one org's generic `ApprovalPolicy` row for
  `"ap_invoice:approve"`.

  The page edits the three facts the AP Gate reads:

    * `threshold_cents` — the bill total at or above which the policy applies;
    * `auto_approve_below` — when true, a bill STRICTLY below the threshold
      skips the Gate; when false, every bill goes through it;
    * `steps` — the ordered named-user / tenant-role chain. Empty steps preserve
      the historical single-decision Gate. A named-user step is chosen from an
      org-member search (by non-PII `handle`) and stores that member's user id —
      never a hand-typed principal id.
    * `account_ids` / `period_keys` — optional scope for the configured threshold
      and chain. Empty means all accounts/periods. An out-of-scope bill still
      uses the ordinary single-decision Gate.

  A missing row means the old always-gate behavior, so the page offers CREATE
  when the org has no policy and UPDATE when it has one. UPDATE is a two-admin
  control: the save opens an approval, and only a distinct admin's approval
  applies the proposed threshold/scope/chain. The page never deletes.

  ## Authorization (kernel, not posture)

  The read uses `Samen.Web.TenantRole.authenticated_scope/2` (any member may
  see the control; the kernel's `OrgScope` pins the org). Every write is
  submitted with `TenantRole.attributed_admin_scope/2`, so the resource's OWN
  `OrgScope` + `RoleAtLeast :admin` policies decide: a member's save is refused
  even if a crafted event reaches this module. The form is OFFERED only on the
  tenant plane (`Samen.Web.Erp.Live.writable?/1`) and only when that admin scope
  really resolves to `:admin`.

  No PII: a tenant id, a policy kind, an integer, a boolean, and routing
  ids/roles.
  """

  use Samen.Web.Tenant.Live

  require Ash.Query

  import Ash.Expr
  import Samen.UI
  import Samen.Web.Erp.Live, only: [assign_mount: 2, erp_sidebar: 1, writable?: 1]
  import Samen.Web.CurrentOrg, only: [acting_as_banner: 1, no_org_card: 1, return_path: 1]

  alias Samen.Scopes.Finance.ApApproval
  alias Samen.Web.Crumbs
  alias Samen.Web.CurrentOrg
  alias Samen.Web.Erp
  alias Samen.Web.Mount
  alias Samen.Web.TenantRole

  @roles ~w(admin member)
  @approver_types ~w(user role)

  @impl true
  def mount(params, session, socket) do
    socket = assign_mount(socket, session)
    org_id = CurrentOrg.resolve(socket.assigns[:samen_mount], params, session)

    {:ok,
     socket
     |> assign(
       org_id: org_id,
       return_to: nil,
       resource: nil,
       policy: nil,
       threshold_text: "0",
       auto_approve_below: false,
       account_scope_text: "",
       period_scope_text: "",
       policy_steps: [],
       step_values: [],
       user_labels: %{},
       member_queries: %{},
       member_results: %{},
       member_highlights: %{},
       form: nil,
       admin?: false,
       missing: nil,
       save_error: nil,
       approval_pending: false,
       saved: false
     )
     |> load()}
  end

  @impl true
  def handle_params(params, uri, socket) do
    org_id = CurrentOrg.reresolve(socket, params)

    {:noreply,
     socket
     |> assign(org_id: org_id, return_to: return_path(uri), saved: false)
     |> load()}
  end

  @doc false
  def load(socket) do
    socket
    |> assign(:approval_pending, false)
    |> assign_new(:saved, fn -> false end)
    |> assign_new(:save_error, fn -> nil end)
    |> assign_new(:return_to, fn -> nil end)
    |> do_load()
  end

  defp do_load(%{assigns: %{org_id: nil}} = socket) do
    assign(socket,
      org_id: nil,
      missing: :no_org,
      resource: nil,
      policy: nil,
      threshold_text: "0",
      auto_approve_below: false,
      account_scope_text: "",
      period_scope_text: "",
      policy_steps: [],
      step_values: [],
      user_labels: %{},
      member_queries: %{},
      member_results: %{},
      member_highlights: %{},
      form: nil,
      admin?: false
    )
  end

  defp do_load(socket) do
    %{samen_mount: mount, org_id: org_id} = socket.assigns

    case Erp.approval_policy(mount) do
      nil ->
        assign(socket,
          missing: :unmounted,
          resource: nil,
          policy: nil,
          threshold_text: "0",
          auto_approve_below: false,
          account_scope_text: "",
          period_scope_text: "",
          policy_steps: [],
          step_values: [],
          user_labels: %{},
          member_queries: %{},
          member_results: %{},
          member_highlights: %{},
          form: nil,
          admin?: false
        )

      resource ->
        case read_policy(resource, mount, org_id) do
          {:ok, policy} ->
            socket
            |> assign(resource: resource, policy: policy, missing: nil, save_error: nil)
            |> assign_form()

          {:error, _reason} ->
            assign(socket,
              resource: resource,
              policy: nil,
              threshold_text: "0",
              auto_approve_below: false,
              account_scope_text: "",
              period_scope_text: "",
              policy_steps: [],
              step_values: [],
              user_labels: %{},
              member_queries: %{},
              member_results: %{},
              member_highlights: %{},
              form: nil,
              admin?: false,
              missing: :unreadable
            )
        end
    end
  end

  defp read_policy(resource, mount, org_id) do
    scope = TenantRole.authenticated_scope(mount, org_id)

    resource
    |> Ash.Query.filter(org_id == ^org_id and kind == ^ApApproval.policy_kind())
    |> Ash.Query.limit(1)
    |> Ash.read_one(scope: scope)
  end

  defp assign_form(socket) do
    %{samen_mount: mount, org_id: org_id, policy: policy, resource: resource} = socket.assigns

    scope = TenantRole.attributed_admin_scope(mount, org_id)
    admin? = writable?(mount) and Map.get(scope.actor, :role) == :admin
    policy_steps = policy_steps(policy)
    threshold_text = if policy, do: Integer.to_string(policy.threshold_cents), else: "0"
    auto_approve_below = if policy, do: policy.auto_approve_below == true, else: false
    account_scope_text = scope_text(policy && Map.get(policy, :account_ids, []))
    period_scope_text = scope_text(policy && Map.get(policy, :period_keys, []))

    form =
      if admin? do
        case policy do
          nil ->
            resource
            |> AshPhoenix.Form.for_create(:create,
              scope: scope,
              params: %{
                org_id: org_id,
                kind: ApApproval.policy_kind(),
                threshold_cents: 0,
                auto_approve_below: false,
                steps: [],
                account_ids: [],
                period_keys: []
              }
            )
            |> to_form()

          policy ->
            policy
            |> AshPhoenix.Form.for_update(:update, scope: scope)
            |> to_form()
        end
      end

    assign(socket,
      form: form,
      admin?: admin?,
      policy_steps: policy_steps,
      step_values: policy_steps,
      user_labels: user_labels(mount, org_id, policy_steps),
      member_queries: %{},
      member_results: %{},
      member_highlights: %{},
      threshold_text: threshold_text,
      auto_approve_below: auto_approve_below,
      account_scope_text: account_scope_text,
      period_scope_text: period_scope_text
    )
  end

  # -- events -----------------------------------------------------------------

  @impl true
  def handle_event("validate", %{"form" => params}, socket) do
    case socket.assigns.form do
      nil ->
        {:noreply, socket}

      form ->
        params = prepare(params, socket)
        steps = params["steps"]
        role_changed? = role_filters_changed?(steps, socket.assigns.step_values)

        params =
          Map.put(
            params,
            "steps",
            clear_members_on_role_change(steps, socket.assigns.step_values)
          )

        form = AshPhoenix.Form.validate(form, params)
        socket = if role_changed?, do: reset_member_ui(socket), else: socket

        {:noreply,
         assign(socket,
           form: form,
           step_values: params["steps"],
           threshold_text: param_text(params["threshold_cents"], socket.assigns.threshold_text),
           auto_approve_below:
             param_bool(params["auto_approve_below"], socket.assigns.auto_approve_below),
           account_scope_text: scope_text(params["account_ids"]),
           period_scope_text: scope_text(params["period_keys"]),
           save_error: nil,
           saved: false
         )}
    end
  end

  def handle_event("add_step", _params, socket) do
    if editable?(socket) do
      {:noreply,
       socket
       |> reset_member_ui()
       |> assign(step_values: socket.assigns.step_values ++ [default_step()])}
    else
      {:noreply, socket}
    end
  end

  def handle_event("remove_step", %{"index" => index}, socket) do
    if editable?(socket) do
      case step_index(index, socket.assigns.step_values) do
        nil ->
          {:noreply, socket}

        index ->
          {:noreply,
           socket
           |> reset_member_ui()
           |> assign(step_values: List.delete_at(socket.assigns.step_values, index))}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("search_members", %{"index" => index, "query" => query}, socket) do
    with true <- editable?(socket),
         index when is_integer(index) <- step_index(index, socket.assigns.step_values) do
      query = to_string(query)
      results = search_members(socket, index, query)

      {:noreply,
       assign(socket,
         member_queries: Map.put(socket.assigns.member_queries, index, query),
         member_results: Map.put(socket.assigns.member_results, index, results),
         member_highlights: put_member_highlight(socket.assigns.member_highlights, index, results)
       )}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("pick_member", %{"index" => index, "id" => id} = params, socket)
      when is_binary(id) and id != "" do
    with true <- editable?(socket),
         index when is_integer(index) <- step_index(index, socket.assigns.step_values) do
      member = %{id: id, handle: params["handle"] || id, role: params["role"]}

      if member_matches_step_role?(socket.assigns.step_values, index, member) do
        {:noreply, put_member(socket, index, member)}
      else
        {:noreply, socket}
      end
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("pick_member", _params, socket), do: {:noreply, socket}

  def handle_event("clear_member", %{"index" => index}, socket) do
    with true <- editable?(socket),
         index when is_integer(index) <- step_index(index, socket.assigns.step_values) do
      {:noreply,
       assign(socket,
         step_values: put_step_value(socket.assigns.step_values, index, ""),
         member_queries: Map.delete(socket.assigns.member_queries, index),
         member_results: Map.delete(socket.assigns.member_results, index),
         member_highlights: Map.delete(socket.assigns.member_highlights, index)
       )}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("member_keydown", %{"index" => index, "key" => key}, socket) do
    with true <- editable?(socket),
         index when is_integer(index) <- step_index(index, socket.assigns.step_values),
         true <- awaiting_member?(socket.assigns.step_values, index) do
      {:noreply, member_keydown(socket, index, to_string(key))}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("member_keydown", _params, socket), do: {:noreply, socket}

  def handle_event("move_step", %{"index" => index, "direction" => direction}, socket) do
    if editable?(socket) do
      case step_index(index, socket.assigns.step_values) do
        nil ->
          {:noreply, socket}

        index ->
          {:noreply,
           socket
           |> reset_member_ui()
           |> assign(step_values: move_step(socket.assigns.step_values, index, direction))}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("save", params, socket) do
    %{samen_mount: mount, org_id: org_id, form: form} = socket.assigns

    if form != nil and socket.assigns.admin? and writable?(mount) and org_id != nil do
      params =
        params
        |> Map.get("form", socket_form_params(socket))
        |> prepare(socket)

      case AshPhoenix.Form.submit(form, params: params) do
        {:ok, _policy} ->
          {:noreply, socket |> assign(form: nil, policy: nil, saved: true) |> load()}

        {:error, form} ->
          approval_pending? = approval_required?(form)

          {:noreply,
           assign(socket,
             form: form,
             step_values: params["steps"],
             account_scope_text: scope_text(params["account_ids"]),
             period_scope_text: scope_text(params["period_keys"]),
             save_error: if(approval_pending?, do: nil, else: form_error(form)),
             approval_pending: approval_pending?,
             saved: false
           )}
      end
    else
      {:noreply,
       assign(socket,
         save_error: "Only an organization admin can change the AP approval policy.",
         saved: false
       )}
    end
  end

  # -- form plumbing ----------------------------------------------------------

  defp editable?(%{
         assigns: %{
           form: form,
           admin?: true,
           org_id: org_id,
           samen_mount: mount
         }
       })
       when not is_nil(form) and is_binary(org_id) do
    writable?(mount)
  end

  defp editable?(_socket), do: false

  # The Save button is a plain button that reads the form state tracked by
  # `validate`, so pressing Enter in the member search cannot implicitly submit
  # the policy form (and a just-picked member is already in `step_values`).
  defp socket_form_params(socket) do
    %{
      "threshold_cents" => socket.assigns.threshold_text,
      "auto_approve_below" => if(socket.assigns.auto_approve_below, do: "true", else: "false"),
      "steps" => socket.assigns.step_values,
      "account_ids" => socket.assigns.account_scope_text,
      "period_keys" => socket.assigns.period_scope_text
    }
  end

  defp param_text(value, _default) when is_binary(value), do: value
  defp param_text(value, _default) when is_integer(value), do: Integer.to_string(value)
  defp param_text(_value, default), do: default

  defp param_bool(value, _default) when value in [true, "true", "on", "1"], do: true
  defp param_bool(value, _default) when value in [false, "false", "0", nil], do: false

  defp param_bool(values, default) when is_list(values) do
    case List.last(values) do
      nil -> default
      value -> param_bool(value, default)
    end
  end

  defp param_bool(_value, default), do: default

  # `org_id` and `kind` are server-side facts on CREATE, never client input.
  # On UPDATE the action does not accept either field. The browser decodes
  # `steps[0][approver_type]` as a MAP keyed by row index, while a direct
  # caller (the tests) hands us a list; normalize both into the list of row
  # maps the action's `{:array, :map}` attribute expects.
  defp prepare(params, socket) do
    params =
      params
      |> Map.reject(fn {key, _value} -> match?("_unused_" <> _, key) end)
      |> Map.put("steps", normalize_step_rows(Map.get(params, "steps", [])))
      |> Map.put("account_ids", split_scope(Map.get(params, "account_ids", [])))
      |> Map.put("period_keys", split_scope(Map.get(params, "period_keys", [])))

    if socket.assigns.policy == nil do
      params
      |> Map.put("org_id", socket.assigns.org_id)
      |> Map.put("kind", ApApproval.policy_kind())
    else
      params
    end
  end

  defp normalize_step_rows(rows) when is_list(rows) do
    rows
    |> Enum.map(&normalize_step_row/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_step_rows(rows) when is_map(rows) do
    rows
    |> Enum.reject(fn {key, _value} -> match?("_unused_" <> _, key) end)
    |> Enum.sort_by(fn {index, _row} -> step_index_number(index) end)
    |> Enum.map(fn {_index, row} -> normalize_step_row(row) end)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_step_rows(_rows), do: []

  defp normalize_step_row(row) when is_map(row) do
    type = value(row, "approver_type") || "user"
    role = normalize_step_role(type, value(row, "role"))

    %{
      "approver_type" => type,
      "approver" => normalize_approver(type, value(row, "approver"))
    }
    |> maybe_put_step_role(role)
  end

  defp normalize_step_row(_row), do: nil

  # Switching a step from role to user hands us the role name (`admin`) as the
  # approver; it is not a user id, so clear it and let the picker choose.
  defp normalize_approver("user", approver) when approver in @roles, do: ""
  defp normalize_approver("role", ""), do: List.first(@roles)
  defp normalize_approver(_type, approver) when is_binary(approver), do: approver
  defp normalize_approver(_type, _approver), do: ""

  defp normalize_step_role("user", role) when role in @roles, do: role
  defp normalize_step_role(_type, _role), do: nil

  defp maybe_put_step_role(step, role) when is_binary(role), do: Map.put(step, "role", role)
  defp maybe_put_step_role(step, _role), do: step

  defp value(row, key) do
    case Map.fetch(row, key) do
      {:ok, value} -> value
      :error -> Map.get(row, safe_atom(key))
    end
  end

  defp safe_atom(key), do: String.to_existing_atom(key)

  defp step_index_number(index) when is_integer(index), do: index

  defp step_index_number(index) when is_binary(index) do
    case Integer.parse(index) do
      {number, _rest} -> number
      :error -> 0
    end
  end

  defp step_index_number(_index), do: 0

  defp step_index(index, step_values) when is_list(step_values) do
    index = step_index_number(index)

    if index >= 0 and index < length(step_values), do: index
  end

  defp step_index(_index, _step_values), do: nil

  defp move_step(step_values, index, "up") when index > 0 do
    swap_steps(step_values, index, index - 1)
  end

  defp move_step(step_values, index, "down") when index < length(step_values) - 1 do
    swap_steps(step_values, index, index + 1)
  end

  defp move_step(step_values, _index, _direction), do: step_values

  defp swap_steps(step_values, left, right) do
    left_step = Enum.at(step_values, left)
    right_step = Enum.at(step_values, right)

    step_values
    |> List.replace_at(left, right_step)
    |> List.replace_at(right, left_step)
  end

  defp default_step, do: %{"approver_type" => "role", "approver" => "admin"}

  defp put_step_value(step_values, index, value) do
    List.update_at(step_values, index, &Map.put(&1, "approver", value))
  end

  defp step_role(step_values, index) do
    case Enum.at(step_values, index) do
      %{"role" => role} when role in @roles -> role
      _ -> nil
    end
  end

  defp role_filters_changed?(new_steps, old_steps) do
    new_steps
    |> Enum.with_index()
    |> Enum.any?(fn {step, index} ->
      Map.get(step, "role") != Map.get(Enum.at(old_steps, index, %{}), "role")
    end)
  end

  defp clear_members_on_role_change(new_steps, old_steps) do
    new_steps
    |> Enum.with_index()
    |> Enum.map(fn {step, index} ->
      old = Enum.at(old_steps, index, %{})

      if step["approver_type"] == "user" and Map.get(step, "role") != Map.get(old, "role") do
        Map.put(step, "approver", "")
      else
        step
      end
    end)
  end

  defp member_matches_step_role?(step_values, index, member) do
    case step_role(step_values, index) do
      nil -> true
      role -> to_string(member.role) == role
    end
  end

  defp member_search_placeholder(step) do
    case step do
      %{"role" => role} when role in @roles -> "Search #{role} members by handle"
      _ -> "Search organization members by handle"
    end
  end

  defp awaiting_member?(step_values, index) do
    case Enum.at(step_values, index) do
      %{"approver_type" => "user", "approver" => ""} -> true
      _ -> false
    end
  end

  defp member_keydown(socket, index, key) do
    case String.downcase(key) do
      "arrowdown" -> move_member_highlight(socket, index, 1)
      "arrowup" -> move_member_highlight(socket, index, -1)
      "enter" -> pick_highlighted_member(socket, index)
      "escape" -> clear_member_search(socket, index)
      _ -> socket
    end
  end

  defp move_member_highlight(socket, index, delta) do
    results = Map.get(socket.assigns.member_results, index, [])

    case length(results) do
      0 ->
        socket

      count ->
        current = Map.get(socket.assigns.member_highlights, index, 0)
        next = Integer.mod(current + delta, count)

        assign(socket,
          member_highlights: Map.put(socket.assigns.member_highlights, index, next)
        )
    end
  end

  defp pick_highlighted_member(socket, index) do
    results = Map.get(socket.assigns.member_results, index, [])
    highlight = Map.get(socket.assigns.member_highlights, index, 0)

    case Enum.at(results, highlight) do
      nil -> socket
      member -> put_member(socket, index, member)
    end
  end

  defp put_member(socket, index, %{id: id} = member) do
    assign(socket,
      step_values: put_step_value(socket.assigns.step_values, index, id),
      user_labels: Map.put(socket.assigns.user_labels, id, member),
      member_queries: Map.delete(socket.assigns.member_queries, index),
      member_results: Map.delete(socket.assigns.member_results, index),
      member_highlights: Map.delete(socket.assigns.member_highlights, index)
    )
  end

  defp clear_member_search(socket, index) do
    assign(socket,
      member_queries: Map.delete(socket.assigns.member_queries, index),
      member_results: Map.delete(socket.assigns.member_results, index),
      member_highlights: Map.delete(socket.assigns.member_highlights, index)
    )
  end

  defp reset_member_ui(socket) do
    assign(socket, member_queries: %{}, member_results: %{}, member_highlights: %{})
  end

  defp put_member_highlight(highlights, index, []), do: Map.delete(highlights, index)
  defp put_member_highlight(highlights, index, _results), do: Map.put(highlights, index, 0)

  defp member_active_descendant(results, highlights, index) do
    case Map.get(results, index, []) do
      [] -> nil
      _results -> "approval-step-#{index}-option-#{Map.get(highlights, index, 0)}"
    end
  end

  defp member_option_style(true) do
    "display:flex;justify-content:space-between;gap:10px;width:100%;padding:7px 10px;font-size:12px;background:var(--accent-soft, #eef2ff);border:0;cursor:pointer;text-align:left"
  end

  defp member_option_style(false) do
    "display:flex;justify-content:space-between;gap:10px;width:100%;padding:7px 10px;font-size:12px;background:none;border:0;cursor:pointer;text-align:left"
  end

  @member_result_limit 8
  @member_candidate_limit 50

  # Org-scoped active-member search by the non-PII `handle`, optionally
  # restricted to the step's admin/member role filter. Fail-closed: an unwired
  # identity namespace, a missing resource, or a read error yields no results.
  defp search_members(
         %{assigns: %{samen_mount: mount, org_id: org_id, step_values: steps}},
         index,
         query
       ) do
    q = query |> to_string() |> String.trim() |> String.downcase()
    role = step_role(steps, index)

    if q == "" or not is_binary(org_id) do
      []
    else
      identity = CurrentOrg.identity_mount(mount)
      scope = TenantRole.authenticated_scope(identity, org_id)
      user_mod = Mount.resource(identity, User)
      membership_mod = Mount.resource(identity, Membership)

      users =
        user_mod
        |> Ash.Query.ensure_selected([:id, :handle, :status, :org_id])
        |> Ash.Query.filter(
          expr(
            org_id == ^org_id and status == "active" and
              contains(string_downcase(handle), ^q)
          )
        )
        |> Ash.Query.sort(handle: :asc)
        |> Ash.Query.limit(@member_candidate_limit)
        |> Ash.read!(scope: scope)

      roles =
        member_roles(membership_mod, scope, org_id, Enum.map(users, & &1.id), role)

      users
      |> Enum.filter(&Map.has_key?(roles, &1.id))
      |> Enum.take(@member_result_limit)
      |> Enum.map(&%{id: &1.id, handle: &1.handle, role: roles[&1.id]})
    end
  rescue
    _ -> []
  end

  defp member_roles(membership_mod, scope, org_id, user_ids, role \\ nil)
  defp member_roles(_membership_mod, _scope, _org_id, [], _role), do: %{}

  defp member_roles(membership_mod, scope, org_id, user_ids, role) do
    query =
      membership_mod
      |> Ash.Query.ensure_selected([:user_id, :role, :status, :org_id])
      |> Ash.Query.filter(expr(org_id == ^org_id and status == "active" and user_id in ^user_ids))

    query =
      if role in @roles do
        role_atom = String.to_existing_atom(role)
        Ash.Query.filter(query, expr(role == ^role_atom))
      else
        query
      end

    query
    |> Ash.read!(scope: scope)
    |> Map.new(&{&1.user_id, &1.role})
  end

  # Handle + role display for already-selected named users, keyed by user id so
  # it survives step reordering. An unresolvable id renders honestly as unknown.
  defp user_labels(mount, org_id, steps) when is_binary(org_id) do
    user_ids =
      steps
      |> Enum.filter(&(&1["approver_type"] == "user"))
      |> Enum.map(& &1["approver"])
      |> Enum.filter(&(is_binary(&1) and &1 != ""))
      |> Enum.uniq()

    if user_ids == [] do
      %{}
    else
      identity = CurrentOrg.identity_mount(mount)
      scope = TenantRole.authenticated_scope(identity, org_id)
      user_mod = Mount.resource(identity, User)
      membership_mod = Mount.resource(identity, Membership)

      users =
        user_mod
        |> Ash.Query.ensure_selected([:id, :handle])
        |> Ash.Query.filter(expr(id in ^user_ids))
        |> Ash.read!(scope: scope)

      roles = member_roles(membership_mod, scope, org_id, user_ids)

      Map.new(users, &{&1.id, %{handle: &1.handle, role: roles[&1.id]}})
    end
  rescue
    _ -> %{}
  end

  defp user_labels(_mount, _org_id, _steps), do: %{}

  defp approver_types, do: @approver_types
  defp roles, do: @roles

  defp policy_steps(nil), do: []

  defp policy_steps(%{steps: steps}) when is_list(steps), do: normalize_step_rows(steps)

  defp policy_steps(_policy), do: []

  # -- display ----------------------------------------------------------------

  defp split_scope(value) do
    value
    |> List.wrap()
    |> Enum.flat_map(fn item -> String.split(to_string(item), ~r/[\s,]+/, trim: true) end)
  end

  defp scope_text(nil), do: ""
  defp scope_text(value) when is_list(value), do: Enum.join(value, ", ")
  defp scope_text(value), do: scope_text(split_scope(value))

  defp scope_summary(nil, all), do: all
  defp scope_summary([], all), do: all
  defp scope_summary(list, _all) when is_list(list), do: "#{length(list)} scoped"
  defp scope_summary(_, all), do: all

  defp status_text(nil), do: "Not configured"
  defp status_text(%{steps: steps}) when is_list(steps) and steps != [], do: "Chain configured"
  defp status_text(_policy), do: "Single decision"

  defp status_variant(nil), do: "mut"
  defp status_variant(%{steps: steps}) when is_list(steps) and steps != [], do: "ok"
  defp status_variant(_policy), do: "info"

  defp threshold_text(nil), do: "not set — an absent policy preserves the historical Gate"
  defp threshold_text(%{threshold_cents: 0}), do: "0 cents — every bill"
  defp threshold_text(%{threshold_cents: cents}), do: "#{cents} cents (#{dollars(cents)})"
  defp threshold_text(_policy), do: "—"

  defp auto_approve_text(nil), do: "not set"

  defp auto_approve_text(%{auto_approve_below: true}),
    do: "on — bills below the threshold skip approval"

  defp auto_approve_text(_policy), do: "off — every bill goes through the Gate"

  defp dollars(cents) when is_integer(cents) and cents >= 0 do
    "$#{div(cents, 100)}.#{cents |> rem(100) |> Integer.to_string() |> String.pad_leading(2, "0")}"
  end

  defp dollars(_cents), do: "—"

  defp step_text(%{"approver_type" => "role", "approver" => role}, _labels)
       when role in @roles,
       do: "Role · #{role}"

  defp step_text(%{"approver_type" => "user", "approver" => user} = step, labels)
       when is_binary(user),
       do: "User · #{member_label(labels, user)}#{role_filter_text(step)}"

  defp step_text(%{"approver_type" => type, "approver" => approver}, _labels) do
    "#{type || "Unassigned"} · #{approver || "Unassigned"}"
  end

  defp step_text(_step, _labels), do: "Unassigned"

  defp role_filter_text(%{"role" => role}) when role in @roles, do: " · #{role} only"
  defp role_filter_text(_step), do: ""

  defp member_label(labels, user_id) do
    case Map.get(labels, user_id) do
      %{handle: handle, role: role} when is_binary(handle) and not is_nil(role) ->
        "#{handle} (#{role})"

      %{handle: handle} when is_binary(handle) ->
        handle

      _ ->
        "unknown member"
    end
  end

  defp step_value(step_values, index, key) do
    case Enum.at(step_values, index, %{}) do
      row when is_map(row) -> Map.get(row, key, "")
      _row -> ""
    end
  end

  defp field_errors(form, field) do
    case form[field] do
      %{errors: errors} -> errors
      _field -> []
    end
  rescue
    _ -> []
  end

  defp step_errors(form), do: field_errors(form, :steps)

  defp approval_required?(form) do
    form
    |> form_errors()
    |> Enum.any?(&approval_required_error?/1)
  rescue
    _ -> false
  end

  defp approval_required_error?(%Samen.Approvals.ApprovalRequired{}), do: true

  defp approval_required_error?(message) when is_binary(message),
    do: approval_required_text?(message)

  defp approval_required_error?({message, opts}) when is_binary(message) do
    approval_required_text?(message) or approval_required_error?(opts)
  end

  defp approval_required_error?({_key, value}), do: approval_required_error?(value)

  defp approval_required_error?(list) when is_list(list),
    do: Enum.any?(list, &approval_required_error?/1)

  defp approval_required_error?(_error), do: false

  defp approval_required_text?(message), do: String.contains?(message, "approval_required:")

  defp form_errors(form) do
    source_errors =
      case form.source do
        %{errors: errors} when is_list(errors) -> errors
        _ -> []
      end

    Enum.to_list(form.errors) ++ source_errors
  rescue
    _ -> []
  end

  defp form_error(form) do
    case Enum.reject(form.errors, &(&1 in [nil, ""])) do
      [] -> "Could not save the AP approval policy."
      errors -> errors |> Enum.map(&error_text/1) |> Enum.uniq() |> Enum.join(" ")
    end
  rescue
    _ -> "Could not save the AP approval policy."
  end

  defp error_text({msg, opts}) when is_binary(msg) do
    Enum.reduce(opts, msg, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", fn _ -> to_string(value) end)
    end)
  end

  defp error_text(msg) when is_binary(msg), do: msg
  defp error_text(other), do: to_string(other)

  defp crumbs(mount, org_id) do
    [Crumbs.org(mount, org_id), "ERP", Erp.ap_approval_label()]
  end

  @impl Samen.Web.Tenant.Live
  def tenant_sidebar(assigns) do
    ~H"""
    <.erp_sidebar
      mount={@samen_mount}
      org_id={@org_id}
      active={:erp_ap_approval}
      return_to={@return_to}
    />
    """
  end

  @impl Samen.Web.Tenant.Live
  def tenant_page(assigns) do
    ~H"""
    <div id="erp-ap-approval">
      <.topbar title={Erp.ap_approval_label()} crumbs={crumbs(@samen_mount, @org_id)} />

      <.acting_as_banner mount={@samen_mount} org_id={@org_id} acting_as={@samen_acting_as} />

      <div class="wrap">
        <%= if @missing == :no_org do %>
          <.no_org_card mount={@samen_mount} />
        <% else %>
          <%= if @missing in [:unmounted, :unreadable] do %>
            <div class="card" style="padding:16px;color:var(--muted)">
              <%= if @missing == :unreadable do %>
                The AP approval policy could not be read. Try again.
              <% else %>
                The AP approval control is not available on this workspace's mounted modules.
              <% end %>
            </div>
          <% else %>
            <div class="gtitle">
              <h3>{Erp.ap_approval_label()}</h3>
              <span class="lane">· one policy per org · AP bills only · admin-gated writes</span>
            </div>

            <div
              :if={@save_error}
              id="ap-approval-error"
              class="card form-error"
              style="padding:10px 14px;color:var(--bad, #b91c1c);font-size:12px;margin-bottom:10px"
            >
              {@save_error}
            </div>

            <div
              :if={@approval_pending}
              id="ap-approval-pending"
              class="card"
              style="padding:12px 14px;color:var(--warn, #b45309);font-size:12px;margin-bottom:10px;border-left:3px solid var(--warn, #b45309)"
            >
              <b>Pending a distinct admin's approval.</b>
              This change is not live yet. The current policy remains in effect until another
              admin approves the request.
            </div>

            <div
              :if={@saved}
              id="ap-approval-saved"
              class="card"
              style="padding:10px 14px;color:var(--ok, #047857);font-size:12px;margin-bottom:10px"
            >
              Saved. The next AP bill follows this policy immediately.
            </div>

            <div
              id="ap-approval-state"
              class="card"
              style="padding:14px 18px;margin-bottom:10px"
            >
              <div style="display:flex;gap:14px;align-items:center;flex-wrap:wrap;margin-bottom:8px">
                <.pill variant={status_variant(@policy)}>{status_text(@policy)}</.pill>
                <span style="font-size:13px"><b>Threshold:</b> {threshold_text(@policy)}</span>
                <span style="font-size:13px"><b>Auto-approve below:</b> {auto_approve_text(@policy)}</span>
                <span style="font-size:13px">
                  <b>Accounts:</b> {scope_summary(@policy && @policy.account_ids, "All accounts")}
                </span>
                <span style="font-size:13px">
                  <b>Periods:</b> {scope_summary(@policy && @policy.period_keys, "All periods")}
                </span>
              </div>

              <div id="ap-approval-chain" style="font-size:13px">
                <b>Chain:</b>
                <%= if @policy_steps == [] do %>
                  <span style="color:var(--muted)">single decision — no chain steps</span>
                <% else %>
                  <ol style="margin:6px 0 0;padding-left:20px">
                    <li :for={{step, index} <- Enum.with_index(@policy_steps)}>
                      Step {index + 1}: {step_text(step, @user_labels)}
                    </li>
                  </ol>
                <% end %>
              </div>
            </div>

            <div class="card" id="ap-approval-body" style="padding:16px 18px">
              <p style="margin:0 0 14px;font-size:13px;color:var(--muted)">
                When a bill is at or above the threshold, the Gate opens an approval with these
                steps in order. Each step must be approved by its named user or a member of its
                role; only the final approval posts the bill. Leave the chain empty for the
                historical single-decision approval.
              </p>

              <%= cond do %>
                <% @form != nil -> %>
                  <.simple_form
                    :let={f}
                    for={@form}
                    id="ap-approval-form"
                    phx-change="validate"
                    phx-submit="save"
                  >
                    <.form_field
                      field={f[:threshold_cents]}
                      label="Threshold (cents)"
                      type="number"
                      min="0"
                      step="1"
                    />

                    <p style="margin:-6px 0 14px;font-size:12px;color:var(--muted)">
                      Bills whose total is at least this amount use the chain. <b>0</b> means
                      every bill.
                    </p>

                    <div class="field" style="display:flex;flex-direction:column;gap:4px;margin-bottom:14px">
                      <div class="field-label" style="font-size:12px;font-weight:600">
                        Auto-approve below threshold
                      </div>
                      <input type="hidden" name={f[:auto_approve_below].name} value="false" />
                      <label style="display:flex;align-items:center;gap:8px;font-size:13px">
                        <input
                          type="checkbox"
                          id={f[:auto_approve_below].id}
                          name={f[:auto_approve_below].name}
                          value="true"
                          checked={f[:auto_approve_below].value in [true, "true", "on", "1"]}
                        />
                        <span>
                          Bills strictly below the threshold skip approval. Off means every bill
                          goes through the Gate.
                        </span>
                      </label>
                    </div>

                    <div class="field" style="display:flex;flex-direction:column;gap:4px;margin-bottom:10px">
                      <label
                        for={f[:account_ids].id}
                        class="field-label"
                        style="font-size:12px;font-weight:600"
                      >
                        Scoped expense accounts (optional)
                      </label>
                      <input
                        type="text"
                        id={f[:account_ids].id}
                        name={f[:account_ids].name}
                        value={@account_scope_text}
                        placeholder="Empty means all accounts"
                      />
                      <span style="font-size:12px;color:var(--muted)">
                        Comma-separated account UUIDs. The threshold and chain apply when at
                        least one bill line touches one of them; other bills keep the ordinary
                        single-decision Gate.
                      </span>
                      <p
                        :for={msg <- field_errors(@form, :account_ids)}
                        class="field-error"
                        style="margin:0;color:var(--bad, #b91c1c);font-size:12px"
                      >
                        {error_text(msg)}
                      </p>
                    </div>

                    <div class="field" style="display:flex;flex-direction:column;gap:4px;margin-bottom:14px">
                      <label
                        for={f[:period_keys].id}
                        class="field-label"
                        style="font-size:12px;font-weight:600"
                      >
                        Scoped bill periods (optional)
                      </label>
                      <input
                        type="text"
                        id={f[:period_keys].id}
                        name={f[:period_keys].name}
                        value={@period_scope_text}
                        placeholder="Empty means all periods"
                      />
                      <span style="font-size:12px;color:var(--muted)">
                        Comma-separated months in <code>YYYY-MM</code> form, for example
                        <code>2026-11, 2026-12</code>.
                      </span>
                      <p
                        :for={msg <- field_errors(@form, :period_keys)}
                        class="field-error"
                        style="margin:0;color:var(--bad, #b91c1c);font-size:12px"
                      >
                        {error_text(msg)}
                      </p>
                    </div>

                    <div id="ap-approval-steps" style="margin-bottom:12px">
                      <div class="field-label" style="font-size:12px;font-weight:600;margin-bottom:6px">
                        Ordered approval steps
                      </div>

                      <div
                        :if={@step_values == []}
                        id="ap-approval-no-steps"
                        style="font-size:12px;color:var(--muted);margin-bottom:8px"
                      >
                        No chain steps. The bill uses one distinct-approver decision.
                      </div>

                      <div
                        :for={{step, index} <- Enum.with_index(@step_values)}
                        id={"approval-step-#{index}"}
                        style="display:flex;gap:6px;align-items:center;flex-wrap:wrap;padding:8px 0;border-bottom:1px solid var(--border, #f3f4f6)"
                      >
                        <span style="font-size:12px;font-weight:600;min-width:54px">
                          Step {index + 1}
                        </span>

                        <select
                          name={"#{f.name}[steps][#{index}][approver_type]"}
                          aria-label={"Approver type for step #{index + 1}"}
                          style="font-size:12px;padding:6px 8px;min-width:100px"
                        >
                          <option
                            :for={type <- approver_types()}
                            value={type}
                            selected={step["approver_type"] == type}
                          >
                            {type}
                          </option>
                        </select>

                        <%= if step["approver_type"] == "user" do %>
                          <select
                            name={"#{f.name}[steps][#{index}][role]"}
                            aria-label={"Role filter for step #{index + 1}"}
                            style="font-size:12px;padding:6px 8px;min-width:110px"
                          >
                            <option value="" selected={step["role"] in [nil, ""]}>
                              Any role
                            </option>
                            <option
                              :for={role <- roles()}
                              value={role}
                              selected={step["role"] == role}
                            >
                              {role} only
                            </option>
                          </select>
                        <% end %>

                        <%= if step["approver_type"] == "role" do %>
                          <select
                            name={"#{f.name}[steps][#{index}][approver]"}
                            aria-label={"Role for step #{index + 1}"}
                            style="font-size:12px;padding:6px 8px;min-width:130px"
                          >
                            <option
                              :for={role <- roles()}
                              value={role}
                              selected={step["approver"] == role}
                            >
                              {role}
                            </option>
                          </select>
                        <% else %>
                          <input
                            type="hidden"
                            name={"#{f.name}[steps][#{index}][approver]"}
                            value={step_value(@step_values, index, "approver")}
                          />

                          <%= if step_value(@step_values, index, "approver") != "" do %>
                            <span
                              class="pill"
                              id={"approval-step-#{index}-member"}
                              style="font-size:12px"
                            >
                              {member_label(
                                @user_labels,
                                step_value(@step_values, index, "approver")
                              )}
                            </span>
                            <button
                              type="button"
                              class="btn"
                              phx-click="clear_member"
                              phx-value-index={index}
                              aria-label={"Change member for step #{index + 1}"}
                              style="font-size:12px;padding:5px 8px"
                            >
                              Change
                            </button>
                          <% else %>
                            <div style="position:relative;flex:1;min-width:220px">
                              <input
                                type="text"
                                value={Map.get(@member_queries, index, "")}
                                phx-change="search_members"
                                phx-keydown="member_keydown"
                                phx-value-index={index}
                                role="combobox"
                                aria-autocomplete="list"
                                aria-expanded={
                                  if Map.get(@member_results, index, []) != [],
                                    do: "true",
                                    else: "false"
                                }
                                aria-controls={"approval-step-#{index}-results"}
                                aria-activedescendant={
                                  member_active_descendant(
                                    @member_results,
                                    @member_highlights,
                                    index
                                  )
                                }
                                placeholder={member_search_placeholder(step)}
                                aria-label={"Search organization member for step #{index + 1}"}
                                autocomplete="off"
                                style="font-size:12px;padding:6px 8px;width:100%"
                              />

                              <div
                                :if={Map.get(@member_results, index, []) != []}
                                id={"approval-step-#{index}-results"}
                                role="listbox"
                                aria-label={"Organization members matching step #{index + 1}"}
                                style="position:absolute;z-index:10;left:0;right:0;top:100%;background:var(--surface, #fff);border:1px solid var(--border, #e5e7eb);border-radius:6px;box-shadow:0 6px 18px rgba(0,0,0,.08);overflow:hidden"
                              >
                                <button
                                  :for={
                                    {member, result_index} <-
                                      Enum.with_index(Map.get(@member_results, index, []))
                                  }
                                  type="button"
                                  id={"approval-step-#{index}-option-#{result_index}"}
                                  role="option"
                                  tabindex="-1"
                                  aria-selected={
                                    if result_index == Map.get(@member_highlights, index, 0),
                                      do: "true",
                                      else: "false"
                                  }
                                  phx-click="pick_member"
                                  phx-value-index={index}
                                  phx-value-id={member.id}
                                  phx-value-handle={member.handle}
                                  phx-value-role={member.role}
                                  style={
                                    member_option_style(
                                      result_index == Map.get(@member_highlights, index, 0)
                                    )
                                  }
                                >
                                  <span>{member.handle}</span>
                                  <span style="color:var(--muted)">{member.role}</span>
                                </button>
                              </div>

                              <p
                                :if={Map.get(@member_results, index, []) != []}
                                style="margin:4px 0 0;font-size:11px;color:var(--muted)"
                              >
                                ↑/↓ to navigate · Enter to select · Esc to clear
                              </p>

                              <p
                                :if={
                                  Map.get(@member_queries, index, "") != "" and
                                    Map.get(@member_results, index, []) == []
                                }
                                style="margin:4px 0 0;font-size:11px;color:var(--muted)"
                              >
                                No active member matches.
                              </p>
                            </div>
                          <% end %>
                        <% end %>

                        <button
                          type="button"
                          class="btn"
                          phx-click="move_step"
                          phx-value-index={index}
                          phx-value-direction="up"
                          disabled={index == 0}
                          aria-label={"Move step #{index + 1} up"}
                          style="font-size:12px;padding:5px 8px"
                        >
                          ↑
                        </button>
                        <button
                          type="button"
                          class="btn"
                          phx-click="move_step"
                          phx-value-index={index}
                          phx-value-direction="down"
                          disabled={index == length(@step_values) - 1}
                          aria-label={"Move step #{index + 1} down"}
                          style="font-size:12px;padding:5px 8px"
                        >
                          ↓
                        </button>
                        <button
                          type="button"
                          class="btn"
                          phx-click="remove_step"
                          phx-value-index={index}
                          aria-label={"Remove step #{index + 1}"}
                          style="font-size:12px;padding:5px 8px"
                        >
                          Remove
                        </button>
                      </div>

                      <div
                        :if={step_errors(@form) != []}
                        id="ap-approval-step-errors"
                        class="field-errors"
                        style="margin-top:8px"
                      >
                        <p
                          :for={msg <- step_errors(@form)}
                          class="field-error"
                          style="margin:0;color:var(--bad, #b91c1c);font-size:12px"
                        >
                          {error_text(msg)}
                        </p>
                      </div>

                      <.button
                        type="button"
                        phx-click="add_step"
                        id="add-approval-step"
                        style="margin-top:10px"
                      >
                        Add step
                      </.button>
                    </div>

                    <:actions>
                      <.button variant="primary" type="button" phx-click="save" id="save-ap-approval">
                        Save policy
                      </.button>
                    </:actions>
                  </.simple_form>
                <% not writable?(@samen_mount) -> %>
                  <p id="ap-approval-read-only" style="margin:0;font-size:13px;color:var(--muted)">
                    Read-only on this plane.
                  </p>
                <% true -> %>
                  <p id="ap-approval-admin-only" style="margin:0;font-size:13px;color:var(--muted)">
                    Only an organization admin can change this policy.
                  </p>
              <% end %>
            </div>
          <% end %>
        <% end %>
      </div>
    </div>
    """
  end
end
