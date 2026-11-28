defmodule Samen.Web.Settings.HuggingFaceLive do
  @moduledoc """
  HuggingFace API Key Management (BYOK Integration).

  Mounted at `/settings/huggingface` by `Samen.Web.Router.samen_settings_routes/3`.

  Features:
  - Connect: Add new HuggingFace API key with validation
  - Validate: Verify key is still active against HuggingFace API
  - Revoke: Remove key from tenant account
  - Usage: View API call metrics and token consumption

  ## Security

  - Raw keys are NEVER stored in the database
  - Keys are encrypted immediately on input via AES-256-GCM
  - Decrypted only in-memory within short-lived processes
  - GC flushes decrypted key when process terminates
  """
  use Samen.Web.Tenant.Live

  import Samen.UI
  import Samen.Web.Settings.Live, only: [settings_sidebar: 1, operator_plane?: 1]
  import Samen.Web.CurrentOrg, only: [acting_as_banner: 1, no_org_card: 1, return_path: 1]

  alias Samen.Web.Crumbs
  alias Samen.Web.CurrentOrg
  alias Samen.Web.Mount
  alias Samen.Scopes.Ai.ApiKey
  alias Samen.Scopes.Ai.Crypto
  alias Samen.Scopes.Ai.PromptLog
  alias Samen.Scopes.Ai.TokenValidator

  require Ash.Query

  @impl true
  def mount(params, session, socket) do
    socket = Samen.Web.Live.assign_mount(socket, session)
    mount = socket.assigns[:samen_mount]
    org_id = CurrentOrg.resolve(mount, params, session)

    if connected?(socket) and is_binary(org_id) do
      subscribe(mount, org_id)
    end

    {:ok,
     socket
     |> assign(
       return_to: nil,
       connect_error: nil,
       connect_success: nil,
       validating: false,
       key_to_validate: nil
     )
     |> load(org_id)}
  end

  @impl true
  def handle_params(params, uri, socket) do
    mount = socket.assigns[:samen_mount]
    org_id = Samen.Web.CurrentOrg.reresolve(socket, params)

    if connected?(socket) do
      old = socket.assigns[:org_id]

      if is_binary(old) and old != org_id do
        unsubscribe(mount, old)
      end

      if is_binary(org_id) do
        subscribe(mount, org_id)
      end
    end

    {:noreply,
     socket
     |> assign(return_to: return_path(uri))
     |> load(org_id)}
  end

  @impl true
  def handle_info({:tenant_updated, %{hf_status: :revoked}}, socket) do
    {:noreply, load(socket, socket.assigns[:org_id])}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @doc false
  def load(socket, org_id) do
    socket = assign(socket, org_id: org_id, api_keys: [], usage_stats: default_usage_stats())

    if is_nil(org_id) do
      socket
    else
      api_keys = load_api_keys(org_id)
      usage_stats = calculate_usage_stats(org_id)

      socket
      |> assign(api_keys: api_keys)
      |> assign(usage_stats: usage_stats)
    end
  end

  @impl true
  def handle_event("connect", %{"api_key" => %{"raw_key" => raw_key}}, socket) do
    %{samen_mount: mount, org_id: org_id} = socket.assigns

    if operator_plane?(mount) do
      {:noreply,
       assign(socket, connect_error: "HuggingFace keys are managed on the tenant plane.")}
    else
      do_connect(socket, org_id, raw_key)
    end
  end

  def handle_event("validate_key", %{"id" => key_id}, socket) do
    %{samen_mount: mount, org_id: org_id} = socket.assigns

    if operator_plane?(mount) do
      {:noreply, socket}
    else
      do_validate_key(socket, org_id, key_id)
    end
  end

  def handle_event("revoke", %{"id" => key_id}, socket) do
    %{samen_mount: mount, org_id: org_id} = socket.assigns

    if operator_plane?(mount) do
      {:noreply, socket}
    else
      do_revoke_key(socket, org_id, key_id)
    end
  end

  def handle_event("dismiss_connect", _params, socket) do
    {:noreply, assign(socket, connect_error: nil, connect_success: nil)}
  end

  # -- render ------------------------------------------------------------------

  @impl Samen.Web.Tenant.Live
  def tenant_assigns(assigns) do
    assigns
    |> assign_new(:connect_error, fn -> nil end)
    |> assign_new(:connect_success, fn -> nil end)
    |> assign_new(:validating, fn -> false end)
  end

  @impl Samen.Web.Tenant.Live
  def tenant_sidebar(assigns) do
    ~H"""
    <.settings_sidebar mount={@samen_mount} org_id={@org_id} active={:huggingface} />
    """
  end

  @impl Samen.Web.Tenant.Live
  def tenant_page(assigns) do
    ~H"""
    <div id="settings-huggingface">
    <.topbar title="HuggingFace Integration" crumbs={[Crumbs.org(@samen_mount, @org_id), Crumbs.section(@samen_mount, @org_id, :settings), "HuggingFace"]}>
      <:actions></:actions>
    </.topbar>

    <.acting_as_banner mount={@samen_mount} org_id={@org_id} acting_as={@samen_acting_as} />

    <%= if is_nil(@org_id) do %>
      <.no_org_card mount={@samen_mount} />
    <% else %>
      <div class="wrap">
        <div id="huggingface-panel">
          <%!-- Connection Status Card --%>
          <div class="card" style="margin-bottom:16px;padding:16px">
            <h3 style="margin:0 0 12px 0;font-size:16px">🔑 HuggingFace Connection</h3>
            <p style="color:var(--muted);font-size:13px;margin:0 0 16px 0">
              Connect your HuggingFace API key to use AI features. Your key is encrypted with AES-256-GCM and never exposed to the frontend.
            </p>

            <%= if @connect_success do %>
              <div id="hf-connect-success" style="background:#DCFCE7;border:1px solid #15803D;padding:12px;border-radius:6px;margin-bottom:12px">
                <strong style="color:#15803D">✓ {@connect_success}</strong>
                <button type="button" phx-click="dismiss_connect" style="float:right;background:none;border:none;cursor:pointer;font-size:16px">×</button>
              </div>
            <% end %>

            <%= if @connect_error do %>
              <div id="hf-connect-error" style="background:#FEE2E2;border:1px solid #B91C1C;padding:12px;border-radius:6px;margin-bottom:12px">
                <strong style="color:#B91C1C">✗ {@connect_error}</strong>
                <button type="button" phx-click="dismiss_connect" style="float:right;background:none;border:none;cursor:pointer;font-size:16px">×</button>
              </div>
            <% end %>

            <%= if not operator_plane?(@samen_mount) do %>
              <form id="hf-connect-form" phx-submit="connect" style="display:flex;gap:8px;align-items:flex-end">
                <div style="flex:1">
                  <label style="display:block;font-size:12px;font-weight:600;margin-bottom:4px">HuggingFace API Key</label>
                  <input
                    type="password"
                    name="api_key[raw_key]"
                    id="hf-raw-key-input"
                    placeholder="hf_..."
                    required
                    style="width:100%;padding:8px;border:1px solid #D1D5DB;border-radius:4px;font-family:monospace"
                  />
                </div>
                <.button type="submit" variant="primary" id="hf-connect-btn">
                  Connect
                </.button>
              </form>
              <p style="color:var(--muted);font-size:11px;margin-top:8px">
                Your key is validated against HuggingFace before saving. Get your key at
                <a href="https://huggingface.co/settings/tokens" target="_blank" style="color:var(--primary)">huggingface.co/settings/tokens</a>
              </p>
            <% else %>
              <p id="hf-operator-note" style="color:var(--muted)">
                HuggingFace key management is a tenant-plane action.
              </p>
            <% end %>
          </div>

          <%!-- Usage Dashboard Card --%>
          <div class="card" style="margin-bottom:16px;padding:16px">
            <h3 style="margin:0 0 12px 0;font-size:16px">📊 Usage Dashboard</h3>
            <div style="display:grid;grid-template-columns:repeat(4,1fr);gap:12px">
              <div style="text-align:center;padding:12px;background:#F3F4F6;border-radius:6px">
                <div style="font-size:24px;font-weight:bold;color:#111827">{@usage_stats.total_calls || 0}</div>
                <div style="font-size:11px;color:var(--muted)">Total Calls</div>
              </div>
              <div style="text-align:center;padding:12px;background:#F3F4F6;border-radius:6px">
                <div style="font-size:24px;font-weight:bold;color:#111827">{format_tokens(@usage_stats.total_tokens || 0)}</div>
                <div style="font-size:11px;color:var(--muted)">Tokens Used</div>
              </div>
              <div style="text-align:center;padding:12px;background:#F3F4F6;border-radius:6px">
                <div style="font-size:24px;font-weight:bold;color:#111827">{format_duration(@usage_stats.avg_duration_ms || 0)}</div>
                <div style="font-size:11px;color:var(--muted)">Avg Response</div>
              </div>
              <div style="text-align:center;padding:12px;background:#F3F4F6;border-radius:6px">
                <div style={"font-size:24px;font-weight:bold;color:#{success_rate_color(@usage_stats)}"}>{success_rate_value(@usage_stats)}%</div>
                <div style="font-size:11px;color:var(--muted)">Success Rate</div>
              </div>
            </div>
          </div>

          <%!-- API Keys Table --%>
          <div class="card" style="padding:16px">
            <h3 style="margin:0 0 12px 0;font-size:16px">🔐 Connected Keys</h3>
            <table id="hf-keys-table" class="tbl">
              <thead>
                <tr>
                  <th scope="col">Name</th>
                  <th scope="col">Key Prefix</th>
                  <th scope="col">Status</th>
                  <th scope="col">Last Used</th>
                  <th scope="col">Errors</th>
                  <th scope="col"></th>
                </tr>
              </thead>
              <tbody>
                <tr :for={key <- @api_keys} class="hf-key-row" id={"hf-key-#{key.id}"}>
                  <td>{key.name}</td>
                  <td><code>{key.key_prefix}…</code></td>
                  <td>
                    <span class={status_class(key.status)}>
                      {status_label(key.status)}
                    </span>
                  </td>
                  <td>{format_datetime(key.last_used_at)}</td>
                  <td>
                    <%= if key.error_count > 0 do %>
                      <span style="color:#B91C1C">{key.error_count} errors</span>
                    <% else %>
                      <span style="color:#15803D">✓</span>
                    <% end %>
                  </td>
                  <td>
                    <div style="display:flex;gap:4px">
                      <button
                        :if={key.status == :active}
                        type="button"
                        phx-click="validate_key"
                        phx-value-id={key.id}
                        class="btn"
                        id={"hf-validate-#{key.id}"}
                        disabled={@validating}
                      >
                        Validate
                      </button>
                      <button
                        :if={key.status in [:active, :pending_validation]}
                        type="button"
                        phx-click="revoke"
                        phx-value-id={key.id}
                        class="btn"
                        id={"hf-revoke-#{key.id}"}
                        style="color:#B91C1C"
                      >
                        Revoke
                      </button>
                    </div>
                  </td>
                </tr>
                <tr :if={@api_keys == []}>
                  <td colspan="6" style="color:var(--muted)">No HuggingFace keys connected yet.</td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </div>
    <% end %>
    </div>
    """
  end

  # -- private -----------------------------------------------------------------

  defp do_connect(socket, org_id, raw_key) do
    cond do
      not Crypto.valid_hf_key?(raw_key) ->
        {:noreply,
         assign(socket,
           connect_error:
             "Invalid HuggingFace API key format. Keys must start with 'hf_' and be at least 10 characters.",
           connect_success: nil
         )}

      true ->
        case TokenValidator.verify_key(raw_key) do
          {:ok, _meta} ->
            iv = Crypto.generate_iv()

            case Crypto.encrypt(raw_key, iv) do
              {:ok, ciphertext} ->
                key_prefix = String.slice(raw_key, 0, min(8, byte_size(raw_key)))

                attrs = %{
                  org_id: org_id,
                  tenant_id: org_id,
                  name: "HuggingFace Key",
                  encrypted_key: ciphertext,
                  encryption_iv: iv,
                  key_prefix: key_prefix,
                  status: :active,
                  validated_at: DateTime.utc_now()
                }

                case ApiKey
                     |> Ash.Changeset.for_create(:create, attrs)
                     |> Ash.create(authorize?: false) do
                  {:ok, _row} ->
                    {:noreply,
                     socket
                     |> assign(
                       connect_success:
                         "Key #{key_prefix}… validated and encrypted successfully!",
                       connect_error: nil
                     )
                     |> load(org_id)}

                  {:error, _reason} ->
                    {:noreply,
                     assign(socket,
                       connect_error: "Failed to store the key. Please try again.",
                       connect_success: nil
                     )}
                end

              {:error, reason} ->
                {:noreply,
                 assign(socket,
                   connect_error: "Encryption failed: #{inspect(reason)}",
                   connect_success: nil
                 )}
            end

          {:error, reason} ->
            {:noreply,
             assign(socket,
               connect_error: connect_error_message(reason),
               connect_success: nil
             )}
        end
    end
  end

  defp do_validate_key(socket, org_id, key_id) do
    socket = assign(socket, validating: true)

    case fetch_key(org_id, key_id) do
      nil ->
        {:noreply,
         socket
         |> assign(validating: false, connect_error: "Key not found.")
         |> load(org_id)}

      key ->
        case decrypt_and_verify(key) do
          :ok ->
            key
            |> Ash.Changeset.for_update(:record_validation, %{})
            |> Ash.update(authorize?: false)

            {:noreply,
             socket
             |> assign(
               validating: false,
               connect_success: "Key validated successfully!",
               connect_error: nil
             )
             |> load(org_id)}

          {:error, :revoked} ->
            case revoke_key_row(key) do
              :ok ->
                broadcast_revocation(socket.assigns.samen_mount, org_id)

                {:noreply,
                 socket
                 |> assign(
                   validating: false,
                   connect_success: nil,
                   connect_error: "Key was revoked by HuggingFace."
                 )
                 |> load(org_id)}

              {:error, _reason} ->
                {:noreply,
                 socket
                 |> assign(
                   validating: false,
                   connect_success: nil,
                   connect_error:
                     "HuggingFace revoked the key, but the local key could not be cleared. Retry revoke."
                 )
                 |> load(org_id)}
            end

          {:error, reason} ->
            key
            |> Ash.Changeset.for_update(:update, %{
              error_count: (key.error_count || 0) + 1,
              last_error: to_string(reason)
            })
            |> Ash.update(authorize?: false)

            {:noreply,
             socket
             |> assign(
               validating: false,
               connect_error: "Validation failed: #{reason}",
               connect_success: nil
             )
             |> load(org_id)}
        end
    end
  end

  defp do_revoke_key(socket, org_id, key_id) do
    case fetch_key(org_id, key_id) do
      nil ->
        {:noreply, socket |> assign(connect_error: "Key not found.") |> load(org_id)}

      key ->
        case revoke_key_row(key) do
          :ok ->
            broadcast_revocation(socket.assigns.samen_mount, org_id)

            {:noreply,
             socket
             |> assign(connect_success: "Key revoked successfully.", connect_error: nil)
             |> load(org_id)}

          {:error, _reason} ->
            {:noreply,
             socket
             |> assign(
               connect_success: nil,
               connect_error: "Could not revoke the key locally. Please try again."
             )
             |> load(org_id)}
        end
    end
  end

  # -- helpers -----------------------------------------------------------------

  defp fetch_key(org_id, key_id) do
    ApiKey
    |> Ash.Query.filter(tenant_id == ^org_id and id == ^key_id)
    |> Ash.read!(authorize?: false)
    |> List.first()
  rescue
    _ -> nil
  end

  defp load_api_keys(org_id) do
    ApiKey
    |> Ash.Query.filter(tenant_id == ^org_id)
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.read!(authorize?: false)
  rescue
    _ -> []
  end

  defp calculate_usage_stats(org_id) do
    logs =
      try do
        PromptLog
        |> Ash.Query.filter(tenant_id == ^org_id)
        |> Ash.read!(authorize?: false)
      rescue
        _ -> []
      end

    total_calls = length(logs)

    total_tokens =
      Enum.reduce(logs, 0, fn l, acc -> acc + (l.input_tokens || 0) + (l.output_tokens || 0) end)

    durations = logs |> Enum.map(& &1.duration_ms) |> Enum.filter(&is_integer/1)
    avg_duration_ms = if durations == [], do: 0, else: div(Enum.sum(durations), length(durations))
    success = Enum.count(logs, fn l -> l.status == :success end)
    success_rate = if total_calls == 0, do: 100.0, else: success / total_calls * 100.0

    %{
      total_calls: total_calls,
      total_tokens: total_tokens,
      avg_duration_ms: avg_duration_ms,
      success_rate: success_rate
    }
  end

  defp default_usage_stats do
    %{total_calls: 0, total_tokens: 0, avg_duration_ms: 0, success_rate: 100.0}
  end

  defp decrypt_and_verify(key) do
    if is_binary(key.encrypted_key) and is_binary(key.encryption_iv) do
      try do
        decrypted = Crypto.decrypt(key.encrypted_key, key.encryption_iv)

        case TokenValidator.verify_key(decrypted) do
          {:ok, _meta} ->
            :ok

          {:error, reason} when reason in [:invalid_token, :insufficient_permissions] ->
            {:error, :revoked}

          {:error, reason} ->
            {:error, reason}
        end
      rescue
        _ -> {:error, :decryption_failed}
      after
        :erlang.garbage_collect()
      end
    else
      {:error, :no_key}
    end
  end

  defp revoke_key_row(key) do
    key
    |> Ash.Changeset.for_update(:update, %{
      encrypted_key: nil,
      encryption_iv: nil,
      key_prefix: nil,
      status: :revoked
    })
    |> Ash.update(authorize?: false)
    |> case do
      {:ok, _key} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp subscribe(mount, org_id) do
    maybe_pubsub(fn pubsub -> Phoenix.PubSub.subscribe(pubsub, tenant_topic(org_id)) end, mount)
  end

  defp unsubscribe(mount, org_id) do
    maybe_pubsub(fn pubsub -> Phoenix.PubSub.unsubscribe(pubsub, tenant_topic(org_id)) end, mount)
  end

  defp broadcast_revocation(mount, org_id) do
    maybe_pubsub(
      fn pubsub ->
        Phoenix.PubSub.broadcast(
          pubsub,
          tenant_topic(org_id),
          {:tenant_updated, %{hf_status: :revoked}}
        )
      end,
      mount
    )
  end

  # Realtime is optional: the settings mount may not carry a `:pubsub` label and the
  # framework cannot assume a host PubSub module exists. A missing/stopped server is
  # a no-op, never a mount crash; the durable key row is still written.
  defp maybe_pubsub(fun, mount) do
    pubsub =
      case mount do
        %Mount{} -> Mount.label(mount, :pubsub, Application.get_env(:samen_core, :pubsub))
        _ -> Application.get_env(:samen_core, :pubsub)
      end

    if pubsub do
      try do
        fun.(pubsub)
      rescue
        _ -> :ok
      end
    end

    :ok
  end

  defp tenant_topic(org_id), do: "tenant_settings:#{org_id}"

  defp connect_error_message(:invalid_token),
    do: "HuggingFace rejected the key (401). Check the token and try again."

  defp connect_error_message(:insufficient_permissions),
    do: "This token lacks the required scopes (read)."

  defp connect_error_message(:huggingface_rate_limited),
    do: "HuggingFace is rate-limiting requests. Try again shortly."

  defp connect_error_message(:timeout), do: "Timed out reaching HuggingFace. Try again."

  defp connect_error_message(:network_failure),
    do: "Could not reach HuggingFace. Check your connection."

  defp connect_error_message(reason), do: "Validation failed: #{inspect(reason)}"

  defp status_class(:active), do: "status-pill status-active"
  defp status_class(:pending_validation), do: "status-pill status-pending"
  defp status_class(:revoked), do: "status-pill status-revoked"
  defp status_class(:expired), do: "status-pill status-expired"
  defp status_class(_), do: "status-pill"

  defp status_label(:active), do: "Active"
  defp status_label(:pending_validation), do: "Pending"
  defp status_label(:revoked), do: "Revoked"
  defp status_label(:expired), do: "Expired"
  defp status_label(_), do: "Unknown"

  defp format_tokens(tokens) when tokens >= 1_000_000 do
    "#{Float.round(tokens / 1_000_000, 1)}M"
  end

  defp format_tokens(tokens) when tokens >= 1_000 do
    "#{Float.round(tokens / 1_000, 1)}K"
  end

  defp format_tokens(tokens), do: to_string(tokens)

  defp format_duration(ms) when ms >= 1000 do
    "#{Float.round(ms / 1000, 1)}s"
  end

  defp format_duration(ms), do: "#{ms}ms"

  defp format_datetime(nil), do: "Never"
  defp format_datetime(%DateTime{} = dt), do: Calendar.strftime(dt, "%b %d, %Y %H:%M")
  defp format_datetime(_), do: "Unknown"

  defp success_rate_color(%{success_rate: rate}) when rate >= 90, do: "#15803D"
  defp success_rate_color(_), do: "#B91C1C"

  defp success_rate_value(%{success_rate: rate}), do: Float.round(rate || 100.0, 1)
end
