defmodule Samen.Web.Erp.ArSettingsLive do
  @moduledoc """
  The AR collections cadence settings page (`<erp>/ar-settings`).

  One admin-owned row per org controls the automated escalation steps after a
  collection case opens: `:notice`, `:final_notice`, and `:collections`. Each
  stage can be enabled or disabled and carries its own interval in days. The
  opening `:reminder` is the case's first stage and is not configurable here.

  A missing row means the kernel defaults (14/21/30 days, every escalation
  enabled), so this page offers CREATE when the org has no row and UPDATE when
  it has one. It never deletes; disabling a stage is an auditable update.

  ## Authorization

  Reads use `Samen.Web.TenantRole.authenticated_scope/2`; every write uses
  `attributed_admin_scope/2`, so the resource's own `OrgScope` + `RoleAtLeast
  :admin` policies decide. The form is offered only on the tenant plane and
  only when that scope resolves to `:admin`. A crafted save event from a
  member is refused by the kernel too.

  No PII: a tenant id and six cadence values.
  """

  use Samen.Web.Tenant.Live

  require Ash.Query

  import Samen.UI
  import Samen.Web.Erp.Live, only: [assign_mount: 2, erp_sidebar: 1, writable?: 1]
  import Samen.Web.CurrentOrg, only: [acting_as_banner: 1, no_org_card: 1, return_path: 1]

  alias Samen.Scopes.Finance.CollectionCadence, as: CadenceSettings
  alias Samen.Web.Crumbs
  alias Samen.Web.CurrentOrg
  alias Samen.Web.Erp
  alias Samen.Web.TenantRole

  @impl true
  def mount(params, session, socket) do
    socket = assign_mount(socket, session)
    org_id = CurrentOrg.resolve(socket.assigns[:samen_mount], params, session)

    {:ok,
     socket
     |> assign(
       org_id: org_id,
       return_to: nil,
       resource: nil,
       cadence: nil,
       form: nil,
       admin?: false,
       missing: nil,
       save_error: nil,
       saved: false
     )
     |> load()}
  end

  @impl true
  def handle_params(params, uri, socket) do
    org_id = CurrentOrg.reresolve(socket, params)

    {:noreply,
     socket
     |> assign(org_id: org_id, return_to: return_path(uri), saved: false)
     |> load()}
  end

  @doc false
  def load(socket) do
    socket
    |> assign_new(:saved, fn -> false end)
    |> assign_new(:save_error, fn -> nil end)
    |> assign_new(:return_to, fn -> nil end)
    |> do_load()
  end

  defp do_load(%{assigns: %{org_id: nil}} = socket) do
    assign(socket,
      org_id: nil,
      missing: :no_org,
      resource: nil,
      cadence: nil,
      form: nil,
      admin?: false
    )
  end

  defp do_load(socket) do
    %{samen_mount: mount, org_id: org_id} = socket.assigns

    case Erp.collection_cadence(mount) do
      nil ->
        assign(socket,
          missing: :unmounted,
          resource: nil,
          cadence: nil,
          form: nil,
          admin?: false
        )

      resource ->
        case read_cadence(resource, mount, org_id) do
          {:ok, cadence} ->
            socket
            |> assign(resource: resource, cadence: cadence, missing: nil, save_error: nil)
            |> assign_form()

          {:error, _reason} ->
            assign(socket,
              resource: resource,
              cadence: nil,
              form: nil,
              admin?: false,
              missing: :unreadable
            )
        end
    end
  end

  defp read_cadence(resource, mount, org_id) do
    scope = TenantRole.authenticated_scope(mount, org_id)

    resource
    |> Ash.Query.filter(org_id == ^org_id)
    |> Ash.Query.limit(1)
    |> Ash.read_one(scope: scope)
  end

  defp assign_form(socket) do
    %{samen_mount: mount, org_id: org_id, cadence: cadence, resource: resource} = socket.assigns

    scope = TenantRole.attributed_admin_scope(mount, org_id)
    admin? = writable?(mount) and Map.get(scope.actor, :role) == :admin
    defaults = CadenceSettings.defaults()

    form =
      if admin? do
        case cadence do
          nil ->
            resource
            |> AshPhoenix.Form.for_create(:create,
              scope: scope,
              params: %{
                org_id: org_id,
                notice_enabled: defaults.notice_enabled,
                final_notice_enabled: defaults.final_notice_enabled,
                collections_enabled: defaults.collections_enabled,
                notice_days: defaults.notice_days,
                final_notice_days: defaults.final_notice_days,
                collections_days: defaults.collections_days
              }
            )
            |> to_form()

          cadence ->
            cadence
            |> AshPhoenix.Form.for_update(:update, scope: scope)
            |> to_form()
        end
      end

    assign(socket, form: form, admin?: admin?)
  end

  @impl true
  def handle_event("validate", %{"form" => params}, socket) do
    case socket.assigns.form do
      nil ->
        {:noreply, socket}

      form ->
        {:noreply,
         assign(socket,
           form: AshPhoenix.Form.validate(form, params),
           save_error: nil,
           saved: false
         )}
    end
  end

  def handle_event("save", %{"form" => params}, socket) do
    %{samen_mount: mount, org_id: org_id, cadence: cadence, form: form} = socket.assigns

    if form != nil and socket.assigns.admin? and writable?(mount) and org_id != nil do
      params = if cadence == nil, do: Map.put(params, "org_id", org_id), else: params

      case AshPhoenix.Form.submit(form, params: params) do
        {:ok, _cadence} ->
          {:noreply, socket |> assign(form: nil, cadence: nil, saved: true) |> load()}

        {:error, form} ->
          {:noreply, assign(socket, form: form, save_error: form_error(form), saved: false)}
      end
    else
      {:noreply,
       assign(socket,
         save_error: "Only an organization admin can change the collection cadence.",
         saved: false
       )}
    end
  end

  defp cadence_rows(nil), do: CadenceSettings.defaults() |> cadence_rows()

  defp cadence_rows(cadence) do
    [
      {:notice, "Notice", cadence.notice_enabled, cadence.notice_days},
      {:final_notice, "Final notice", cadence.final_notice_enabled, cadence.final_notice_days},
      {:collections, "Collections", cadence.collections_enabled, cadence.collections_days}
    ]
  end

  defp source_text(nil), do: "Defaults in effect"
  defp source_text(_cadence), do: "Custom cadence saved"

  defp source_variant(nil), do: "mut"
  defp source_variant(_cadence), do: "ok"

  defp enabled_variant(true), do: "ok"
  defp enabled_variant(false), do: "mut"

  defp form_error(form) do
    case Enum.reject(form.errors, &(&1 in [nil, ""])) do
      [] -> "Could not save the collection cadence."
      errors -> errors |> Enum.map(&error_text/1) |> Enum.uniq() |> Enum.join(" ")
    end
  rescue
    _ -> "Could not save the collection cadence."
  end

  defp error_text({msg, opts}) when is_binary(msg) do
    Enum.reduce(opts, msg, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", fn _ -> to_string(value) end)
    end)
  end

  defp error_text(msg) when is_binary(msg), do: msg
  defp error_text(other), do: to_string(other)

  defp crumbs(mount, org_id) do
    [Crumbs.org(mount, org_id), "ERP", Erp.ar_settings_label()]
  end

  @impl Samen.Web.Tenant.Live
  def tenant_sidebar(assigns) do
    ~H"""
    <.erp_sidebar
      mount={@samen_mount}
      org_id={@org_id}
      active={:erp_ar_settings}
      return_to={@return_to}
    />
    """
  end

  @impl Samen.Web.Tenant.Live
  def tenant_page(assigns) do
    ~H"""
    <div id="erp-ar-settings">
    <.topbar title={Erp.ar_settings_label()} crumbs={crumbs(@samen_mount, @org_id)} />

    <.acting_as_banner mount={@samen_mount} org_id={@org_id} acting_as={@samen_acting_as} />

    <div class="wrap">
      <%= if @missing == :no_org do %>
        <.no_org_card mount={@samen_mount} />
      <% else %>
        <%= if @missing in [:unmounted, :unreadable] do %>
          <div class="card" style="padding:16px;color:var(--muted)">
            <%= if @missing == :unreadable do %>
              The collection cadence could not be read. Try again.
            <% else %>
              AR settings need this workspace's mounted Finance cadence module.
            <% end %>
          </div>
        <% else %>
          <div class="gtitle">
            <h3>{Erp.ar_settings_label()}</h3>
            <span class="lane">· one cadence per org · admin-gated writes</span>
          </div>

          <div
            :if={@save_error}
            id="ar-settings-error"
            class="card form-error"
            style="padding:10px 14px;color:var(--bad, #b91c1c);font-size:12px;margin-bottom:10px"
          >
            {@save_error}
          </div>

          <div
            :if={@saved}
            id="ar-settings-saved"
            class="card"
            style="padding:10px 14px;color:var(--ok, #047857);font-size:12px;margin-bottom:10px"
          >
            Saved. The next daily dunning sweep uses this cadence.
          </div>

          <div
            id="ar-cadence-state"
            class="card"
            style="padding:14px 18px;margin-bottom:10px"
          >
            <div style="display:flex;gap:14px;align-items:center;flex-wrap:wrap;margin-bottom:10px">
              <.pill variant={source_variant(@cadence)}>{source_text(@cadence)}</.pill>
              <span style="font-size:12px;color:var(--muted)">
                The opening reminder is always the first stage; these control the escalation steps after it.
              </span>
            </div>

            <div
              :for={{key, label, enabled, days} <- cadence_rows(@cadence)}
              id={"cadence-#{key}"}
              style="display:flex;gap:12px;align-items:center;flex-wrap:wrap;padding:7px 0;border-top:1px solid var(--border, #f3f4f6);font-size:13px"
            >
              <.pill variant={enabled_variant(enabled)}>
                {if enabled, do: "Enabled", else: "Disabled"}
              </.pill>
              <span><b>{label}</b> — every <b>{days}</b> days</span>
            </div>
          </div>

          <div class="card" id="ar-cadence-body" style="padding:16px 18px">
            <p style="margin:0 0 14px;font-size:13px;color:var(--muted)">
              Disabled stages are skipped, not treated as a hard stop. If every remaining stage is disabled,
              due cases are skipped until you enable one. A missing row uses 14/21/30 days with every stage enabled.
            </p>

            <%= cond do %>
              <% @form != nil -> %>
                <.simple_form
                  :let={f}
                  for={@form}
                  id="ar-settings-form"
                  phx-change="validate"
                  phx-submit="save"
                >
                  <div
                    id="cadence-notice-form-row"
                    style="display:flex;gap:18px;align-items:flex-start;flex-wrap:wrap;padding:8px 0;border-bottom:1px solid var(--border, #f3f4f6)"
                  >
                    <div style="flex:1;min-width:180px">
                      <div class="field-label" style="font-size:12px;font-weight:600;margin-bottom:4px">Notice</div>
                      <input type="hidden" name={f[:notice_enabled].name} value="false" />
                      <label style="display:flex;align-items:center;gap:8px;font-size:13px">
                        <input
                          type="checkbox"
                          id={f[:notice_enabled].id}
                          name={f[:notice_enabled].name}
                          value="true"
                          checked={f[:notice_enabled].value in [true, "true", "on", "1"]}
                        />
                        <span>Enabled</span>
                      </label>
                    </div>
                    <div id="cadence-notice-days-field" style="width:190px">
                      <.form_field
                        field={f[:notice_days]}
                        label="Notice interval (days)"
                        type="number"
                        min="1"
                        max="365"
                        step="1"
                      />
                    </div>
                  </div>

                  <div
                    id="cadence-final-notice-form-row"
                    style="display:flex;gap:18px;align-items:flex-start;flex-wrap:wrap;padding:8px 0;border-bottom:1px solid var(--border, #f3f4f6)"
                  >
                    <div style="flex:1;min-width:180px">
                      <div class="field-label" style="font-size:12px;font-weight:600;margin-bottom:4px">Final notice</div>
                      <input type="hidden" name={f[:final_notice_enabled].name} value="false" />
                      <label style="display:flex;align-items:center;gap:8px;font-size:13px">
                        <input
                          type="checkbox"
                          id={f[:final_notice_enabled].id}
                          name={f[:final_notice_enabled].name}
                          value="true"
                          checked={f[:final_notice_enabled].value in [true, "true", "on", "1"]}
                        />
                        <span>Enabled</span>
                      </label>
                    </div>
                    <div id="cadence-final-notice-days-field" style="width:190px">
                      <.form_field
                        field={f[:final_notice_days]}
                        label="Final notice interval (days)"
                        type="number"
                        min="1"
                        max="365"
                        step="1"
                      />
                    </div>
                  </div>

                  <div
                    id="cadence-collections-form-row"
                    style="display:flex;gap:18px;align-items:flex-start;flex-wrap:wrap;padding:8px 0"
                  >
                    <div style="flex:1;min-width:180px">
                      <div class="field-label" style="font-size:12px;font-weight:600;margin-bottom:4px">Collections</div>
                      <input type="hidden" name={f[:collections_enabled].name} value="false" />
                      <label style="display:flex;align-items:center;gap:8px;font-size:13px">
                        <input
                          type="checkbox"
                          id={f[:collections_enabled].id}
                          name={f[:collections_enabled].name}
                          value="true"
                          checked={f[:collections_enabled].value in [true, "true", "on", "1"]}
                        />
                        <span>Enabled</span>
                      </label>
                    </div>
                    <div id="cadence-collections-days-field" style="width:190px">
                      <.form_field
                        field={f[:collections_days]}
                        label="Collections interval (days)"
                        type="number"
                        min="1"
                        max="365"
                        step="1"
                      />
                    </div>
                  </div>

                  <:actions>
                    <.button variant="primary" type="submit" id="save-ar-settings">
                      Save cadence
                    </.button>
                  </:actions>
                </.simple_form>
              <% not writable?(@samen_mount) -> %>
                <p id="ar-settings-read-only" style="margin:0;font-size:13px;color:var(--muted)">
                  Read-only on this plane.
                </p>
              <% true -> %>
                <p id="ar-settings-admin-only" style="margin:0;font-size:13px;color:var(--muted)">
                  Only an organization admin can change the collection cadence.
                </p>
            <% end %>
          </div>
        <% end %>
      <% end %>
    </div>
    </div>
    """
  end
end
