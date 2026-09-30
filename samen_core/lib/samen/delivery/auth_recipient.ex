defmodule Samen.Delivery.AuthRecipient do
  @moduledoc """
  Resolves auth-email recipients (credential_id → plaintext email) for the
  delivery chokepoint's `resolve_recipient` callback.

  For auth emails, the recipient is identified by `credential_id`. This module
  resolves it to a plaintext email by looking up the credential's associated
  user and revealing the vaulted email address.
  """

  alias Samen.Masked
  require Logger

  @doc """
  Build a `resolve_recipient` function suitable for wiring into an ESP
  adapter's config.

  Returns a function `fn message -> {:ok, email} | {:error, reason}`.

  Options:

    * `:credential_mod` (required) — the host's credential resource
    * `:user_mod` (required) — the host's user resource
    * `:repo` (required) — the host's Ecto repo MODULE. In a release,
      `Application.get_env(app, Repo)` yields the repo's config, not the
      module, so this cannot be inferred reliably.
  """
  @spec resolver(keyword()) :: (map() -> {:ok, String.t()} | {:error, term()})
  def resolver(opts) do
    credential_mod = Keyword.fetch!(opts, :credential_mod)
    user_mod = Keyword.fetch!(opts, :user_mod)
    repo = Keyword.fetch!(opts, :repo)

    fn message ->
      resolve(message, credential_mod, user_mod, repo)
    end
  end

  defp resolve(%{to_subscriber_id: credential_id}, credential_mod, user_mod, repo)
       when is_binary(credential_id) do
    with {:ok, _credential} <- Ash.get(credential_mod, credential_id, authorize?: false),
         {:ok, user} <- find_user(user_mod, credential_id),
         {:ok, email} <- extract_primary_email(user, repo) do
      {:ok, email}
    else
      {:error, reason} = err ->
        Logger.warning("[AuthRecipient] failed to resolve #{credential_id}: #{inspect(reason)}")
        err
    end
  end

  defp resolve(_message, _credential_mod, _user_mod, _repo) do
    {:error, :missing_subscriber_id}
  end

  defp find_user(user_mod, credential_id) do
    require Ash.Query

    user_mod
    |> Ash.Query.filter(credential_id == ^credential_id)
    |> Ash.Query.limit(1)
    # The vaulted emails attribute is NOT loaded by default — reading it
    # without an explicit load hands extract_primary_email an %Ash.NotLoaded{}
    # and Enum crashes on it (prod, 2026-09-30).
    |> Ash.Query.load(:emails)
    # authz-scope: pre-auth credential_id→user unique-key lookup for auth-email
    # delivery — the org is unknown until the user resolves, cannot be pinned;
    # unique credential_id + limit(1) bounds it to one row.
    |> Ash.read!(authorize?: false)
    |> case do
      [user] -> {:ok, user}
      [] -> {:error, :user_not_found}
    end
  end

  # Extract the primary email from the user's vaulted `emails` field.
  # In prod the loaded attribute is a SINGLE %Masked{} token (the primary
  # address); dev/test fixtures may carry the legacy list of %{label, address}
  # maps. Never assume Enumerable — Enum over the bare struct crashed the
  # first configured prod send (Protocol.UndefinedError, 2026-09-30).
  defp extract_primary_email(user, repo) do
    case Map.get(user, :emails) do
      %Masked{token: token} when is_binary(token) ->
        reveal_from_vault(token, repo)

      emails when is_list(emails) ->
        case Enum.find(emails, fn e -> Map.get(e, :label) == "primary" end) do
          %{address: %Masked{token: token}} when is_binary(token) ->
            reveal_from_vault(token, repo)

          %{address: %{token: token}} when is_binary(token) ->
            reveal_from_vault(token, repo)

          %{address: email} when is_binary(email) ->
            {:ok, email}

          _ ->
            {:error, :no_primary_email}
        end

      _ ->
        {:error, :no_primary_email}
    end
  end

  defp reveal_from_vault(token, repo) do
    if is_nil(repo) do
      {:error, :no_repo_configured}
    else
      # Use the Vault to reveal — the system has implicit authority for
      # auth-lifecycle sends (ADR-035 §5 A2).
      masked = %Samen.Masked{token: token, label: :email}

      case Samen.Vault.reveal(masked, repo) do
        {:ok, email} when is_binary(email) -> {:ok, email}
        {:error, reason} -> {:error, {:vault_reveal_failed, reason}}
        _ -> {:error, :vault_reveal_failed}
      end
    end
  rescue
    e ->
      Logger.warning("[AuthRecipient] vault reveal error: #{inspect(e)}")
      {:error, :vault_reveal_error}
  end
end
