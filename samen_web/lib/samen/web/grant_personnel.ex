defmodule Samen.Web.GrantPersonnel do
  @moduledoc """
  The grant personnel report (WS-ACCT Phase 11; ADR-054 D8/§4).

  Finance stores one opaque HR `employee_id` per effort row and never
  re-declares the person. This module is the ONE report projection: it reads
  the grant org-scoped, resolves the name through `Samen.Api.PiiResolution`
  on the acting plane, and hands the SAME rows to all three egress paths:

    * `Samen.Web.GrantPersonnel.Live` — the HTML table;
    * `Samen.Web.GrantPersonnel.CsvController` — the RFC-4180 download;
    * `Samen.Web.GrantPersonnel.ApiController` — the JSON payload.

  On the tenant plane the name is clear; on the operator/impersonation plane
  it is `%Samen.Masked{}` and stringifies to `••••`. The projection never
  carries a vault token. A mount that has not named an HR namespace (the
  Phase-16 wiring) reports only the bounded employment facts — the employee
  id, effort percentage, and effective date — which is the design's explicit
  "no third path" fallback, never a guessed name.
  """

  require Ash.Query

  alias Samen.Masked
  alias Samen.Scopes.Finance.GrantCompliance
  alias Samen.Web.Csv
  alias Samen.Web.Mount

  @columns [:employee_id, :name, :effort_pct, :effective_on]

  @doc "The report's bounded column allowlist."
  def columns, do: @columns

  @doc """
  Load one grant's personnel report for `mount` + `org_id`.

  Returns `{:ok, %{grant: grant, rows: rows, personnel_wired?: boolean}}` or
  `{:error, reason}` where reason is `:no_mount`, `:no_org`, `:grant_not_mounted`,
  `:not_found`, or a read error.
  """
  def load(%Mount{} = mount, org_id, grant_id) when is_binary(org_id) do
    with {:ok, grant} <- fetch_grant(mount, org_id, grant_id) do
      case personnel_config(mount) do
        nil ->
          bounded_report(mount, grant)

        config ->
          resolved_report(mount, org_id, grant, config)
      end
    end
  end

  def load(%Mount{}, nil, _grant_id), do: {:error, :no_org}
  def load(%Mount{}, _org_id, _grant_id), do: {:error, :no_org}
  def load(nil, _org_id, _grant_id), do: {:error, :no_mount}

  @doc """
  The report's CSV binary. Cells are produced by the shared projection and
  serialized through `Samen.Web.Csv` (formula-neutralized, RFC 4180).
  """
  def csv(%{grant: _grant, rows: rows}) do
    [Enum.map(@columns, &to_string/1) | Enum.map(rows, &csv_row/1)]
    |> Csv.serialize()
  end

  @doc "The report's JSON payload — the API egress for the same projection."
  def json(%{grant: grant, rows: rows, personnel_wired?: wired?}) do
    Jason.encode!(%{
      "data" => %{
        "type" => "grant_personnel_report",
        "id" => grant.id,
        "attributes" => %{
          "award_ref" => grant.award_ref,
          "funder" => grant.funder,
          "program" => grant.program,
          "personnel_wired" => wired?,
          "rows" =>
            Enum.map(rows, fn row ->
              %{
                "employee_id" => row.employee_id,
                "name" => row.name,
                "effort_pct" => row.effort_pct,
                "effective_on" => Date.to_iso8601(row.effective_on)
              }
            end)
        }
      }
    })
  end

  # -- reads -----------------------------------------------------------------

  defp fetch_grant(mount, org_id, grant_id) do
    resource = Mount.resource(mount, :Grant)

    if Code.ensure_loaded?(resource) do
      resource
      |> Ash.Query.filter(id == ^grant_id)
      |> Ash.Query.limit(1)
      |> Ash.read(scope: Mount.scope(mount, org_id))
      |> case do
        {:ok, [grant | _]} -> {:ok, grant}
        {:ok, []} -> {:error, :not_found}
        {:error, _reason} -> {:error, :not_found}
      end
    else
      {:error, :grant_not_mounted}
    end
  end

  defp resolved_report(mount, org_id, grant, config) do
    rows_mod = Mount.resource(mount, :GrantPersonnel)
    scope = Mount.scope(mount, org_id)

    if Code.ensure_loaded?(rows_mod) do
      case GrantCompliance.personnel(grant, scope,
             rows: rows_mod,
             personnel: config,
             repo: mount.repo
           ) do
        {:ok, rows} ->
          {:ok,
           %{
             grant: grant,
             rows: Enum.map(rows, &normalize_row/1),
             personnel_wired?: true
           }}

        {:error, :personnel_not_wired} ->
          bounded_report(mount, grant)
      end
    else
      bounded_report(mount, grant)
    end
  end

  # The allowed bounded-facts fallback: no HR namespace, no name column value,
  # never a guessed or synthesised name.
  defp bounded_report(mount, grant) do
    # `org_id` is not select-by-default on the grant read; the bounded-facts
    # query pins every row to it, so load it explicitly (the same requirement
    # `GrantCompliance.personnel/3` handles for the resolved path).
    grant = Ash.load!(grant, [:org_id], authorize?: false)
    rows_mod = Mount.resource(mount, :GrantPersonnel)

    cond do
      not Code.ensure_loaded?(rows_mod) ->
        {:error, :personnel_not_mounted}

      true ->
        rows =
          rows_mod
          |> Ash.Query.filter(org_id == ^grant.org_id and grant_id == ^grant.id)
          |> Ash.Query.sort(effective_on: :asc)
          |> Ash.read!(authorize?: false)
          |> Enum.map(fn row ->
            %{
              employee_id: row.employee_id,
              name: nil,
              effort_pct: row.effort_pct,
              effective_on: row.effective_on
            }
          end)

        {:ok, %{grant: grant, rows: rows, personnel_wired?: false}}
    end
  end

  # The host's HR namespace is a session-safe mount label (a module atom), the
  # same sibling-mount seam as `:crm_namespace` / `:identity_namespace`.
  defp personnel_config(%Mount{} = mount) do
    case Mount.label(mount, :personnel_namespace, nil) do
      namespace when is_atom(namespace) ->
        resource = Module.concat(namespace, :Employee)

        if Code.ensure_loaded?(resource) do
          [resource: resource, name_attribute: :full_name]
        end

      _ ->
        nil
    end
  end

  defp normalize_row(row) do
    %{
      employee_id: row.employee_id,
      name: display_name(row.name),
      effort_pct: row.effort_pct,
      effective_on: row.effective_on
    }
  end

  # The plane-resolved value, faithfully. `%Masked{}` renders `••••`;
  # `%Ash.ForbiddenField{}` is the API-key absence posture and renders empty;
  # a tenant value is the decrypted binary (a composite's JSON text).
  defp display_name(nil), do: nil
  defp display_name(%Masked{} = masked), do: to_string(masked)
  defp display_name(%Ash.ForbiddenField{}), do: nil
  defp display_name(value) when is_binary(value), do: value
  defp display_name(value), do: to_string(value)

  defp csv_row(row) do
    [
      Csv.render_cell(row.employee_id),
      Csv.render_cell(row.name),
      Csv.render_cell(row.effort_pct),
      Csv.render_cell(row.effective_on)
    ]
  end
end
