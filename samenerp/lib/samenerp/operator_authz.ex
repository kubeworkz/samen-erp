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
  def resolve_role(_otp_app, principal_id) when is_binary(principal_id) do
    case find_membership(principal_id) do
      {:ok, role} -> map_role(role)
      {:error, _} -> nil
    end
  end

  def resolve_role(_otp_app, _principal_id), do: nil

  defp find_membership(principal_id) do
    # The principal_id is the user_id from the session.
    # Check if this user has a membership in the operator org.
    Op.Membership
    |> Ash.Query.filter(org_id == ^@operator_org_id and user_id == ^principal_id)
    |> Ash.Query.limit(1)
    |> Ash.read(authorize?: false)
    |> case do
      {:ok, [%{role: role}]} -> {:ok, role}
      {:ok, []} -> {:error, :no_membership}
    end
  rescue
    _ -> {:error, :query_failed}
  end

  defp map_role(:owner), do: :operator_admin
  defp map_role(:admin), do: :operator_support
  defp map_role(:member), do: :operator_readonly
  defp map_role(_), do: nil
end
