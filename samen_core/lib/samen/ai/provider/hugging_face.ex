defmodule Samen.AI.Provider.HuggingFace do
  @moduledoc """
  HuggingFace-via-BYOK `Samen.AI.Provider` adapter (OpenClaw-lite P1 companion to
  the reference vendor adapter, ADR-043 §5.1).

  **MaskedPayload-only** — both callbacks head-match `%Samen.AI.MaskedPayload{}`; a
  raw string refuses by `FunctionClauseError` (the INV-7 clause gate,
  `VaultField.dump_to_native` precedent).

  **Key never touches a config column on this path**: the HF key is NOT expected
  in `config[:api_key]` alone. It is resolved per-request from `config[:org_id]`'s
  org-owned BYOK row (`Samen.Scopes.Ai.ApiKey` — the `/settings/huggingface`
  seam) — the scope's `tenant_id` today is that org id — decrypted IN-MEMORY
  via `Samen.Scopes.Ai.Crypto.decrypt/2`, forwarded to HF, then GC'd. No key is
  ever written to a config file: `config[:api_key]` is HONORED when a caller
  passes it directly (hosts still can), but `config[:org_id]` is the BYOK path.

  **Fail-honest**: an unwired tenant (`:org_id` names no `aik_api_key` row with
  `encrypted_key` + `encryption_iv`) or a broken decrypt (`decrypt/2` raise /
  `valid_hf_key?/1` shape miss) returns `{:error, :not_configured}` (the seeded
  org has not connected at `/settings/huggingface`), never a canned `{:ok, _}`.
  That failure is exactly the surface `Samen.Web.AI.Server.configuration_hint/0`
  renders VERBATIM via `Samen.AI.configuration_hint/0` on the AI kit's
  `:not_configured` branch — so an honest `:not_configured` here becomes the
  honest empty-state copy there (`Components.ai_result/1`). HF-transport errors
  (401/429/5xx) are NORMALIZED to bounded `{:provider_error, :hugging_face}`
  before they propagate per INV-7 §3.2b / EG6, so the adapter's Inspect-redacted
  seam never leaks a key or a segment — same status-code→error mapping
  `Samen.Scopes.Ai.Client` already ships, just post-scrub.
  """

  @behaviour Samen.AI.Provider

  require Ash.Query

  alias Samen.AI.Completion
  alias Samen.AI.MaskedPayload
  alias Samen.Scopes.Ai.ApiKey
  alias Samen.Scopes.Ai.Crypto
  alias Samen.Scopes.Ai.HttpAdapter

  @hf_base_url "https://huggingface.co"

  @impl Samen.AI.Provider
  def complete(%MaskedPayload{} = payload, config) when is_map(config) do
    case resolve_key(config) do
      {:ok, api_key} -> dispatch(payload, api_key, config)
      {:error, _reason} -> {:error, :not_configured}
    end
  end

  @impl Samen.AI.Provider
  def embed(%MaskedPayload{} = _payload, _config) do
    {:error, :not_implemented}
  end

  # ---------------------------------------------------------------------------
  # Internals

  defp resolve_key(config) do
    cond do
      present?(config, :api_key) ->
        {:ok, Map.get(config, :api_key)}

      present?(config, :org_id) ->
        case decrypt_row(Map.get(config, :org_id)) do
          nil ->
            {:error, :not_configured}

          row ->
            with {:ok, api_key} <- decrypt_api_key_from_row(row),
                 :ok <- assert_key_shape(api_key) do
              {:ok, api_key}
            else
              _ -> {:error, :not_configured}
            end
        end

      true ->
        {:error, :not_configured}
    end
  rescue
    _ -> {:error, :not_configured}
  end

  defp decrypt_row(org_id) when is_binary(org_id) do
    query =
      ApiKey
      |> Ash.Query.filter(tenant_id == ^org_id)
      |> Ash.Query.limit(1)

    case Ash.read(query, authorize?: false) do
      {:ok, [row | _]} -> row
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp decrypt_row(_org_id), do: nil

  defp decrypt_api_key_from_row(%ApiKey{encrypted_key: ct, encryption_iv: iv})
       when is_binary(ct) and byte_size(ct) > 16 and is_binary(iv) and byte_size(iv) == 12 do
    decrypted = Samen.Scopes.Ai.Crypto.decrypt(ct, iv)
    :erlang.garbage_collect()
    {:ok, decrypted}
  rescue
    _ -> {:error, :decryption_failed}
  end

  defp decrypt_api_key_from_row(_), do: {:error, :no_key}

  defp assert_key_shape(api_key) do
    cond do
      not is_binary(api_key) -> {:error, :invalid_key_shape}
      Crypto.valid_hf_key?(api_key) -> :ok
      true -> {:error, :invalid_key_shape}
    end
  end

  defp present?(config, key) do
    case Map.get(config, key) do
      nil -> false
      "" -> false
      _ -> true
    end
  end

  defp dispatch(%MaskedPayload{} = payload, api_key, config) do
    model =
      Map.get(config, :model_id) || Map.get(config, :model) ||
        "mistralai/Mistral-7B-Instruct-v0.3"

    prompt = payload.segments |> Enum.map(&to_string/1) |> Enum.join("\n")
    url = "#{@hf_base_url}/#{model}"

    headers = [
      {"Authorization", "Bearer #{api_key}"},
      {"Content-Type", "application/json"}
    ]

    body =
      Jason.encode!(%{
        inputs: prompt,
        parameters: %{
          max_new_tokens: Map.get(config, :max_new_tokens, 250),
          temperature: Map.get(config, :temperature, 0.7),
          top_p: Map.get(config, :top_p, 0.9),
          do_sample: Map.get(config, :do_sample, true)
        }
      })

    http_opts = [timeout: 30_000, connect_timeout: 5_000]

    res =
      case Map.get(config, :transport) do
        fun when is_function(fun, 1) ->
          fun.(%{url: url, headers: headers, body: body, api_key: api_key, model: model})

        _ ->
          HttpAdapter.post(url, headers, body, http_opts)
      end

    gc = fn -> :erlang.garbage_collect() end

    case res do
      {:ok, 200, resp} ->
        _ = gc.()
        {:ok, to_completion(resp, model)}

      {:ok, status, _resp_body} when status in [401, 403] ->
        _ = gc.()
        {:error, :not_configured}

      {:ok, 429, _resp_body} ->
        _ = gc.()
        {:error, :tenant_quota_exhausted}

      {:ok, _status, _resp_body} ->
        _ = gc.()
        {:error, {:provider_error, :hugging_face}}

      {:error, reason} when is_atom(reason) ->
        _ = gc.()
        {:error, reason}

      {:error, _reason} ->
        _ = gc.()
        {:error, {:provider_error, :hugging_face}}

      other when is_map(other) and map_size(other) > 0 ->
        _ = gc.()
        {:ok, to_completion(other, model)}

      _ ->
        _ = gc.()
        {:error, {:provider_error, :hugging_face}}
    end
  rescue
    _ -> {:error, {:provider_error, :hugging_face}}
  end

  defp to_completion(resp, model) when is_list(resp) do
    text =
      case resp do
        [%{"generated_text" => t} | _] when is_binary(t) -> t
        [%{"text" => t} | _] when is_binary(t) -> t
        _ -> Jason.encode!(resp)
      end

    %Completion{text: text, model: model, provider: :hugging_face, usage: %{}, meta: %{}}
  end

  defp to_completion(resp, model) when is_map(resp) do
    text =
      cond do
        is_binary(Map.get(resp, "generated_text")) -> Map.get(resp, "generated_text")
        is_binary(Map.get(resp, "text")) -> Map.get(resp, "text")
        is_binary(Map.get(resp, "content")) -> Map.get(resp, "content")
        true -> Jason.encode!(resp)
      end

    %Completion{text: text, model: model, provider: :hugging_face, usage: %{}, meta: %{}}
  end

  defp to_completion(resp, model) when is_binary(resp) do
    %Completion{text: resp, model: model, provider: :hugging_face, usage: %{}, meta: %{}}
  end

  defp to_completion(_resp, model) do
    %Completion{text: "", model: model, provider: :hugging_face, usage: %{}, meta: %{}}
  end
end
