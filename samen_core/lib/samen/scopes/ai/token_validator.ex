defmodule Samen.Scopes.Ai.TokenValidator do
  @moduledoc """
  HuggingFace Token Validator (WS-ERP AI Integration).

  Handles key validation, lifecycle management, and background sweeps.

  ## Responsibilities

  1. **Initial Validation** — verify key against HuggingFace before saving
  2. **Background Sweeps** — periodic re-validation of all tenant keys
  3. **Revocation Detection** — flag accounts when keys become invalid
  4. **Error Handling** — graceful handling of 401, 403, 429 errors

  ## Security

  - Keys are validated synchronously on input (inline user request)
  - Background sweeps use rate-limited Oban workers
  - Invalid keys are immediately cleared from database
  - PubSub broadcasts notify UI of revocation events
  """

  @hf_whoami_url "https://huggingface.co"

  @doc """
  Validates a raw HuggingFace key against their API.

  Returns `{:ok, metadata}` if valid, `{:error, reason}` otherwise.

  ## Examples

      {:ok, meta} = Samen.Scopes.Ai.TokenValidator.verify_key("hf_xxx")
      {:error, :invalid_token} = Samen.Scopes.Ai.TokenValidator.verify_key("bad_key")
  """
  @spec verify_key(String.t()) :: {:ok, map()} | {:error, term()}
  def verify_key(raw_key) when is_binary(raw_key) do
    headers = [{"Authorization", "Bearer #{raw_key}"}]
    finch_pool = Application.get_env(:samen_core, :hf_finch_pool, SamenCore.HFHTTPClient)

    case Req.get(@hf_whoami_url,
           headers: headers,
           finch: finch_pool,
           receive_timeout: 5_000
         ) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Req.Response{status: 401}} ->
        {:error, :invalid_token}

      {:ok, %Req.Response{status: 403}} ->
        {:error, :insufficient_permissions}

      {:ok, %Req.Response{status: 429}} ->
        {:error, :huggingface_rate_limited}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:upstream_error, status}}

      {:error, %{reason: :timeout}} ->
        {:error, :timeout}

      {:error, _reason} ->
        {:error, :network_failure}
    end
  end

  def verify_key(_), do: {:error, :invalid_input}

  @doc """
  Links a HuggingFace key to a tenant after validation.

  Encrypts the key and stores it in the database.

  ## Parameters

  - `tenant` — tenant record (or map with id)
  - `raw_key` — raw HuggingFace API key

  ## Returns

  - `{:ok, updated_tenant}` on success
  - `{:error, reason}` on validation failure
  """
  @spec link_key(map(), String.t()) :: {:ok, map()} | {:error, term()}
  def link_key(tenant, raw_key) when is_binary(raw_key) do
    case verify_key(raw_key) do
      {:ok, _hf_meta} ->
        # Token is valid, encrypt and store
        iv = :crypto.strong_rand_bytes(12)

        case Samen.Scopes.Ai.Crypto.encrypt(raw_key, iv) do
          {:ok, ciphertext} ->
            key_prefix = String.slice(raw_key, 0, min(8, byte_size(raw_key)))

            updated_tenant =
              tenant
              |> Map.put(:encrypted_hf_key, ciphertext)
              |> Map.put(:encryption_iv, iv)
              |> Map.put(:key_prefix, key_prefix)
              |> Map.put(:hf_status, :active)
              |> Map.put(:hf_validated_at, DateTime.utc_now())

            {:ok, updated_tenant}

          {:error, reason} ->
            {:error, {:encryption_failed, reason}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  def link_key(_, _), do: {:error, :invalid_input}

  @doc """
  Revokes a tenant's HuggingFace key.

  Clears encrypted credentials and flags the account as requiring setup.
  """
  @spec revoke_key(map()) :: {:ok, map()}
  def revoke_key(tenant) do
    updated_tenant =
      tenant
      |> Map.put(:encrypted_hf_key, nil)
      |> Map.put(:encryption_iv, nil)
      |> Map.put(:key_prefix, nil)
      |> Map.put(:hf_status, :revoked)

    # Broadcast revocation event for real-time UI updates
    broadcast_revocation(tenant.id)

    {:ok, updated_tenant}
  end

  @doc """
  Verifies a tenant's existing key is still valid.

  Used by background sweep workers to detect revoked keys.
  """
  @spec verify_existing_key(map()) :: :ok | {:error, term()}
  def verify_existing_key(%{encrypted_hf_key: nil}), do: :ok
  def verify_existing_key(%{hf_status: :revoked}), do: :ok

  def verify_existing_key(%{encrypted_hf_key: encrypted, encryption_iv: iv}) do
    decrypted_key = Samen.Scopes.Ai.Crypto.decrypt(encrypted, iv)

    case verify_key(decrypted_key) do
      {:ok, _meta} ->
        # Force GC to flush decrypted key from memory
        :erlang.garbage_collect()
        :ok

      {:error, reason} when reason in [:invalid_token, :insufficient_permissions] ->
        :erlang.garbage_collect()
        {:error, :revoked}

      {:error, :huggingface_rate_limited} ->
        :erlang.garbage_collect()
        {:error, :rate_limited}

      {:error, reason} ->
        :erlang.garbage_collect()
        {:error, reason}
    end
  end

  def verify_existing_key(_), do: {:error, :invalid_tenant}

  @doc """
  Processes a batch of tenants for background key verification.

  Returns list of `{tenant_id, result}` tuples.
  """
  @spec sweep_keys([map()]) :: [{String.t(), :ok | {:error, term()}}]
  def sweep_keys(tenants) when is_list(tenants) do
    Enum.map(tenants, fn tenant ->
      result = verify_existing_key(tenant)
      {tenant.id, result}
    end)
  end

  # Broadcast revocation event via PubSub
  defp broadcast_revocation(tenant_id) do
    pubsub = Application.get_env(:samen_core, :pubsub, Samen.PubSub)

    if pubsub do
      Phoenix.PubSub.broadcast(
        pubsub,
        "tenant_settings:#{tenant_id}",
        {:tenant_updated, %{hf_status: :revoked}}
      )
    end
  end
end
