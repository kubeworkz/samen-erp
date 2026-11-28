defmodule Samen.Web.Settings.HuggingFaceLiveTest do
  @moduledoc """
  `/settings/huggingface` BYOK end-to-end proof: the LiveView validates the
  raw key against HuggingFace, encrypts + persists it, reloads it, and revokes
  both on an explicit click and on a 401 from a re-validation.
  """

  use Samen.WebTest.DataCase, async: false

  alias Samen.Scopes.Ai.{ApiKey, Crypto}
  alias Samen.Web.Mount
  alias Samen.Web.Settings.HuggingFaceLive

  @raw_key "hf_live_valid_key_12345"

  defmodule ValidAdapter do
    @behaviour Samen.Scopes.Ai.HttpAdapter

    @impl true
    def get(_url, _headers, _opts), do: {:ok, 200, %{"name" => "tester"}}

    @impl true
    def post(_url, _headers, _body, _opts), do: {:ok, 200, %{}}

    @impl true
    def stream_post(_url, _headers, _body, _opts, _acc, _on_chunk), do: {:error, :not_implemented}
  end

  defmodule RevokedAdapter do
    @behaviour Samen.Scopes.Ai.HttpAdapter

    @impl true
    def get(_url, _headers, _opts), do: {:ok, 401, %{}}

    @impl true
    def post(_url, _headers, _body, _opts), do: {:ok, 401, %{}}

    @impl true
    def stream_post(_url, _headers, _body, _opts, _acc, _on_chunk), do: {:error, :not_implemented}
  end

  setup do
    pubsub = :"hf_live_pubsub_#{System.unique_integer([:positive])}"
    start_supervised!({Phoenix.PubSub, name: pubsub})
    Application.put_env(:samen_core, :pubsub, pubsub)
    Application.put_env(:samen_core, :hf_http_adapter, ValidAdapter)

    on_exit(fn ->
      Application.delete_env(:samen_core, :pubsub)
      Application.delete_env(:samen_core, :hf_http_adapter)
    end)

    org = Ash.UUID.generate()

    mount =
      Mount.new(:settings, Samen.WebTest.Operator, Samen.WebTest.Repo,
        plane: Samen.Web.Plane.tenant(),
        labels: %{pubsub: pubsub}
      )

    session = %{"samen_mount" => Mount.to_session(mount)}
    {:ok, socket} = HuggingFaceLive.mount(%{"org" => org}, session, %Phoenix.LiveView.Socket{})

    {:ok, socket: socket, org: org, pubsub: pubsub}
  end

  test "connect validates, encrypts, persists, and reloads the key", %{socket: socket, org: org} do
    assert {:noreply, socket} =
             HuggingFaceLive.handle_event(
               "connect",
               %{"api_key" => %{"raw_key" => @raw_key}},
               socket
             )

    assert socket.assigns.connect_success =~ "validated and encrypted"

    assert [key] = Ash.read!(ApiKey, authorize?: false)
    assert key.tenant_id == org
    assert stored_org_id(key.id) == org
    assert key.status == :active
    assert key.key_prefix == "hf_live_"
    assert Crypto.decrypt(key.encrypted_key, key.encryption_iv) == @raw_key

    # The reload path is what the table renders: the persisted row, not a shell.
    assert Enum.any?(socket.assigns.api_keys, &(&1.id == key.id))
  end

  test "revoke clears the persisted secret and broadcasts", %{
    socket: socket,
    org: org,
    pubsub: pubsub
  } do
    {:noreply, socket} =
      HuggingFaceLive.handle_event("connect", %{"api_key" => %{"raw_key" => @raw_key}}, socket)

    assert [key] = Ash.read!(ApiKey, authorize?: false)
    Phoenix.PubSub.subscribe(pubsub, "tenant_settings:#{org}")

    assert {:noreply, socket} =
             HuggingFaceLive.handle_event("revoke", %{"id" => key.id}, socket)

    assert socket.assigns.connect_success =~ "revoked"
    assert_receive {:tenant_updated, %{hf_status: :revoked}}

    revoked = Ash.get!(ApiKey, key.id, authorize?: false)
    assert revoked.status == :revoked
    assert is_nil(revoked.encrypted_key)
    assert is_nil(revoked.encryption_iv)
  end

  test "re-validation of a rejected key revokes it and broadcasts", %{
    socket: socket,
    org: org,
    pubsub: pubsub
  } do
    {:noreply, socket} =
      HuggingFaceLive.handle_event("connect", %{"api_key" => %{"raw_key" => @raw_key}}, socket)

    assert [key] = Ash.read!(ApiKey, authorize?: false)
    Phoenix.PubSub.subscribe(pubsub, "tenant_settings:#{org}")
    Application.put_env(:samen_core, :hf_http_adapter, RevokedAdapter)

    assert {:noreply, socket} =
             HuggingFaceLive.handle_event("validate_key", %{"id" => key.id}, socket)

    assert socket.assigns.connect_error =~ "revoked"
    assert_receive {:tenant_updated, %{hf_status: :revoked}}

    revoked = Ash.get!(ApiKey, key.id, authorize?: false)
    assert revoked.status == :revoked
    assert is_nil(revoked.encrypted_key)
  end

  defp stored_org_id(id) do
    %{rows: [[org]]} =
      Repo.query!("SELECT aik_org_id::text FROM aik_api_key WHERE aik_id = $1", [
        Ecto.UUID.dump!(id)
      ])

    org
  end
end
