defmodule Samen.Web.Notes.ExportController do
  @moduledoc """
  The WS-Notes page DOWNLOAD routes (ADR-053 §5 D5, §6 R6; WS-Notes Phase 2 unit 2.4) —
  `GET <pages_path>/:id/export.md` and `GET <pages_path>/:id/export.csv`.

  Mount/session posture mirrors `Samen.Web.Csv.ExportController` and
  `Samen.Web.Ics.ExportController` exactly:

    1. **Org-scope** — the org comes from the session (`Samen.Web.CurrentOrg.resolve/3`), the
       scope from the mount's plane. Another org's page is `404 page not found`, the same answer
       an unknown id gets (R1: no existence oracle).

    2. **Masking (R6)** — there is NO plane gate here and none is needed: `Export` renders through
       `Samen.Web.Notes.Reads`, which resolves every block on the acting plane before any byte is
       serialized. An operator downloads a page whose vaulted blocks are `••••` — the same pixels
       the editor shows. Refusing the download would be posture; rendering the mask is the
       guarantee.

  These are controller actions, not LiveViews, so they ride the route `assigns` (the mount) and
  live OUTSIDE the notes `live_session`; the host's `:browser` pipeline still supplies the session
  plug `CurrentOrg` reads.
  """

  use Phoenix.Controller, formats: [:html]

  import Plug.Conn

  alias Samen.Web.CurrentOrg
  alias Samen.Web.Mount
  alias Samen.Web.Notes.Export

  @doc "`GET <pages_path>/:id/export.md` — the page as Markdown."
  def markdown(conn, params), do: serve(conn, params, :markdown)

  @doc "`GET <pages_path>/:id/export.csv` — the page's blocks as CSV."
  def csv(conn, params), do: serve(conn, params, :csv)

  defp serve(conn, params, format) do
    mount = conn.assigns[:samen_mount]
    org_id = CurrentOrg.resolve(mount, params, get_session(conn))

    do_serve(conn, mount, org_id, Map.get(params, "id"), format)
  end

  defp do_serve(conn, nil, _org_id, _id, _format), do: conn |> put_status(503) |> text("no mount")

  defp do_serve(conn, _mount, nil, _id, _format), do: conn |> put_status(404) |> text("no org")

  defp do_serve(conn, mount, org_id, id, format) do
    scope = Mount.scope(mount, org_id)

    case build(mount, scope, id, format) do
      {:ok, %{body: body, filename: filename}} ->
        conn
        |> put_resp_content_type(content_type(format))
        |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename}"))
        |> send_resp(200, body)

      {:error, :not_found} ->
        conn |> put_status(404) |> text("page not found")
    end
  end

  defp build(mount, scope, id, :markdown), do: Export.markdown(mount, scope, id)
  defp build(mount, scope, id, :csv), do: Export.csv(mount, scope, id)

  defp content_type(:markdown), do: "text/markdown; charset=utf-8"
  defp content_type(:csv), do: "text/csv; charset=utf-8"
end
