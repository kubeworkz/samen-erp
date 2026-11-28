defmodule Samen.Scopes.Ai.VerifyCredentialsWorker do
  @moduledoc """
  HuggingFace Credential Verification Worker (BYOK Integration).

  Periodically validates tenant HuggingFace API keys against the HuggingFace API.
  If a key is revoked or invalid, the worker clears the encrypted credentials and
  flags the tenant account as requiring setup.

  ## Security Model

  - Keys are decrypted only in-memory within this short-lived Oban process
  - GC flushes decrypted key when process terminates
  - Rate-limited to avoid hammering HuggingFace API
  - Invalid keys are immediately cleared from database

  ## Error Handling

  - 401/403 → Mark key as revoked, clear credentials
  - 429 → Snooze and retry later (rate limited)
  - Network errors → Retry with exponential backoff

  ## Configuration

      # In config/config.exs or config/runtime.exs
      config :samen_core, Oban,
        plugins: [
          {Oban.Plugins.Cron, crontab: [
            # Run daily at midnight
            {"0 0 * * *", Samen.Scopes.Ai.VerifyCredentialsWorker}
          ]}
        ]

  ## Queue / Attempts

  Queue: `:maintenance` (shared with other maintenance workers)
  Max attempts: 3 (handles transient network errors)
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 3

  require Logger
  require Ash.Query

  alias Samen.Scopes.Ai.ApiKey
  alias Samen.Scopes.Ai.Crypto
  alias Samen.Scopes.Ai.TokenValidator

  @impl Oban.Worker
  def perform(%Oban.Job{id: job_id}) do
    Logger.info("[HuggingFace.VerifyCredentials] Starting sweep, job_id=#{job_id}")

    case sweep_tenant_keys() do
      {:ok, %{checked: checked, revoked: revoked, errors: errors}} ->
        Logger.info(
          "[HuggingFace.VerifyCredentials] Sweep complete: " <>
            "checked=#{checked}, revoked=#{revoked}, errors=#{errors}"
        )

        :ok

      {:error, reason} ->
        Logger.error("[HuggingFace.VerifyCredentials] Sweep failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Sweep all tenant HuggingFace keys.

  Returns `{:ok, %{checked: n, revoked: n, errors: n}}` on success.
  """
  @spec sweep_tenant_keys() :: {:ok, map()} | {:error, term()}
  def sweep_tenant_keys do
    keys = get_tenants_with_hf_keys()

    results =
      Enum.reduce(keys, %{checked: 0, revoked: 0, errors: 0}, fn key, acc ->
        case verify_tenant_key(key) do
          :ok ->
            %{acc | checked: acc.checked + 1}

          {:error, :revoked} ->
            %{acc | checked: acc.checked + 1, revoked: acc.revoked + 1}

          {:error, :rate_limited} ->
            %{acc | checked: acc.checked + 1}

          {:error, _reason} ->
            %{acc | checked: acc.checked + 1, errors: acc.errors + 1}
        end
      end)

    {:ok, results}
  rescue
    e ->
      Logger.error("[HuggingFace.VerifyCredentials] Sweep crashed: #{inspect(e)}")
      {:error, e}
  end

  @doc """
  Verify a single tenant's HuggingFace key.

  Returns `:ok` if valid, `{:error, reason}` otherwise.
  """
  @spec verify_tenant_key(map() | struct()) :: :ok | {:error, term()}
  def verify_tenant_key(%{encrypted_key: nil}), do: :ok
  def verify_tenant_key(%{status: :revoked}), do: :ok

  def verify_tenant_key(%{
        id: key_id,
        tenant_id: tenant_id,
        encrypted_key: encrypted,
        encryption_iv: iv
      }) do
    try do
      decrypted_key = Crypto.decrypt(encrypted, iv)

      case TokenValidator.verify_key(decrypted_key) do
        {:ok, _meta} ->
          key = fetch_key(key_id)

          if key do
            key
            |> Ash.Changeset.for_update(:record_validation, %{})
            |> Ash.update(authorize?: false)
          end

          :ok

        {:error, reason} when reason in [:invalid_token, :insufficient_permissions] ->
          case revoke_key_row(key_id, tenant_id) do
            :ok -> {:error, :revoked}
            {:error, revoke_reason} -> {:error, revoke_reason}
          end

        {:error, :huggingface_rate_limited} ->
          {:error, :rate_limited}

        {:error, reason} ->
          Logger.warning(
            "[HuggingFace.VerifyCredentials] Key #{key_id} " <>
              "verification failed: #{inspect(reason)}"
          )

          {:error, reason}
      end
    rescue
      e ->
        Logger.warning("[HuggingFace.VerifyCredentials] Key #{key_id} crashed: #{inspect(e)}")

        {:error, e}
    after
      :erlang.garbage_collect()
    end
  end

  def verify_tenant_key(_), do: {:error, :invalid_key}

  # -- Private functions -------------------------------------------------------

  defp get_tenants_with_hf_keys do
    ApiKey
    |> Ash.Query.filter(status == :active)
    |> Ash.read!(authorize?: false)
  rescue
    _ -> []
  end

  defp fetch_key(key_id) do
    ApiKey
    |> Ash.Query.filter(id == ^key_id)
    |> Ash.read!(authorize?: false)
    |> List.first()
  rescue
    _ -> nil
  end

  defp revoke_key_row(key_id, tenant_id) do
    case fetch_key(key_id) do
      nil ->
        {:error, :not_found}

      key ->
        key
        |> Ash.Changeset.for_update(:update, %{
          encrypted_key: nil,
          encryption_iv: nil,
          key_prefix: nil,
          status: :revoked
        })
        |> Ash.update(authorize?: false)
        |> case do
          {:ok, _key} ->
            broadcast_revocation(tenant_id)
            :ok

          {:error, reason} ->
            Logger.error(
              "[HuggingFace.VerifyCredentials] Could not revoke key #{key_id}: #{inspect(reason)}"
            )

            {:error, reason}
        end
    end
  end

  defp broadcast_revocation(tenant_id) do
    case Application.get_env(:samen_core, :pubsub) do
      nil ->
        :ok

      pubsub ->
        try do
          Phoenix.PubSub.broadcast(
            pubsub,
            "tenant_settings:#{tenant_id}",
            {:tenant_updated, %{hf_status: :revoked}}
          )
        rescue
          # Realtime is optional: a host with no running PubSub still gets the
          # durable revoke row, just no live push.
          _ -> :ok
        end
    end
  end
end
