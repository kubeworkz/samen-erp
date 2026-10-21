defmodule Samen.Web.OrgProvisioning do
  @moduledoc """
  The ORG-PROVISIONING seam (WS-Notes Phase 6, unit 1c) — a host's per-org setup runs at the
  moment a tenant org is CREATED, not the first time someone notices the surface is empty.

  ## Why this seam exists

  Some framework state is per-ORG REGISTRY state, not tenant content: the Pages search index
  (`Doc.title` + `DocBlock.text` in the host's `SearchIndex`) is the one this seam was built
  for. `Samen.Web.Notes.Search` is FAIL-CLOSED — with no registry row for an org it answers the
  honest empty result set — so an org that never got registered has a `/pages?q=` that cannot
  be told apart from "nothing matches": wired, but silently dumb.

  A host seed can only repair the orgs the seeder knows about. Any tenant org created later
  got nothing, and `?q=` answered empty forever. That is a provisioning gap, not a search bug,
  so the fix lives here: org CREATION is the one moment every creation path shares.

  ## The contract (the house `{mod, fun, args}` seam)

      # config/config.exs of the host
      config :my_app, :org_provisioning, [{MyApp.Provisioning, :provision_org!, []}]

  Each hook is called as `apply(mod, fun, args ++ [org_id])` — the `org_id` LAST, the same
  shape `Samen.Web.Onboarding`'s `:plan_labels` seam and `Samen.Web.CurrentOrg`'s
  `:org_directory` use. A hook must be IDEMPOTENT (it may run again after a failure, and a
  host seed can replay it on every boot) and must return `:ok` or `{:ok, _}` on success.

  ## Fail-honest, and deliberately NON-FATAL

  The org row is already committed when a hook runs, so a failing hook must never unwind it — a
  search-registry write that failed is not a reason to tell a brand-new tenant their account
  does not exist. It must also never vanish. `run/2` therefore:

    * returns `:ok` when no hook is configured, or every hook succeeded;
    * returns `{:error, [{mod, fun, reason}]}` and emits a `Logger.error` naming the hook, the
      org and the reason for EVERY failure — including a raise (rescued here, never propagated
      into a response) and an unexpected return (a hook that returns neither `:ok` nor
      `{:ok, _}` has not reported success, so this seam does not read it as success).

  A malformed config entry is reported the same way rather than silently dropped: a hook that
  never ran is not a hook that passed.
  """

  require Logger

  alias Samen.Web.Mount

  @config_key :org_provisioning

  @type hook :: {module(), atom(), list()}
  @type failure :: {module(), atom(), term()}

  @doc """
  The VALID `{mod, fun, args}` hooks configured for `otp_app` (`[]` when unwired). Malformed
  entries are excluded here and reported by `run/2`, which is where they can be logged once.
  """
  @spec hooks(atom() | nil) :: [hook()]
  def hooks(otp_app) when is_atom(otp_app) and not is_nil(otp_app) do
    otp_app
    |> raw_hooks()
    |> Enum.filter(&hook?/1)
  end

  def hooks(_), do: []

  @doc "TRUE when `otp_app` names at least one provisioning hook."
  @spec configured?(atom() | nil) :: boolean()
  def configured?(otp_app), do: hooks(otp_app) != []

  @doc """
  Provision `org_id` through every hook `mount`'s host configures, returning `:ok` when there
  were none or all succeeded and `{:error, [{mod, fun, reason}]}` otherwise. A `nil`/non-binary
  org id (no org to provision) or a mount with no resolvable `otp_app` is a no-op.

  Never raises: a hook's raise, `{:error, reason}`, or unexpected return is collected, logged at
  `:error`, and returned. The caller decides nothing else — the org row already exists.
  """
  @spec run(Mount.t(), String.t() | nil) :: :ok | {:error, [failure()]}
  def run(%Mount{} = mount, org_id) when is_binary(org_id) do
    case Mount.otp_app(mount) do
      nil ->
        :ok

      otp_app ->
        {hooks, invalid} = otp_app |> raw_hooks() |> Enum.split_with(&hook?/1)
        report_invalid(otp_app, invalid)
        run_hooks(hooks, org_id)
    end
  end

  def run(_mount, _org_id), do: :ok

  defp run_hooks([], _org_id), do: :ok

  defp run_hooks(hooks, org_id) do
    failures =
      Enum.flat_map(hooks, fn {mod, fun, _args} = hook ->
        case invoke(hook, org_id) do
          :ok ->
            []

          {:error, reason} ->
            Logger.error(
              "[org_provisioning] #{format_hook(hook)} failed for org #{org_id}: #{inspect(reason)}"
            )

            [{mod, fun, reason}]
        end
      end)

    case failures do
      [] -> :ok
      failures -> {:error, failures}
    end
  end

  defp invoke({mod, fun, args}, org_id) do
    case apply(mod, fun, args ++ [org_id]) do
      :ok -> :ok
      {:ok, _} -> :ok
      other -> {:error, {:unexpected_return, other}}
    end
  rescue
    error -> {:error, error}
  end

  # A malformed entry never becomes a silent no-op: it is named, with the host it was wired in.
  defp report_invalid(_otp_app, []), do: :ok

  defp report_invalid(otp_app, invalid) do
    Logger.error(
      "[org_provisioning] #{inspect(otp_app)} has malformed hooks (expected {mod, fun, args}): " <>
        "#{inspect(invalid)}"
    )
  end

  defp raw_hooks(otp_app) when is_atom(otp_app) and not is_nil(otp_app),
    do: otp_app |> Application.get_env(@config_key, []) |> List.wrap()

  defp raw_hooks(_), do: []

  defp hook?({mod, fun, args}) when is_atom(mod) and is_atom(fun) and is_list(args), do: true
  defp hook?(_), do: false

  # `mod.fun/arity` as the hook would be CALLED (the appended org id is an argument).
  defp format_hook({mod, fun, args}),
    do: "#{inspect(mod)}.#{fun}/#{length(args) + 1}"
end
