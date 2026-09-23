Tenants are **bringing their own Hugging Face API keys**, your application acts as an agent executing AI tasks on their behalf using their infrastructure and quota. This drastically reduces your operational costs and shifts liability, but it requires highly secure credential management and robust validation.

Here is the architectural blueprint for an "OAuth/BYO-Key" integration:

### 1. Secure Credential Storage & Lifecycle

Never expose tenant API keys to the frontend, and encrypt them heavily at rest.

- **Encryption:** Store keys in your database using **AES-256-GCM** encryption. Use a unique data encryption key (DEK) per tenant, backed by a master key from a Key Management Service (KMS) like AWS KMS or HashiCorp Vault.
- **Key Validation:** When a tenant inputs their **User Access Token**, immediately validate it via a lightweight API call before saving it.

---

### 2. Request Routing Architecture

Your backend must act as an isolated proxy. When a tenant initiates an AI workflow, your server decrypts *only* that tenant's key in memory, executes the request, and flushes the key.

```plaintext
[Tenant UI] 
   │ (Sends request with JWT/Session)
   ▼
[Your Application Backend]
   │ 1. Fetch encrypted key for tenant_id
   │ 2. Decrypt key via KMS
   │ 3. Forward request to Hugging Face
   ▼
[Hugging Face API / Endpoints] (Billed directly to Tenant's HF Account)
```

---

### 3. Handling Permissions & Resources

Because the token belongs to the tenant, your application's capabilities will depend on what that token can access.

- **Tenant-Owned Models:** If tenants want to use private models hosted on their own Hugging Face accounts, their token must have `read` access to their specific organization or user space.
- **Namespace Isolation:** When your app creates or fetches assets (like spaces, repos, or datasets) via their token, strictly prefix or namespace them (e.g., `tenant-space/appname-dataset`) so your app doesn't accidentally interfere with their other personal Hugging Face projects.

---

### 4. Error Handling & Edge Cases

With BYO keys, tenant-side configuration changes will cause app failures. You must catch these elegantly:

- **Token Revocation:** If a tenant deletes their key on Hugging Face, your app will receive a `401 Unauthorized`. Intercept this error, flag their account as "Setup Required", and prompt them to provide a new key.
- **Tenant Quota Exhaustion:** If the tenant runs out of Hugging Face billing credits, the API will throw a `429 Too Many Requests` or a billing error. Your UI must display an error explaining that *their* Hugging Face account has hit its limit, ensuring they don't blame your platform.

---

In an **Elixir/Erlang (BEAM)** ecosystem, a Bring-Your-Own-Key (BYO-Key) architecture is highly efficient. You can leverage **Erlang's crypto module**, lightweight **GenStages/Tasks**, and connection pooling to build a highly parallel, isolated proxy for your tenants' Hugging Face requests.

---

### 1. Key Storage & Decryption in Elixir

To ensure isolation, keys should be stored encrypted in your database (e.g., PostgreSQL via Ecto) and decrypted **only in memory** within the short-lived process executing the request.

#### Database Schema Example

Use binary fields to store the initialization vector (IV) and the ciphertext.

```plaintext
defmodule MyApp.Tenants.Tenant do
  use Ecto.Schema

  schema "tenants" do
    field :name, :string
    field :encrypted_hf_key, :binary
    field :encryption_iv, :binary
    # ... other tenant fields
  end
end
```

#### Secure Decryption Utility

Use Erlang’s native `:crypto` application for low-overhead **AES-256-GCM** decryption:

---

### 2. Client Client Integration (HTTPPoison / Finch)

When calling Hugging Face Serverless APIs, use **Finch** or **Req** for HTTP client management. They utilize Erlang's `:hackney` or `:poolboy` concepts underneath to manage connection pools dynamically.

> **Implementation note (INV-4):** the shipped kernel cannot depend on a vendor
> HTTP client — `samen_core/mix.exs` is gate-checked against `:req`/`:finch`/
> `:hackney`/`:httpoison`/`:tesla`. The actual transport is the
> `Samen.Scopes.Ai.HttpAdapter` seam (behaviour + OTP `:httpc` default + a
> `config :samen_core, :hf_http_adapter, ...` override), which a host may
> implement with Finch/Req outside the kernel. The examples below show the
> original Req shape for reference; the seam preserves the same status mapping.

Here is how to structure a secure, tenant-isolated inference call:

```plaintext
defmodule MyApp.HuggingFace.Client do
  @base_url "https://huggingface.co"

  @doc """
  Executes text generation using the tenant's decrypted API key.
  """
  def generate_text(model_id, prompt, decrypted_key) do
    url = "#{@base_url}/#{model_id}"
    
    headers = [
      {"Authorization", "Bearer #{decrypted_key}"},
      {"Content-Type", "application/json"}
    ]

    body = Jason.encode!(%{
      inputs: prompt,
      parameters: %{max_new_tokens: 250, temperature: 0.7}
    })

    # Using Req (highly recommended modern HTTP client for Elixir)
    case Req.post(url, headers: headers, body: body, retry: false) do
      {:ok, %Req.Response{status: 200, body: response_body}} ->
        {:ok, response_body}

      {:ok, %Req.Response{status: 401}} ->
        {:error, :invalid_tenant_key}

      {:ok, %Req.Response{status: 429}} ->
        {:error, :tenant_quota_exhausted}

      {:ok, %Req.Response{status: status, body: error_body}} ->
        {:error, {:hf_api_error, status, error_body}}

      {:error, reason} ->
        {:error, {:network_failure, reason}}
    end
  end
end

```

---

### 3. Concurrency and Multi-Tenant Isolation

The BEAM is perfect for this architecture because a failure in one tenant's request will never impact another.

- **Isolate via Elixir Tasks:** Always run inference calls inside an isolated process using `Task.Supervisor`. If a tenant provides a malformed key or Hugging Face times out, only that specific process dies.
- **Avoid GenServers for Keys:** Do **not** spin up a persistent `GenServer` per tenant just to hold their decrypted Hugging Face key in state. Keeping decrypted keys in long-lived state increases your memory footprint and creates an unnecessary security surface area. Decrypt on-demand and let the GC flush it when the `Task` finishes.

```plaintext
# In your application controller or context:
def handle_tenant_request(tenant, model_id, prompt) do
  Task.Supervisor.async_nolink(MyApp.TaskSupervisor, fn ->
    decrypted_key = MyApp.Security.Crypto.decrypt(tenant.encrypted_hf_key, tenant.encryption_iv)
    MyApp.HuggingFace.Client.generate_text(model_id, prompt, decrypted_key)
  end)
  |> Task.await(:timer.seconds(30)) # Protect against total upstream hangs
end

```

---

### 4. BEAM-Specific Edge Cases to Watch

- **Binary Leakage:** In Erlang/Elixir, binaries larger than 64 bytes (like HF keys) are allocated on a shared global heap, and reference counts are kept. To ensure a tenant's decrypted key is aggressively wiped from memory right after the API call, invoke `:erlang.garbage_collect/0` or let the short-lived `Task` process terminate immediately.
- **Token Validation Pipeline:** When a user saves their key, use a simple `Req.get("https://huggingface.co", headers: ...)` check inside a backend validation pipeline to flag invalid keys immediately before saving them to Ecto.

---

Here is the implementation guide for securing your tenants' keys using **Ecto Changesets** and handling Hugging Face’s **Server-Sent Events (SSE) streaming** asynchronously in Elixir.

---

### Part 1: Secure Ecto Changeset Pipeline

To prevent unencrypted keys from ever touching your database logs or storage accidentally, we handle encryption directly inside the `Ecto.Changeset` pipeline using `Cloak` patterns or raw `:crypto`.

This ensures that whenever a tenant inputs a raw API key, it is encrypted immediately, and the raw text is dropped from the changeset parameters.

```plaintext
defmodule MyApp.Tenants.Tenant do
  use Ecto.Schema
  import Ecto.Changeset
  alias MyApp.Security.Crypto

  schema "tenants" do
    field :name, :string
    field :encrypted_hf_key, :binary
    field :encryption_iv, :binary

    # Virtual field used for form/API ingestion only (never persisted)
    field :raw_hf_key, :string, virtual: true 
  end

  def changeset(tenant, attrs) do
    tenant
    |> cast(attrs, [:name, :raw_hf_key])
    |> validate_required([:name])
    |> encrypt_hf_key()
  end

  defp encrypt_hf_key(%Ecto.Changeset{valid?: true, changes: %{raw_hf_key: raw_key}} = changeset) do
    # Generate a cryptographically secure random 12-byte IV for AES-GCM
    iv = :crypto.strong_rand_bytes(12)
    
    case Crypto.encrypt(raw_key, iv) do
      {:ok, ciphertext} ->
        changeset
        |> put_change(:encrypted_hf_key, ciphertext)
        |> put_change(:encryption_iv, iv)
        |> delete_change(:raw_hf_key) # Clean up virtual field data from memory
      _ ->
        add_error(changeset, :raw_hf_key, "Encryption failed")
    end
  end

  defp encrypt_hf_key(changeset), do: changeset
end

```

And update your `Crypto` utility to include the companion encryption function matching your decryption code:

```plaintext
defmodule MyApp.Security.Crypto do
  @secret_key Application.compile_env!(:my_app, :kms_master_key) # Must be exactly 32 bytes

  def encrypt(plaintext, iv) do
    # AES-GCM requires 16-byte authentication tags
    {ciphertext, tag} = :crypto.crypto_one_time_aead(:aes_256_gcm, @secret_key, iv, plaintext, "", 16, true)
    {:ok, ciphertext <> tag}
  end

  def decrypt(ciphertext, iv) do
    cipher_tag_size = byte_size(ciphertext) - 16
    <<c_text::binary-size(cipher_tag_size), tag::binary-size(16)>> = ciphertext
    :crypto.crypto_one_time_aead(:aes_256_gcm, @secret_key, iv, c_text, "", tag, false)
  end
end

```

---

### Part 2: Streaming LLM Responses (Server-Sent Events) via Req

Hugging Face Inference endpoints support streaming via Server-Sent Events (SSE) when you pass `stream: true` in the request parameters.

Because you are using Elixir, you can stream these chunks over an established connection directly to a calling process (like a **Phoenix Channel**, a **LiveView**, or an API client gateway) using `Req`. `Req` abstracts away complex network buffers elegantly while isolating network resources per process.

```plaintext
defmodule MyApp.HuggingFace.Streamer do
  @base_url "https://huggingface.co"

  @doc """
  Streams a text generation model response back to a target Elixir process chunk-by-chunk.
  """
  def stream_generation(model_id, prompt, decrypted_key, target_pid) do
    url = "#{@base_url}/#{model_id}"
    
    headers = [
      {"Authorization", "Bearer #{decrypted_key}"},
      {"Content-Type", "application/json"}
    ]

    body = Jason.encode!(%{
      inputs: prompt,
      parameters: %{max_new_tokens: 500, temperature: 0.7},
      stream: true # Tells HuggingFace to return text/event-stream
    })

    # Execute the request asynchronously, piping bytes into an anonymous handler function
    Req.post(url, headers: headers, body: body, retry: false, into: fn {:data, chunk}, context ->
      parse_and_forward_chunk(chunk, target_pid)
      {:cont, context}
    end)
  end

  # Server-Sent Events arrive looking like: "data: {"token": {"text": "hello"}}\n\n"
  defp parse_and_forward_chunk(chunk, target_pid) do
    chunk
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.each(fn
      "data:" <> json_str -> 
        send_json_token(json_str, target_pid)
      _ -> 
        :skip # Ignores keep-alive pulses or blank spacing lines
    end)
  end

  defp send_json_token(json_str, target_pid) do
    case Jason.decode(String.trim(json_str)) do
      {:ok, %{"token" => %{"text" => text}, "generated_text" => nil}} ->
        # Send partial piece back to your LiveView/Channel
        send(target_pid, {:hf_stream_chunk, text})

      {:ok, %{"generated_text" => full_text}} ->
        # Final stream chunk contains the complete assembled text string
        send(target_pid, {:hf_stream_done, full_text})

      {:error, _} ->
        :invalid_json
    end
  end
end

```

---

### 3. Orchestrating it in a LiveView or Controller

To process this concurrently without blocking system memory or crashing your primary state, run the streaming module inside a transient BEAM task.

```plaintext
# Inside your LiveView, Phoenix Channel, or Context layer:
def handle_user_prompt(tenant, model_id, prompt) do
  # 1. Grab the client process ID to stream back to
  caller_pid = self()

  # 2. De-reference and decrypt the key exactly where it's needed
  decrypted_key = MyApp.Security.Crypto.decrypt(tenant.encrypted_hf_key, tenant.encryption_iv)

  # 3. Spin up an unlinked supervised Task 
  Task.Supervisor.start_child(MyApp.TaskSupervisor, fn ->
    MyApp.HuggingFace.Streamer.stream_generation(model_id, prompt, decrypted_key, caller_pid)
    
    # Force Garbage Collection on the binary memory space of this transient process
    # immediately before it terminates, eradicating the decrypted key from the heap
    :erlang.garbage_collect()
  end)
end

# 4. Handle incoming streamed events asynchronously in your consumer UI/Channel
def handle_info({:hf_stream_chunk, text}, socket) do
  # Append incoming chunks seamlessly to your UI state
  {:noreply, assign(socket, :completion_text, socket.assigns.completion_text <> text)}
end

def handle_info({:hf_stream_done, _final_text}, socket) do
  {:noreply, assign(socket, :streaming_loading, false)}
end

```

---

Here is how to implement the final two layers of your architecture: configuring a dedicated **Supervisor tree** to manage your tenant tasks safely, and setting up an **API validation context** to verify tokens against Hugging Face before committing them to the database.

---

### Part 1: Configuring the Supervisor Tree

To ensure a failure in one tenant's stream (like a network timeout or bad API key) cannot cascade and crash other tenants or your web app, isolate them under a dedicated **DynamicSupervisor** or a **Task.Supervisor**.

Add these to your primary application supervisor tree (typically found in `lib/my_app/application.ex`):

```plaintext
defmodule MyApp.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # 1. Start your Ecto Database connection pool
      MyApp.Repo,
      
      # 2. Start the Phoenix endpoint
      MyAppWeb.Endpoint,

      # 3. Dedicated Task Supervisor for running tenant Hugging Face API calls
      # This provides a clean namespace and isolates transient streaming tasks
      {Task.Supervisor, name: MyApp.HuggingFaceTaskSupervisor}
    ]

    opts = [strategy: :one_for_one, name: MyApp.Supervisor]
    Supervisor.start_link(children, opts)
  end
end

```

---

### Part 2: Upstream Token Validation and Error Handling

When a tenant submits an API token, you shouldn't just encrypt it blindly. You want to validate that the token is real, active, and contains the proper scopes. Hugging Face provides a `whoami` endpoint exactly for this purpose.

Create an orchestration module (like a context layer) that acts as the entry point for linking keys:

```plaintext
defmodule MyApp.Tenants do
  alias MyApp.Repo
  alias MyApp.Tenants.Tenant

  @hf_whoami_url "https://huggingface.co"

  @doc """
  Validates a tenant's raw Hugging Face key against their API,
  and saves it to the database if it is valid.
  """
  def link_huggingface_key(tenant, %{"raw_hf_key" => raw_key} = attrs) do
    case verify_key_with_huggingface(raw_key) do
      {:ok, _hf_meta} ->
        # Token is good, pass it to the changeset for encryption and storage
        tenant
        |> Tenant.changeset(attrs)
        |> Repo.update()

      {:error, reason} ->
        # Return a structured error to display cleanly on your frontend
        {:error, reason}
    end
  end

  # Makes a synchronous validation call to Hugging Face
  defp verify_key_with_huggingface(raw_key) do
    headers = [{"Authorization", "Bearer #{raw_key}"}]

    # Short timeout since this is an inline user web request
    case Req.get(@hf_whoami_url, headers: headers, receive_timeout: 5000) do
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

      {:error, %LintError{reason: :timeout}} ->
        {:error, :timeout}

      {:error, _reason} ->
        {:error, :network_failure}
    end
  end
end

```

---

### Part 3: Connecting Validation to your Web Interface

When a user fills out a settings form to link their key, you can map the structured atom errors directly back onto your user interface (like a **Phoenix LiveView** or a JSON API controller).

**LiveView Example**

```plaintext
defmodule MyAppWeb.TenantSettingsLive do
  use MyAppWeb, :live_view
  alias MyApp.Tenants

  def handle_event("save_hf_key", %{"tenant" => tenant_params}, socket) do
    tenant = socket.assigns.current_tenant

    case Tenants.link_huggingface_key(tenant, tenant_params) do
      {:ok, updated_tenant} ->
        {:noreply, 
         socket 
         |> put_flash(:info, "Hugging Face key validated and encrypted successfully!")
         |> assign(:current_tenant, updated_tenant)}

      {:error, :invalid_token} ->
        {:noreply, put_flash(socket, :error, "The API key provided was rejected by Hugging Face (401 Unauthorized).")}

      {:error, :insufficient_permissions} ->
        {:noreply, put_flash(socket, :error, "This token does not have the required scopes. Please generate a token with Read/Write permissions.")}

      {:error, :network_failure} ->
        {:noreply, put_flash(socket, :error, "Could not reach Hugging Face servers. Please try again later.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        # Handle standard database validation failures
        {:noreply, assign(socket, :changeset, changeset)}
    end
  end
end

```

---

Using **Oban** is the gold standard for this on the BEAM. Unlike cron-like tools (like Quantum), Oban persists jobs to your database (PostgreSQL). If your server crashes or restarts mid-sweep, Oban ensures jobs resume exactly where they left off and provides native rate-limiting so you don't accidentally DOS Hugging Face with concurrent validation checks.

Here is the complete implementation for an automated Oban sweeping pipeline.

---

### Part 1: Define the Oban Worker

This worker handles a single tenant at a time. If a tenant's token returns a `401` or `403`, we flag the tenant in the database and clear their encrypted credentials so your system safely knows they require setup.

```plaintext
defmodule MyApp.Workers.VerifyTenantHFCredentials do
  use Oban.Worker, queue: :background, max_attempts: 3
  
  alias MyApp.Repo
  alias MyApp.Tenants.Tenant
  alias MyApp.Tenants

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"tenant_id" => tenant_id}}) do
    case Repo.get(Tenant, tenant_id) do
      nil -> 
        :ok # Tenant was deleted in the meantime

      tenant ->
        # If they don't even have a key set up, skip it
        if is_nil(tenant.encrypted_hf_key) do
          :ok
        else
          verify_and_update_tenant(tenant)
        end
    end
  end

  defp verify_and_update_tenant(tenant) do
    # 1. Decrypt the key inside our transient Oban process
    decrypted_key = MyApp.Security.Crypto.decrypt(tenant.encrypted_hf_key, tenant.encryption_iv)

    # 2. Check upstream with Hugging Face (using the same function from the context layer)
    case Tenants.verify_key_with_huggingface(decrypted_key) do
      {:ok, _meta} ->
        # Key is still valid!
        :ok

      {:error, reason} when reason in [:invalid_token, :insufficient_permissions] ->
        # The key was revoked or changed by the tenant on HuggingFace.
        # Mark their account as inactive/unverified and safely null out the dead key.
        tenant
        | Ecto.Changeset.change(%{
            encrypted_hf_key: nil,
            encryption_iv: nil,
            hf_status: "revoked" # Assuming you add a status tracking field
          })
        | Repo.update!()

        # You could broadcast a Phoenix PubSub message here to notify their active UI session
        :ok

      {:error, :huggingface_rate_limited} ->
        # Tell Oban to snooze and retry later so we don't count this as a hard failure
        {:snooze, 60}

      {:error, _network_or_timeout} ->
        # Network blips happen. Return an error tuple so Oban automatically retries
        # based on its exponential backoff logic.
        {:error, :upstream_temporary_failure}
    end
  end
end

```

---

### Part 2: Build the Periodic Sweeper (Cron Job)

Next, create a coordinator worker that fires periodically (e.g., every night at midnight). It queries your database for all tenants who have an active Hugging Face key and queues an individual Oban worker for each one.

---

### Part 3: Configure Oban in `config.exs`

To hook up the cron scheduling, add `Oban.Plugins.Cron` to your configuration settings.

```plaintext
config :my_app, Oban,
  engine: Oban.Engines.Basic,
  repo: MyApp.Repo,
  queues: [background: 10], # Max 10 concurrent background tasks globally
  plugins: [
    {Oban.Plugins.Cron,
     crontab: [
       # Runs the full sweep once every day at midnight
       {"0 0 * * *", MyApp.Workers.DailyHFSweeper}
     ]}
  ]

```

---

### Part 4: Safety & Optimization Measures

- **Memory Management (Binary Heap Flash):** Because `VerifyTenantHFCredentials` pulls the key into its private heap to decrypt it, ensure that once `perform/1` returns, the BEAM destroys the process context entirely. Oban handles this naturally: worker processes are short-lived transient structures that are torn down instantly after execution, completely purging the tenant’s decrypted key data from memory.
- **Rate-Throttling:** By configuring your queue concurrency limits (`queues: [background: 10]`), you guarantee your application will never hammer Hugging Face's global endpoints with hundreds of requests at the exact same millisecond, avoiding massive cluster blocklists or `429` errors.

---

Here is how to implement unit testing using **Mox** to simulate Hugging Face API behaviors safely without hitting the live internet, followed by the **Phoenix LiveView** code to handle the real-time UI states when keys are revoked.

---

### Part 1: Testing the Integration with Mox

To test your background workers and client pipelines without using real keys or hitting Hugging Face limits, use **Mox** to mock the HTTP responses.

**1. Define the Client Behaviour**

Create a contract for any module interacting with the Hugging Face API:

```plaintext
# lib/my_app/hugging_face/api_behaviour.ex
defmodule MyApp.HuggingFace.APIBehaviour do
  @callback verify_key(String.t()) :: {:ok, map()} | {:error, atom() | {atom(), integer()}}
end

```

**2. Update Your Implementation & Configs**

Modify your core code to call a configured module rather than hardcoding `Req` directly:

```plaintext
# lib/my_app/tenants.ex
defmodule MyApp.Tenants do
  @hf_api Application.compile_env!(:my_app, :hf_api_client)

  def verify_key_with_huggingface(raw_key) do
    @hf_api.verify_key(raw_key)
  end
end

```

Now, map the implementations in your environment configurations:

```plaintext
# config/config.exs (Production / Default)
config :my_app, :hf_api_client, MyApp.HuggingFace.HTTPClient

# config/test.exs (Test environment)
config :my_app, :hf_api_client, MyApp.HuggingFace.APIMock

```

Define the mock inside your `test/test_helper.exs`:

```plaintext
Mox.defmock(MyApp.HuggingFace.APIMock, for: MyApp.HuggingFace.APIBehaviour)

```

**3. Write the Oban Worker Test**

Now you can mock network failures, revoked tokens, or successes to verify that your Oban worker reacts exactly as planned.

```plaintext
# test/workers/verify_tenant_hf_credentials_test.exs
defmodule MyApp.Workers.VerifyTenantHFCredentialsTest do
  use MyApp.DataCase, async: true
  import Mox

  alias MyApp.Workers.VerifyTenantHFCredentials
  alias MyApp.Tenants.Tenant

  setup :verify_on_exit!

  test "successfully marks tenant as revoked if Hugging Face returns 401" do
    # 1. Create a dummy tenant with an encrypted key
    iv = :crypto.strong_rand_bytes(12)
    {:ok, encrypted} = MyApp.Security.Crypto.encrypt("hf_dead_token", iv)
    
    tenant = Repo.insert!(%Tenant{
      name: "Acme Corp",
      encrypted_hf_key: encrypted,
      encryption_iv: iv,
      hf_status: "active"
    })

    # 2. Mock the behavior of the API for this test process
    MyApp.HuggingFace.APIMock
    |> expect(:verify_key, fn "hf_dead_token" -> {:error, :invalid_token} end)

    # 3. Execute the Oban worker synchronously
    assert :ok = Oban.Testing.perform_job(VerifyTenantHFCredentials, %{"tenant_id" => tenant.id})

    # 4. Assert that the database updated correctly
    updated_tenant = Repo.get!(Tenant, tenant.id)
    assert is_nil(updated_tenant.encrypted_hf_key)
    assert updated_tenant.hf_status == "revoked"
  end
end

```

---

### Part 2: Frontend UI Feedback States (Phoenix LiveView)

When an Oban job flags a tenant's key as `"revoked"`, you need to instantly inform any users logged into that tenant's dashboard. We do this by broadcasting an event over **Phoenix PubSub** from the worker and catching it live in the interface.

**1. Broadcast the Event from the Worker**

Update the revocation match arm inside your Oban worker (`VerifyTenantHFCredentials`) to broadcast the status change:

```plaintext
# Inside your worker logic when a token is found to be invalid:
tenant
|> Ecto.Changeset.change(%{encrypted_hf_key: nil, encryption_iv: nil, hf_status: "revoked"})
|> Repo.update!()

# Broadcast to all web nodes that this tenant space has changed status
Phoenix.PubSub.broadcast(
  MyApp.PubSub,
  "tenant_settings:#{tenant.id}",
  {:tenant_updated, %{hf_status: "revoked"}}
)

```

**2. Handle the State in LiveView**

When a tenant's setting dashboard or AI workbench mounts, subscribe them to their tenant's PubSub topic. If a background sweep catches a bad key, the UI updates instantly without requiring a page refresh.

```plaintext
# lib/my_app_web/live/ai_workbench_live.ex
defmodule MyAppWeb.AIWorkbenchLive do
  use MyAppWeb, :live_view

  def mount(_params, _session, socket) do
    tenant = socket.assigns.current_tenant

    if connected?(socket) do
      # Subscribe to real-time events for this tenant space
      Phoenix.PubSub.subscribe(MyApp.PubSub, "tenant_settings:#{tenant.id}")
    end

    {:ok, assign(socket, hf_status: tenant.hf_status, prompt: "")}
  end

  # Capture the broadcasted PubSub message from the background worker
  def handle_info({:tenant_updated, %{hf_status: "revoked"}}, socket) do
    {:noreply, 
     socket
     |> assign(hf_status: "revoked")
     |> put_flash(:error, "Your Hugging Face API key was flagged as invalid or expired by a background check. Please update it in settings.")}
  end

  # Render individual UI states depending on key validity
  def render(assigns) do
    ~H"""
    <div class="p-6">
      <h1 class="text-2xl font-bold mb-4">Tenant AI Workspace</h1>

      <%= if @hf_status == "revoked" do %>
        <div class="bg-red-50 border border-red-200 text-red-800 p-4 rounded-lg flex items-center justify-between mb-6">
          <div>
            <p class="font-semibold">⚠️ Hugging Face Connection Severed</p>
            <p class="text-sm">Your API key is invalid, deleted, or lacks read scopes. AI tools are disabled.</p>
          </div>
          <.link navigate={~p"/settings/integration"} class="bg-red-600 text-white px-3 py-1.5 rounded text-sm hover:bg-red-700">
            Fix Integration
          </.link>
        </div>
      <% end %>

      <div class="card bg-base-100 shadow-xl p-4">
        <textarea 
          disabled={@hf_status == "revoked"} 
          placeholder="Enter prompt..." 
          class="textarea textarea-bordered w-full disabled:opacity-50 disabled:bg-gray-100"
        ></textarea>
        
        <button 
          disabled={@hf_status == "revoked"} 
          class="btn btn-primary mt-2 disabled:btn-disabled"
        >
          Generate Output
        </button>
      </div>
    </div>
    """
  end
end

```

---

Here is how to implement multi-tenant data isolation at the database layer using Ecto, followed by how to track and aggregate token metrics for your tenants even when they use their own keys.

---

### Part 1: Ecto Multi-Tenancy Architecture

In an Elixir/Phoenix app, you have two primary options for multi-tenancy at the data layer: **Foreign Key Isolation (Shared Schema)** or **PostgreSQL Schemas (Prefix Isolation)**.

Since your tenants are bringing their own Hugging Face keys, a **Foreign Key Strategy** paired with **Ecto multi-tenant scopes** is highly recommended. It keeps your schema management simple, reduces migration complexities, and allows you to aggregate cross-tenant performance metrics effortlessly.

**1. Setup Tenant Context Scoping**

Create a base query macro or helper function inside your data contexts to automatically scope queries down by `tenant_id`:

```plaintext
defmodule MyApp.Repo.Scoped do
  import Ecto.Query

  @doc """
  Forces every database query to slice exactly by the tenant's context.
  """
  def scoped(query, %{id: tenant_id}) do
    from q in query, where: q.tenant_id == ^tenant_id
  end
end

```

**2. Querying Tenant Space Safely**

Whenever you fetch or update models, chain them through your filtering pipe so information can never cross-pollinate between tenants:

```plaintext
defmodule MyApp.AIContext do
  alias MyApp.Repo
  alias MyApp.Repo.Scoped
  alias MyApp.AI.PromptLog

  def list_logs_for_tenant(tenant) do
    PromptLog
    |> Scoped.scoped(tenant)
    |> order_by(desc: :inserted_at)
    |> Repo.all()
  end
end

```

---

### Part 2: Tracking Usage Statistics & Token Metadata

Even though tenants pay Hugging Face directly for raw compute through their keys, your system should track their usage profiles. This lets you spot failing tenant loops, calculate total throughput, and display usage telemetry graphs.

**1. The Metrics Table Schema**

Create a table to log the size, duration, and reliability of every single outbound Hugging Face request:

```plaintext
defmodule MyApp.AI.PromptLog do
  use Ecto.Schema
  import Ecto.Changeset

  schema "ai_prompt_logs" do
    field :model_id, :string
    field :input_tokens, :integer
    field :output_tokens, :integer
    field :duration_ms, :integer
    field :status, :string, default: "success" # "success", "failed"
    field :error_type, :string # nil, "401_revoked", "429_rate_limit"

    belongs_to :tenant, MyApp.Tenants.Tenant

    timestamps()
  end
end

```

**2. Intercepting Metrics in the Streaming Lifecycle**

Modify your streaming client process (`MyApp.HuggingFace.Streamer`) to keep a running count of execution metrics, then commit those values asynchronously via a transient Task or an Oban queue once the stream closes.

```plaintext
defmodule MyApp.HuggingFace.TelemetryStreamer do
  @base_url "https://huggingface.co"

  def stream_with_metrics(model_id, prompt, decrypted_key, tenant_id, target_pid) do
    start_time = System.monotonic_time(:millisecond)
    # Estimate raw input tokens (simple character space mapping or rough approximation)
    input_tokens = estimate_token_count(prompt)

    url = "#{@base_url}/#{model_id}"
    headers = [{"Authorization", "Bearer #{decrypted_key}"}, {"Content-Type", "application/json"}]
    body = Jason.encode!(%{inputs: prompt, stream: true})

    # Wrap mutable counting metadata in a local map accumulator state
    initial_acc = %{tokens_streamed: 0, status: "success", error_type: nil}

    {:ok, final_acc} = 
      Req.post(url, headers: headers, body: body, into: fn {:data, chunk}, context ->
        # Parse streaming payloads and forward them instantly to the client UI
        streamed_count = parse_and_forward_chunk(chunk, target_pid)
        
        # Update accumulator counts
        updated_acc = Map.update!(context.acc, :tokens_streamed, &(&1 + streamed_count))
        {:cont, Map.put(context, :acc, updated_acc)}
      end, acc: initial_acc)

    end_time = System.monotonic_time(:millisecond)

    # Cleanly offload writing metrics into Postgres without delaying the current socket thread
    Task.Supervisor.start_child(MyApp.HuggingFaceTaskSupervisor, fn ->
      log_metrics(%{
        tenant_id: tenant_id,
        model_id: model_id,
        input_tokens: input_tokens,
        output_tokens: final_acc.tokens_streamed,
        duration_ms: end_time - start_time,
        status: final_acc.status,
        error_type: final_acc.error_type
      })
    end)
  end

  defp estimate_token_count(text), do: Float.ceil(String.length(text) / 4) |> round()

  defp log_metrics(attrs) do
    %MyApp.AI.PromptLog{}
    |> MyApp.AI.PromptLog.changeset(attrs)
    |> MyApp.Repo.insert()
  end
end

```

---

### 3. Analyzing Tenant Usage Telemetry

Now that usage logs are mapped natively into your application database and scoped by your custom multi-tenancy helper macros, you can extract insights for individual dashboards.

For instance, this context function calculates structural usage data, counting failed requests versus active outputs inside a tenant's space:

```plaintext
defmodule MyApp.AI.Analytics do
  import Ecto.Query
  alias MyApp.Repo
  alias MyApp.Repo.Scoped
  alias MyApp.AI.PromptLog

  @doc """
  Aggregates token activity metrics for a specific tenant space over a rolling 30-day window.
  """
  def get_tenant_dashboard_stats(tenant) do
    thirty_days_ago = DateTime.utc_now() |> DateTime.add(-30, :day)

    PromptLog
    |> Scoped.scoped(tenant)
    |> where([p], p.inserted_at >= ^thirty_days_ago)
    |> select([p], %{
         total_generation_calls: count(p.id),
         total_output_tokens: sum(p.output_tokens),
         average_response_time: avg(p.duration_ms),
         failure_rate: fragment("COUNT(CASE WHEN ? = 'failed' THEN 1 END) * 100.0 / COUNT(*)", p.status)
       })
    | Repo.one()
  end
end

```

---

Here is the final piece of your integration: configuring **Finch** to handle low-level HTTP connection pooling (ensuring your system isolates network bottlenecks per tenant), followed by a **Phoenix LiveView dashboard component** to display real-time usage metrics and charts.

---

### Part 1: Resiliency Tactics with Finch Connection Pools

By default, making individual HTTP requests can cause bottlenecks if upstream APIs experience lag. **Finch** (built on top of `Mint`) allows you to define distinct connection pools.

We can configure a dedicated pool explicitly for Hugging Face. This ensures that even if Hugging Face slows down, it will never consume or exhaust the default connection pools used by the rest of your application.

**1. Add Finch to your Supervisor Tree**

Open your `lib/my_app/application.ex` file and declare a named Finch instance with custom pool limits for the Hugging Face API:

```plaintext
defmodule MyApp.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      MyApp.Repo,
      MyAppWeb.Endpoint,
      {Task.Supervisor, name: MyApp.HuggingFaceTaskSupervisor},

      # Configure Finch with a custom connection pool size for Hugging Face
      {Finch,
       name: MyApp.HFHTTPClient,
       pools: %{
         "https://huggingface.co" => [
           size: 50,              # Max 50 concurrent persistent connections
           count: 5,              # Break the pool into 5 independent shards to avoid lock contention
           max_idle_time: 15_000  # Close idle connections after 15 seconds
         ]
       }}
    ]

    opts = [strategy: :one_for_one, name: MyApp.Supervisor]
    Supervisor.start_link(children, opts)
  end
end

```

---

### 2. Instruct Req to Use Your Finch Pool

Modify your `Req` network calls inside your modules to route through this explicit resilient pool by using the `finch: MyApp.HFHTTPClient` option:

```plaintext
# Wherever you invoke Req.post or Req.get for HuggingFace:
Req.post(url,
  headers: headers,
  body: body,
  finch: MyApp.HFHTTPClient, # Forces the request onto your dedicated pool
  connect_timeout: 5_000,    # 5s max to establish connection
  receive_timeout: 30_000,   # 30s max wait for data chunks
  retry: :safe_transient     # Automatically retry on idempotent network drops
)

```

---

### Part 2: Real-Time LiveView Analytics Component

Now that your data layer isolates logs via `Tenant Contexts`, you can present this usage telemetry directly to tenants using a modern, interactive dashboard component.

**1. The LiveView Dashboard Module**

Create a LiveView panel that pulls the telemetry stats we structured in the previous step and maps them into pure HTML/CSS layouts.
