defmodule Samen.AI.VerifyCredentialsWorkerTest do
  @moduledoc """
  BYOK end-to-end proof for `Samen.Scopes.Ai.VerifyCredentialsWorker`:

    * an `aik_api_key` row is a real persisted row (the settings surface's create
      path), not a simulated tenant map;
    * a 401 from HuggingFace revokes + clears it; and
    * the revocation is broadcast on the tenant settings topic the LiveView
      subscribes to.
  """

  use ExUnit.Case, async: false

  alias Samen.Scopes.Ai.{ApiKey, Crypto, VerifyCredentialsWorker}
  alias SamenCore.TestRepo

  @raw_key "hf_worker_valid_key_12345"

  defmodule InvalidAdapter do
    @behaviour Samen.Scopes.Ai.HttpAdapter

    @impl true
    def get(_url, _headers, _opts), do: {:ok, 401, %{}}

    @impl true
    def post(_url, _headers, _body, _opts), do: {:ok, 401, %{}}

    @impl true
    def stream_post(_url, _headers, _body, _opts, _acc, _on_chunk), do: {:error, :not_implemented}
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo)
    Ecto.Adapters.SQL.Sandbox.mode(TestRepo, {:shared, self()})

    pubsub = :"hf_worker_pubsub_#{System.unique_integer([:positive])}"
    start_supervised!({Phoenix.PubSub, name: pubsub})
    Application.put_env(:samen_core, :pubsub, pubsub)
    Application.put_env(:samen_core, :hf_http_adapter, InvalidAdapter)

    on_exit(fn ->
      Application.delete_env(:samen_core, :pubsub)
      Application.delete_env(:samen_core, :hf_http_adapter)
    end)

    {:ok, pubsub: pubsub}
  end

  test "sweeps an active key, revokes it on 401, clears the secret, and broadcasts", %{
    pubsub: pubsub
  } do
    org = Ash.UUID.generate()
    iv = Crypto.generate_iv()
    {:ok, ciphertext} = Crypto.encrypt(@raw_key, iv)

    created =
      ApiKey
      |> Ash.Changeset.for_create(:create, %{
        tenant_id: org,
        name: "HuggingFace Key",
        encrypted_key: ciphertext,
        encryption_iv: iv,
        key_prefix: "hf_worke",
        status: :active
      })
      |> Ash.create!(authorize?: false)

    # The resource's injected `org_id` is derived from the tenant id the settings
    # surface actually has, so the row is usable without a second identifier.
    assert stored_org_id(created.id) == org

    Phoenix.PubSub.subscribe(pubsub, "tenant_settings:#{org}")

    assert {:ok, %{checked: 1, revoked: 1, errors: 0}} =
             VerifyCredentialsWorker.sweep_tenant_keys()

    assert_receive {:tenant_updated, %{hf_status: :revoked}}

    revoked = Ash.get!(ApiKey, created.id, authorize?: false)
    assert revoked.status == :revoked
    assert is_nil(revoked.encrypted_key)
    assert is_nil(revoked.encryption_iv)
  end

  defp stored_org_id(id) do
    %{rows: [[org]]} =
      TestRepo.query!("SELECT aik_org_id::text FROM aik_api_key WHERE aik_id = $1", [
        Ecto.UUID.dump!(id)
      ])

    org
  end
end
