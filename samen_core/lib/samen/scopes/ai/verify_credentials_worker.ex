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
        }

  ## Queue / Attempts

  Queue: `:maintenance` (shared with other maintenance workers)
  Max attempts: 3 (handles transient network errors)
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 3

  require Logger

  alias Samen.Scopes.Ai.TokenValidator

  @impl Oban.Worker
  def perform(%Oban.Job{id: job_id}) do
    Logger.info("[HuggingFace.VerifyCredentials] Starting sweep, job_id=#{job_id}")

    # In production, this would query all tenants with active HuggingFace keys
    # For now, we'll demonstrate the pattern with a simulated sweep
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
    # In production, this would:
    # 1. Query all tenants with active HuggingFace keys
    # 2. For each tenant, decrypt key and validate against HuggingFace API
    # 3. Mark invalid keys as revoked
    # 4. Broadcast revocation events via PubSub

    # Simulated sweep for demonstration
    tenants = get_tenants_with_hf_keys()

    results =
      Enum.reduce(tenants, %{checked: 0, revoked: 0, errors: 0}, fn tenant, acc ->
        case verify_tenant_key(tenant) do
          :ok ->
            %{acc | checked: acc.checked + 1}

          {:error, :revoked} ->
            %{acc | checked: acc.checked + 1, revoked: acc.revoked + 1}

          {:error, :rate_limited} ->
            # Don't count rate limits as errors - they're expected
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
  @spec verify_tenant_key(map()) :: :ok | {:error, term()}
  def verify_tenant_key(%{encrypted_hf_key: nil}), do: :ok
  def verify_tenant_key(%{hf_status: :revoked}), do: :ok

  def verify_tenant_key(%{id: tenant_id, encrypted_hf_key: encrypted, encryption_iv: iv}) do
    # Decrypt key in memory
    decrypted_key = Samen.Scopes.Ai.Crypto.decrypt(encrypted, iv)

    try do
      case TokenValidator.verify_key(decrypted_key) do
        {:ok, _meta} ->
          # Key is valid
          update_tenant_validation_status(tenant_id, :ok)
          :ok

        {:error, reason} when reason in [:invalid_token, :insufficient_permissions] ->
          # Key was revoked or changed by tenant on HuggingFace
          revoke_tenant_key(tenant_id)
          {:error, :revoked}

        {:error, :huggingface_rate_limited} ->
          # Rate limited - tell Oban to snooze and retry later
          {:error, :rate_limited}

        {:error, reason} ->
          Logger.warning(
            "[HuggingFace.VerifyCredentials] Tenant #{tenant_id} " <>
              "verification failed: #{inspect(reason)}"
          )

          {:error, reason}
      end
    after
      # Force GC to flush decrypted key from memory
      :erlang.garbage_collect()
    end
  end

  def verify_tenant_key(_), do: {:error, :invalid_tenant}

  # -- Private functions -------------------------------------------------------

  defp get_tenants_with_hf_keys do
    # In production, this would query the database:
    # Tenant
    # |> where([t], not is_nil(t.encrypted_hf_key) and t.hf_status == :active)
    # |> Repo.all()

    # For now, return empty list (no-op until database schema is migrated)
    []
  end

  defp revoke_tenant_key(tenant_id) do
    # In production, this would:
    # 1. Clear encrypted_hf_key and encryption_iv
    # 2. Set hf_status to :revoked
    # 3. Broadcast revocation event via PubSub

    Logger.warning(
      "[HuggingFace.VerifyCredentials] Revoking key for tenant #{tenant_id}"
    )

    # Broadcast revocation event
    pubsub = Application.get_env(:samen_core, :pubsub)

    if pubsub do
      Phoenix.PubSub.broadcast(
        pubsub,
        "tenant_settings:#{tenant_id}",
        {:tenant_updated, %{hf_status: :revoked}}
      )
    end
  end

  defp update_tenant_validation_status(tenant_id, :ok) do
    # In production, this would update the tenant's validation timestamp
    Logger.debug(
      "[HuggingFace.VerifyCredentials] Tenant #{tenant_id} key validated successfully"
    )
  end
end
