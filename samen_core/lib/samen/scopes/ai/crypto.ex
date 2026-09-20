defmodule Samen.Scopes.Ai.Crypto do
  @moduledoc """
  AES-256-GCM encryption/decryption utility for HuggingFace API keys.

  Provides encrypt/decrypt functions using Erlang's native `:crypto` module.
  Keys are encrypted at rest with a unique IV per encryption operation.

  ## Security Model

  - **Encryption**: AES-256-GCM with 12-byte IV and 16-byte auth tag
  - **Key Storage**: Encrypted ciphertext + IV stored in database
  - **Decryption**: Only in-memory within short-lived processes
  - **Memory Safety**: Decrypted keys are GC'd when the process terminates

  ## Usage

      # Encrypt a key
      iv = :crypto.strong_rand_bytes(12)
      {:ok, ciphertext} = Samen.Scopes.Ai.Crypto.encrypt("hf_xxx", iv)

      # Decrypt a key
      plaintext = Samen.Scopes.Ai.Crypto.decrypt(ciphertext, iv)
  """

  @doc """
  Encrypts plaintext using AES-256-GCM.

  Returns `{:ok, ciphertext}` where ciphertext includes the 16-byte auth tag.

  ## Examples

      iv = :crypto.strong_rand_bytes(12)
      {:ok, ciphertext} = Samen.Scopes.Ai.Crypto.encrypt("secret_key", iv)
      is_binary(ciphertext)  # => true
  """
  @spec encrypt(binary(), binary()) :: {:ok, binary()} | {:error, term()}
  def encrypt(plaintext, iv) when is_binary(plaintext) and byte_size(iv) == 12 do
    key = master_key()

    try do
      {ciphertext, tag} =
        :crypto.crypto_one_time_aead(
          :aes_256_gcm,
          key,
          iv,
          plaintext,
          "",  # Additional authenticated data
          16,  # Tag length
          true  # Encrypt
        )

      {:ok, ciphertext <> tag}
    rescue
      e -> {:error, {:encryption_failed, e}}
    end
  end

  def encrypt(_, _), do: {:error, :invalid_args}

  @doc """
  Decrypts ciphertext using AES-256-GCM.

  The ciphertext must include the 16-byte auth tag appended at the end.

  ## Examples

      plaintext = Samen.Scopes.Ai.Crypto.decrypt(ciphertext, iv)
      plaintext == "secret_key"  # => true
  """
  @spec decrypt(binary(), binary()) :: binary()
  def decrypt(ciphertext, iv) when is_binary(ciphertext) and byte_size(iv) == 12 do
    key = master_key()
    cipher_tag_size = byte_size(ciphertext) - 16

    if cipher_tag_size < 0 do
      raise ArgumentError, "ciphertext too short (must include 16-byte auth tag)"
    end

    <<c_text::binary-size(^cipher_tag_size), tag::binary-size(16)>> = ciphertext

    case :crypto.crypto_one_time_aead(
           :aes_256_gcm,
           key,
           iv,
           c_text,
           "",  # Additional authenticated data
           tag,
           false  # Decrypt
         ) do
      plaintext when is_binary(plaintext) ->
        plaintext

      :error ->
        raise ArgumentError, "decryption failed (wrong IV or corrupted ciphertext)"
    end
  end

  def decrypt(_, _), do: raise(ArgumentError, "invalid ciphertext or IV")

  @doc """
  Generates a cryptographically secure 12-byte IV for AES-GCM.
  """
  @spec generate_iv() :: binary()
  def generate_iv, do: :crypto.strong_rand_bytes(12)

  @doc """
  Validates a HuggingFace API key format.

  Returns `true` if the key matches the expected `hf_` prefix pattern.
  """
  @spec valid_hf_key?(term()) :: boolean()
  def valid_hf_key?(key) when is_binary(key) do
    String.starts_with?(key, "hf_") and byte_size(key) >= 10
  end

  def valid_hf_key?(_), do: false

  # Master key from application config (must be 32 bytes for AES-256)
  # In production, this comes from KMS (AWS KMS / HashiCorp Vault)
  defp master_key do
    case Application.get_env(:samen_core, :kms_master_key) do
      key when is_binary(key) and byte_size(key) == 32 ->
        key

      _ ->
        # Development/test fallback: derive from a consistent source
        # WARNING: Never use this in production!
        :crypto.hash(:sha256, "samen-dev-kms-fallback-key-do-not-use-in-prod")
    end
  end
end
