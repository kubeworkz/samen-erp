defmodule SamenerpWeb.DocsController do
  @moduledoc """
  The public documentation surface (`/docs`).

  Static HTML from `SamenerpWeb.Docs`: no session, no org, no LiveView, no
  database read — the docs render even while Postgres is unavailable (the same
  posture as `SamenerpWeb.PageController.healthz/2`). The category ids are the
  tenant sidebar's group ids, so `/docs/erp` documents the sidebar's **ERP**
  group.
  """
  use Phoenix.Controller, formats: [:html]

  def index(conn, _params) do
    html(conn, SamenerpWeb.Docs.index_html())
  end

  def show(conn, %{"id" => "getting-started"}) do
    html(conn, SamenerpWeb.Docs.getting_started_html())
  end

  def show(conn, %{"id" => id}) do
    case SamenerpWeb.Docs.group_html(id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> html(SamenerpWeb.Docs.not_found_html())

      body ->
        html(conn, body)
    end
  end
end
