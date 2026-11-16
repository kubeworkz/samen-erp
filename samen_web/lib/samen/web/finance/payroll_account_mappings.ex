defmodule Samen.Web.Finance.PayrollAccountMappings do
  @moduledoc """
  The read seam for the payroll account mapping admin surface.

  Resolves the host's mounted `Finance.PayrollAccountMapping` and
  `Finance.Account` resources from the mount (never from caller input), then
  reads both through the caller's org-pinned scope. The mapping list is a
  bounded `ListLive` page; the account picker is a bounded, code-sorted list.
  This module adds no policy of its own — `OrgScope` owns the org boundary and
  the write policies stay with the resource's own admin-gated actions.
  """

  require Ash.Query

  alias Samen.Web.{Mount, Reads}

  # A chart of accounts is normally a few hundred rows. The picker is bounded
  # anyway so a pathological account table cannot fan out into an unbounded
  # select; the page tells the operator when the cap was reached.
  @account_limit 500

  @type resources :: %{
          mapping_resource: module(),
          account_resource: module(),
          accounts: [struct()],
          accounts_truncated?: boolean(),
          accounts_error?: boolean()
        }

  @doc """
  Resolve the mapping/account resources and read the org's account picker.

  Returns `{:error, :finance_not_mounted}` when the host has not materialized
  the Finance mapping/account resources. An account read failure is kept
  separate: the list can still render and `accounts_error?: true` makes the
  create form's empty picker honest.
  """
  @spec load(Mount.t() | nil, Samen.Scope.t()) :: {:ok, resources()} | {:error, atom()}
  def load(%Mount{} = mount, %Samen.Scope{} = scope) do
    with {:ok, mapping_resource} <- resource(mount, :PayrollAccountMapping),
         {:ok, account_resource} <- resource(mount, :Account) do
      {accounts, accounts_error?} = read_accounts(account_resource, scope)

      {:ok,
       %{
         mapping_resource: mapping_resource,
         account_resource: account_resource,
         accounts: accounts,
         accounts_truncated?: length(accounts) == @account_limit,
         accounts_error?: accounts_error?
       }}
    end
  end

  def load(%Mount{}, _scope), do: {:error, :no_org}
  def load(nil, _scope), do: {:error, :no_mount}

  @doc """
  Read one keyset page of the org's payroll account mappings.

  This is the `ListLive` reads contract (`(mount, scope, %ListState{}) ->
  %Page{}`). The query is org-pinned and bounded by `Samen.Web.Reads.page!/3`;
  the account relationship is loaded so the page can show the host account's
  code and name without a per-row read.
  """
  @spec mappings_page(Mount.t(), Samen.Scope.t(), Samen.Web.ListState.t()) ::
          Samen.Web.Page.t()
  def mappings_page(%Mount{} = mount, %Samen.Scope{} = scope, %Samen.Web.ListState{} = state) do
    org_id = scope.actor.org_id

    Mount.resource(mount, :PayrollAccountMapping)
    |> Ash.Query.filter(org_id == ^org_id)
    # `org_id` is not selected by default; the row editor's Ash update needs the
    # persisted org so SameOrgFk can compare a changed account against it.
    |> Ash.Query.ensure_selected([:org_id, :provider, :external_code, :account_id])
    |> Ash.Query.load(:account)
    |> Reads.page!(
      state,
      scope: scope,
      filter_fields: [:provider, :external_code]
    )
  rescue
    _ ->
      %Samen.Web.Page{
        items: [],
        page_size: Reads.bounded_page_size(state.page_size),
        unread: :read_failed
      }
  end

  defp read_accounts(account_resource, scope) do
    org_id = scope.actor.org_id

    account_resource
    |> Ash.Query.filter(org_id == ^org_id)
    |> Ash.Query.ensure_selected([:id, :code, :name])
    |> Ash.Query.sort(code: :asc)
    |> Ash.Query.limit(@account_limit)
    |> Ash.read(scope: scope)
    |> case do
      {:ok, accounts} -> {accounts, false}
      {:error, _reason} -> {[], true}
    end
  rescue
    _ -> {[], true}
  end

  defp resource(mount, name) do
    module = Mount.resource(mount, name)

    if Code.ensure_loaded?(module) do
      {:ok, module}
    else
      {:error, :finance_not_mounted}
    end
  end
end
