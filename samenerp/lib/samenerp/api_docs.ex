defmodule Samenerp.ApiDocs do
  @moduledoc """
  API Documentation module for Samenerp.

  Generates OpenAPI 3.0 specification for the REST API.

  ## Endpoints

  ### Authentication
  - `POST /api/v1/auth/login` — Login with email/password
  - `POST /api/v1/auth/logout` — Logout and invalidate session
  - `GET /api/v1/auth/me` — Get current user info

  ### Users
  - `GET /api/v1/users` — List users
  - `GET /api/v1/users/:id` — Get user by ID
  - `POST /api/v1/users` — Create user
  - `PUT /api/v1/users/:id` — Update user
  - `DELETE /api/v1/users/:id` — Delete user

  ### Organizations
  - `GET /api/v1/orgs` — List organizations
  - `GET /api/v1/orgs/:id` — Get organization by ID
  - `POST /api/v1/orgs` — Create organization
  - `PUT /api/v1/orgs/:id` — Update organization

  ### ERP - Chart of Accounts
  - `GET /api/v1/erp/accounts` — List accounts
  - `GET /api/v1/erp/accounts/:id` — Get account by ID
  - `POST /api/v1/erp/accounts` — Create account
  - `PUT /api/v1/erp/accounts/:id` — Update account

  ### ERP - Journal Entries
  - `GET /api/v1/erp/entries` — List journal entries
  - `GET /api/v1/erp/entries/:id` — Get entry by ID
  - `POST /api/v1/erp/entries` — Create journal entry

  ### AI Integration
  - `GET /api/v1/ai/models` — List available AI models
  - `POST /api/v1/ai/generate` — Generate text
  - `POST /api/v1/ai/stream` — Stream text generation
  - `GET /api/v1/ai/usage` — Get usage statistics

  ## Rate Limits

  All endpoints are rate-limited based on your subscription plan:

  | Plan | Requests/min | AI Requests/min |
  |---|---|---|
  | Free | 100 | 10 |
  | Pro | 1,000 | 100 |
  | Enterprise | 10,000 | 1,000 |

  Rate limit headers are included in responses:
  - `X-RateLimit-Limit` — The rate limit for the current window
  - `X-RateLimit-Remaining` — Remaining requests in the current window
  - `X-RateLimit-Reset` — Time when the window resets (Unix timestamp)

  ## Authentication

  All API requests require authentication via Bearer token:

  ```
  Authorization: Bearer your_api_key_here
  ```

  Get your API key from Settings → API Keys.

  ## Error Responses

  All errors follow this format:

  ```json
  {
    "error": "error_code",
    "message": "Human-readable error message",
    "details": {}
  }
  ```

  Common error codes:
  - `400` — Bad Request
  - `401` — Unauthorized
  - `403` — Forbidden
  - `404` — Not Found
  - `429` — Rate Limited
  - `500` — Internal Server Error
  """

  @doc """
  Generate OpenAPI 3.0 specification.
  """
  @spec generate_spec() :: map()
  def generate_spec do
    %{
      openapi: "3.0.3",
      info: %{
        title: "Samenerp API",
        description: "REST API for Samenerp ERP system",
        version: "1.0.0",
        contact: %{
          name: "API Support",
          email: "support@samenerp.com"
        }
      },
      servers: [
        %{
          url: "https://api.samenerp.com",
          description: "Production"
        },
        %{
          url: "https://staging-api.samenerp.com",
          description: "Staging"
        },
        %{
          url: "http://localhost:4050",
          description: "Local Development"
        }
      ],
      components: %{
        securitySchemes: %{
          bearerAuth: %{
            type: "http",
            scheme: "bearer",
            bearerFormat: "API Key"
          }
        },
        schemas: %{
          Error: %{
            type: "object",
            properties: %{
              error: %{type: "string"},
              message: %{type: "string"},
              details: %{type: "object"}
            }
          },
          User: %{
            type: "object",
            properties: %{
              id: %{type: "string", format: "uuid"},
              email: %{type: "string", format: "email"},
              name: %{type: "string"},
              inserted_at: %{type: "string", format: "date-time"},
              updated_at: %{type: "string", format: "date-time"}
            }
          },
          Organization: %{
            type: "object",
            properties: %{
              id: %{type: "string", format: "uuid"},
              name: %{type: "string"},
              plan: %{type: "string"},
              inserted_at: %{type: "string", format: "date-time"}
            }
          },
          Account: %{
            type: "object",
            properties: %{
              id: %{type: "string", format: "uuid"},
              code: %{type: "string"},
              name: %{type: "string"},
              type: %{type: "string", enum: ["asset", "liability", "equity", "revenue", "expense"]},
              balance: %{type: "number"}
            }
          },
          JournalEntry: %{
            type: "object",
            properties: %{
              id: %{type: "string", format: "uuid"},
              date: %{type: "string", format: "date"},
              description: %{type: "string"},
              lines: %{type: "array", items: %{type: "object"}}
            }
          },
          AiGenerateRequest: %{
            type: "object",
            required: ["model", "prompt"],
            properties: %{
              model: %{type: "string", description: "HuggingFace model ID"},
              prompt: %{type: "string", description: "Input prompt"},
              max_tokens: %{type: "integer", default: 250},
              temperature: %{type: "number", default: 0.7}
            }
          },
          AiGenerateResponse: %{
            type: "object",
            properties: %{
              text: %{type: "string"},
              tokens_used: %{type: "integer"},
              model: %{type: "string"}
            }
          }
        }
      },
      security: [%{bearerAuth: []}],
      paths: %{
        "/api/v1/auth/login" => %{
          post: %{
            tags: ["Authentication"],
            summary: "Login with email and password",
            requestBody: %{
              required: true,
              content: %{
                "application/json" => %{
                  schema: %{
                    type: "object",
                    required: ["email", "password"],
                    properties: %{
                      email: %{type: "string", format: "email"},
                      password: %{type: "string"}
                    }
                  }
                }
              }
            },
            responses: %{
              "200" => %{
                description: "Login successful",
                content: %{
                  "application/json" => %{
                    schema: %{
                      type: "object",
                      properties: %{
                        token: %{type: "string"},
                        user: %{type: "object"}
                      }
                    }
                  }
                }
              },
              "401" => %{
                description: "Invalid credentials",
                content: %{
                  "application/json" => %{
                    schema: %{"$ref" => "#/components/schemas/Error"}
                  }
                }
              }
            }
          }
        },
        "/api/v1/ai/generate" => %{
          post: %{
            tags: ["AI"],
            summary: "Generate text using AI",
            requestBody: %{
              required: true,
              content: %{
                "application/json" => %{
                  schema: %{"$ref" => "#/components/schemas/AiGenerateRequest"}
                }
              }
            },
            responses: %{
              "200" => %{
                description: "Generation successful",
                content: %{
                  "application/json" => %{
                    schema: %{"$ref" => "#/components/schemas/AiGenerateResponse"}
                  }
                }
              },
              "429" => %{
                description: "Rate limited",
                content: %{
                  "application/json" => %{
                    schema: %{"$ref" => "#/components/schemas/Error"}
                  }
                }
              }
            }
          }
        }
      }
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
end
