defmodule Samen.Scopes.Ai.Client do
  @moduledoc """
  HuggingFace API Client (WS-ERP AI Integration).

  BYOK (Bring Your Own Key) proxy that executes AI tasks on behalf of tenants
  using their HuggingFace API keys. Keys are decrypted in-memory only for the
  duration of the request, then flushed via GC.

  ## Architecture

  1. Tenant sends request with JWT/Session
  2. Backend fetches encrypted key for tenant_id
  3. Backend decrypts key via KMS (in-memory only)
  4. Backend forwards request to HuggingFace
  5. HuggingFace bills directly to Tenant's HF Account

  ## Error Handling

  - 401 → :invalid_tenant_key (flag account as "Setup Required")
  - 429 → :tenant_quota_exhausted (display error to user)
  - 5xx → :upstream_error (retry logic)
  """

  @hf_base_url "https://huggingface.co"

  @doc """
  Executes text generation using the tenant's decrypted API key.

  ## Parameters

  - `model_id` — HuggingFace model identifier
  - `prompt` — input text prompt
  - `decrypted_key` — tenant's decrypted API key
  - `opts` — additional options (max_new_tokens, temperature, etc.)

  ## Returns

  - `{:ok, response_body}` on success
  - `{:error, :invalid_tenant_key}` on 401
  - `{:error, :tenant_quota_exhausted}` on 429
  - `{:error, {:hf_api_error, status, body}}` on other errors
  - `{:error, {:network_failure, reason}}` on network errors
  """
  @spec generate_text(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def generate_text(model_id, prompt, decrypted_key, opts \\ []) do
    url = "#{@hf_base_url}/#{model_id}"

    headers = [
      {"Authorization", "Bearer #{decrypted_key}"},
      {"Content-Type", "application/json"}
    ]

    body =
      Jason.encode!(%{
        inputs: prompt,
        parameters: %{
          max_new_tokens: Keyword.get(opts, :max_new_tokens, 250),
          temperature: Keyword.get(opts, :temperature, 0.7),
          top_p: Keyword.get(opts, :top_p, 0.9),
          do_sample: Keyword.get(opts, :do_sample, true)
        }
      })

    case Samen.Scopes.Ai.HttpAdapter.post(url, headers, body,
           timeout: 30_000,
           connect_timeout: 5_000
         ) do
      {:ok, 200, response_body} ->
        {:ok, response_body}

      {:ok, 401, _body} ->
        {:error, :invalid_tenant_key}

      {:ok, 429, _body} ->
        {:error, :tenant_quota_exhausted}

      {:ok, 403, _body} ->
        {:error, :insufficient_permissions}

      {:ok, status, error_body} ->
        {:error, {:hf_api_error, status, error_body}}

      {:error, reason} ->
        {:error, {:network_failure, reason}}
    end
  end

  @doc """
  Validates a HuggingFace API key against their whoami endpoint.

  Returns `{:ok, metadata}` if valid, `{:error, reason}` otherwise.
  """
  @spec verify_key(String.t()) :: {:ok, map()} | {:error, term()}
  def verify_key(raw_key) do
    headers = [{"Authorization", "Bearer #{raw_key}"}]

    case Samen.Scopes.Ai.HttpAdapter.get(@hf_base_url, headers, timeout: 5_000) do
      {:ok, 200, body} ->
        {:ok, body}

      {:ok, 401, _body} ->
        {:error, :invalid_token}

      {:ok, 403, _body} ->
        {:error, :insufficient_permissions}

      {:ok, 429, _body} ->
        {:error, :huggingface_rate_limited}

      {:ok, status, _body} ->
        {:error, {:upstream_error, status}}

      {:error, :timeout} ->
        {:error, :timeout}

      {:error, _reason} ->
        {:error, :network_failure}
    end
  end

  @doc """
  Lists available models from HuggingFace.
  """
  @spec list_models(String.t(), keyword()) :: {:ok, list()} | {:error, term()}
  def list_models(decrypted_key, opts \\ []) do
    url = "#{@hf_base_url}/api/models"
    headers = [{"Authorization", "Bearer #{decrypted_key}"}]

    params =
      %{}
      |> maybe_put(:search, Keyword.get(opts, :search))
      |> maybe_put(:limit, Keyword.get(opts, :limit, 20))
      |> maybe_put(:sort, Keyword.get(opts, :sort, :downloads))
      |> maybe_put(:direction, Keyword.get(opts, :direction, -1))

    # Query params (Req's `params:`) become an explicit query string — the
    # defaults above guarantee a non-empty map.
    url = "#{url}?#{URI.encode_query(params)}"

    case Samen.Scopes.Ai.HttpAdapter.get(url, headers, timeout: 10_000) do
      {:ok, 200, models} ->
        {:ok, models}

      {:ok, 401, _body} ->
        {:error, :invalid_tenant_key}

      {:ok, 429, _body} ->
        {:error, :tenant_quota_exhausted}

      {:error, reason} ->
        {:error, {:network_failure, reason}}
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
