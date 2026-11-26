defmodule Samenerp.ApiDocs do
  @moduledoc """
  The OpenAPI 3.0 document for this host's public API — generated from the
  JSON:API router's OWN route table, never from a hand-written endpoint list.

  `SamenerpWeb.Api.Router` is the AshJsonApi router the Phoenix router forwards
  to; `generate_spec/0` asks that router which routes it actually serves
  (`AshJsonApi.Router.formatted_routes/1`), matches them back to their resource
  routes, and prefixes each path with the mount point read out of
  `SamenerpWeb.Router.__routes__/0`. So a route the endpoint does not serve
  cannot appear in the document, and a newly mounted route cannot be missing
  from it — moving the `forward/2` or adding a `json_api` route moves the spec.

  This mattered: the previous hand-written document advertised
  `POST /api/v1/auth/login` and `POST /api/v1/ai/generate`, both of which this
  host answers 404 (its `/api/v1` is the JSON:API surface over
  `Samenerp.Vertical`). `/docs/api-reference` renders this document, so the
  readable page advertised dead endpoints too; `docs_routes_test.exs` now
  asserts every advertised path is served (not 404) as well as row-for-row
  agreement with this module.

  ## What the served surface is bounded by

  Reads run through each resource's `:api_read` action (keyset pagination,
  `default_limit 50`, `max_page_size 200`, `page[limit]` clamped by
  `Samen.Web.Api.PageLimitClamp`), authorization is the resources' own policy
  stack (OrgScope + RBAC), and a field outside `json_api show_fields` is absent
  from every payload — including the vault field.
  """

  @doc """
  Generate the OpenAPI 3.0 specification for the routes this host mounts.
  """
  @spec generate_spec() :: map()
  def generate_spec do
    router = SamenerpWeb.Api.Router

    # The authority: the routes the AshJsonApi endpoint actually dispatches.
    served =
      router
      |> AshJsonApi.Router.formatted_routes()
      |> MapSet.new(fn route -> {route.verb, route.path} end)

    resources =
      router.domains()
      |> Enum.flat_map(&Ash.Domain.Info.resources/1)

    prefix = api_prefix()

    paths =
      for resource <- resources,
          route <- AshJsonApi.Resource.Info.routes(resource),
          MapSet.member?(served, {route.method, route.route}),
          reduce: %{} do
        acc ->
          path = prefix <> route.route
          operations = Map.get(acc, path, %{})
          Map.put(acc, path, Map.put(operations, route.method, operation(resource, route)))
      end

    %{
      openapi: "3.0.3",
      info: %{
        title: "Samenerp API",
        description:
          "The versioned JSON:API surface this host mounts. Every path here is served by the " <>
            "AshJsonApi router under the mount point below; reads are org-scoped and keyset-bounded " <>
            "(default limit 50, max page size 200).",
        version: api_version()
      },
      servers: [%{url: "/", description: "This host"}],
      components: %{
        securitySchemes: %{
          bearerAuth: %{type: "http", scheme: "bearer", bearerFormat: "API Key"}
        },
        schemas: schemas(resources)
      },
      security: [%{bearerAuth: []}],
      paths: paths
    }
  end

  @doc """
  Render OpenAPI spec as JSON.
  """
  @spec render_spec() :: String.t()
  def render_spec do
    generate_spec()
    |> Jason.encode!(pretty: true)
  end

  @doc """
  Serve OpenAPI spec endpoint.
  """
  @spec serve_spec(Plug.Conn.t()) :: Plug.Conn.t()
  def serve_spec(conn) do
    conn
    |> Plug.Conn.put_resp_header("content-type", "application/json")
    |> Plug.Conn.send_resp(200, render_spec())
  end

  # ---- the spec, derived ---------------------------------------------------

  # The `forward/2` target in the Phoenix router — moving the mount moves the
  # spec with it. Falls back to the documented default only if the forward is
  # gone (in which case no /api path is served at all).
  defp api_prefix do
    Enum.find_value(SamenerpWeb.Router.__routes__(), "/api/v1", fn route ->
      if route.plug == SamenerpWeb.Api.Endpoint, do: route.path
    end)
  end

  defp api_version do
    to_string(Application.spec(:samenerp, :vsn) || "0.1.0")
  end

  defp operation(resource, route) do
    type = AshJsonApi.Resource.Info.type(resource)
    by_id? = String.contains?(route.route, ":id")

    %{
      tags: [type],
      summary: "#{action_verb(route.action)} #{type}#{if by_id?, do: " by id", else: ""}",
      operationId: "#{route.action}_#{type}#{if by_id?, do: "_by_id", else: ""}",
      parameters: parameters(by_id?),
      responses: responses(by_id?)
    }
  end

  defp parameters(false), do: []

  defp parameters(true) do
    [%{name: "id", in: "path", required: true, schema: %{type: "string", format: "uuid"}}]
  end

  defp responses(by_id?) do
    base = %{
      "200" => %{description: "The JSON:API document"},
      "401" => %{description: "Missing or invalid API key"},
      "403" => %{description: "Refused by the resource's own policy stack (org scope / role)"}
    }

    if by_id?,
      do: Map.put(base, "404", %{description: "No such record in the caller's org"}),
      else: base
  end

  defp action_verb(:api_read), do: "Read"

  defp action_verb(action) do
    action
    |> to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  # Only the fields the resource EXPOSES (`json_api show_fields`) reach the
  # schema: the same deny-by-default allowlist the serializer honours, so the
  # document cannot name a field a payload never carries.
  defp schemas(resources) do
    Map.new(resources, fn resource ->
      properties =
        resource
        |> Ash.Resource.Info.public_attributes()
        |> Enum.filter(&AshJsonApi.Resource.Info.show_field?(resource, &1.name))
        |> Map.new(fn attribute -> {attribute.name, field_schema(attribute)} end)

      {AshJsonApi.Resource.Info.type(resource), %{type: "object", properties: properties}}
    end)
  end

  defp field_schema(attribute) do
    case attribute.type do
      Ash.Type.UUID -> %{type: "string", format: "uuid"}
      Ash.Type.String -> %{type: "string"}
      Ash.Type.Integer -> %{type: "integer"}
      Ash.Type.Boolean -> %{type: "boolean"}
      Ash.Type.UtcDatetime -> %{type: "string", format: "date-time"}
      Ash.Type.UtcDatetimeUsec -> %{type: "string", format: "date-time"}
      _other -> %{type: "string"}
    end
  end
end
