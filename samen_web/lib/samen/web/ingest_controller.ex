defmodule Samen.Web.IngestController do
  @moduledoc """
  The `POST /ingest/:provider` route entry for the signed provider-ingestion
  contract. A thin Phoenix controller that delegates to
  `Samen.Web.Ingest.Ingress.ingest/2` (the `IngressController` seam pattern).

  Mounted by `Samen.Web.Router.samen_ingest_routes/1`. The host endpoint MUST
  wire `Samen.Web.Webhook.RawBodyReader` into `Plug.Parsers` so the exact signed
  bytes survive decoding.
  """

  use Phoenix.Controller, formats: [:json]

  @doc "Ingest one signed provider delivery (verify → redact → persist → enqueue)."
  def create(conn, _params), do: Samen.Web.Ingest.Ingress.ingest(conn, [])
end
