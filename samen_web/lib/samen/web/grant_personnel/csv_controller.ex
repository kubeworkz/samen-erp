defmodule Samen.Web.GrantPersonnel.CsvController do
  @moduledoc """
  The grant personnel CSV download (`/grants/:id/personnel.csv`) — the CSV
  egress of `Samen.Web.GrantPersonnel`.

  Reads the grant org-scoped, builds the shared projection, and serves it
  through `Samen.Web.Csv` (RFC 4180 + formula neutralization). The operator
  plane gets the same `••••` cell as the DOM; there is no raw-row path.
  """

  use Phoenix.Controller, formats: [:html]

  import Plug.Conn

  alias Samen.Web.CurrentOrg
  alias Samen.Web.GrantPersonnel

  def export(conn, %{"id" => grant_id} = params) do
    mount = conn.assigns[:samen_mount]
    org_id = CurrentOrg.resolve(mount, params, get_session(conn))

    case GrantPersonnel.load(mount, org_id, grant_id) do
      {:ok, report} ->
        conn
        |> put_resp_content_type("text/csv")
        |> put_resp_header(
          "content-disposition",
          ~s(attachment; filename="grant-#{grant_id}-personnel.csv")
        )
        |> send_resp(200, GrantPersonnel.csv(report))

      {:error, reason} ->
        error(conn, reason)
    end
  end

  defp error(conn, :not_found), do: conn |> put_status(404) |> text("grant not found")
  defp error(conn, :no_org), do: conn |> put_status(404) |> text("no org")
  defp error(conn, :no_mount), do: conn |> put_status(503) |> text("no mount")

  defp error(conn, :grant_not_mounted),
    do: conn |> put_status(503) |> text("grant personnel report not mounted")

  defp error(conn, reason),
    do: conn |> put_status(422) |> text("report failed: #{inspect(reason)}")
end
