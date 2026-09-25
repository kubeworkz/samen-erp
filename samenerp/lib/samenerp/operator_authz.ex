defmodule Samenerp.OperatorAuthz do
  @moduledoc """
  The PRODUCTION operator-authority resolver for Samen ERP.

  Replaces `Samen.Web.Operator.Authz.dev_operator_role/2` in prod.
  Checks whether the authenticated principal holds an operator membership
  (owner/admin role in the operator org) and returns the corresponding
  operator role.

  ## Wiring

  In `config/prod.exs` or `config/runtime.exs`:

      config :samenerp, :operator_authority,
        {Samenerp.OperatorAuthz, :resolve_role, [:samenerp]}

  ## Role mapping

  | Tenant membership role | Operator role        |
  |------------------------|----------------------|
  | `:owner`               | `:operator_admin`    |
  | `:admin`               | `:operator_support`  |
  | `:member`              | `:operator_readonly` |
  | other / no membership  | `nil` (denied)       |
  """

  require Ash.Query

  alias Samenerp.Operator, as: Op

  @operator_org_id "0f000000-0000-4000-8000-0000000000aa"

  @doc """
  Resolve the operator role for a principal.

  Called by `Samen.Web.Operator.Authz.resolve_role/2` via the MFA seam.
  Returns an operator role atom or `nil` (deny).
  """
  @spec resolve_role(atom(), String.t() | nil) :: atom() | nil
  def resolve_role(otp_app, principal_id) when is_atom(otp_app) and is_binary(principal_id) do
    case find_membership(principal_id) do
      {:ok, role} -> map_role(role)
      {:error, _} ->
        # Dev/test convenience: when disarmed, the seeded operator still reaches
        # the console without special-casing every caller. Armed prod fails closed.
        if Samen.Web.TenantGate.armed?(otp_app), do: nil, else: :operator_admin
    end
  end

  def resolve_role(otp_app, nil) when is_atom(otp_app) do
    if Samen.Web.TenantGate.armed?(otp_app), do: nil, else: :operator_admin
  end

  def resolve_role(_otp_app, _principal_id), do: nil

  # ADR-035 §5 A4 — the spine is CREDENTIAL-scoped (`Session.credential_id`),
  # while `Membership.user_id` is a per-org User. `Samen.Web.Operator.Authz`
  # now passes the spine `credential_id` as the principal; resolve it to the
  # operator-org User(s) first, then the membership. Direct user_id still works
  # (legacy `samen_current_user` / SessionController bridge). Either path
  # admits an operator; only a real operator-org membership produces a role.
  defp find_membership(principal_id) do
    # 1. Direct User → Membership (BYO-auth / bridged spine login).
    case membership_for_user(principal_id) do
      {:ok, role} -> {:ok, role}
      {:error, _} ->
        # 2. Credential → User(s) → Membership (pure spine session, no bridge).
        principal_id
        |> users_for_credential()
        |> Enum.find_value({:error, :no_membership}, fn user_id ->
          case membership_for_user(user_id) do
            {:ok, role} -> {:ok, role}
            _ -> nil
          end
        end)
    end
  rescue
    _ -> {:error, :query_failed}
  end

  defp membership_for_user(user_id) do
    Op.Membership
    |> Ash.Query.filter(org_id == ^@operator_org_id and user_id == ^user_id)
    |> Ash.Query.limit(1)
    |> Ash.read(authorize?: false)
    |> case do
      {:ok, [%{role: role}]} -> {:ok, role}
      {:ok, []} -> {:error, :no_membership}
    end
  end

  defp users_for_credential(credential_id) do
    Op.User
    |> Ash.Query.filter(credential_id == ^credential_id)
    |> Ash.Query.select([:id])
    |> Ash.read!(authorize?: false)
    |> Enum.map(& &1.id)
  rescue
    _ -> []
  end

  defp map_role(:owner), do: :operator_admin
  defp map_role(:admin), do: :operator_support
  defp map_role(:member), do: :operator_readonly
  defp map_role(_), do: nil
end
