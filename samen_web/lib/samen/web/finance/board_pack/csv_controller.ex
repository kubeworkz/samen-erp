defmodule Samen.Web.Finance.BoardPack.CsvController do
  @moduledoc """
  The board pack's CSV download (`/board/export.csv`).

  The org comes from the session and the mount from the route assigns, the
  same posture as `Samen.Web.Csv.ExportController` and the grant personnel
  download. The rows are the SAME report the page renders, serialized
  through `Samen.Web.Csv` (RFC 4180 + formula neutralization); there is no
  second projection.
  """

  use Phoenix.Controller, formats: [:html]

  import Plug.Conn

  alias Samen.Web.CurrentOrg
  alias Samen.Web.Finance.BoardPack

  def export(conn, params) do
    mount = conn.assigns[:samen_mount]
    org_id = CurrentOrg.resolve(mount, params, get_session(conn))

    case BoardPack.load(mount, org_id) do
      {:ok, state} ->
        conn
        |> put_resp_content_type("text/csv")
        |> put_resp_header("content-disposition", ~s(attachment; filename="board-pack.csv"))
        |> send_resp(200, BoardPack.csv(state.report))

      {:error, reason} ->
        error(conn, reason)
    end
  end

  defp error(conn, :not_found), do: conn |> put_status(404) |> text("not found")
  defp error(conn, :no_org), do: conn |> put_status(404) |> text("no org")
  defp error(conn, :no_mount), do: conn |> put_status(503) |> text("no mount")
  defp error(conn, :no_period), do: conn |> put_status(404) |> text("no fiscal period")

  defp error(conn, :finance_not_mounted),
    do: conn |> put_status(503) |> text("finance not mounted")

  defp error(conn, reason),
    do: conn |> put_status(422) |> text("board pack failed: #{inspect(reason)}")
end
