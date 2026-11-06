defmodule Samen.Web.GrantPersonnel.ApiController do
  @moduledoc """
  The grant personnel JSON API (`/grants/:id/personnel.json`) — the API
  egress of `Samen.Web.GrantPersonnel`.

  The payload is built from the SAME plane-resolved projection as the DOM and
  CSV: tenant names are clear, operator names are `••••`, and neither a
  plaintext nor a `vt_*` token can enter the body. This is the session-scoped
  report API; the host's external `/api/v1` surface remains AshJsonApi-only.
  """

  use Phoenix.Controller, formats: [:json]

  import Plug.Conn

  alias Samen.Web.CurrentOrg
  alias Samen.Web.GrantPersonnel

  def show(conn, %{"id" => grant_id} = params) do
    mount = conn.assigns[:samen_mount]
    org_id = CurrentOrg.resolve(mount, params, get_session(conn))

    case GrantPersonnel.load(mount, org_id, grant_id) do
      {:ok, report} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, GrantPersonnel.json(report))

      {:error, reason} ->
        error(conn, reason)
    end
  end

  defp error(conn, :not_found), do: conn |> put_status(404) |> json_error("grant not found")
  defp error(conn, :no_org), do: conn |> put_status(404) |> json_error("no org")
  defp error(conn, :no_mount), do: conn |> put_status(503) |> json_error("no mount")

  defp error(conn, :grant_not_mounted),
    do: conn |> put_status(503) |> json_error("grant personnel report not mounted")

  defp error(conn, reason),
    do: conn |> put_status(422) |> json_error("report failed: #{inspect(reason)}")

  defp json_error(conn, message) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(conn.status, Jason.encode!(%{"error" => message}))
  end
end
