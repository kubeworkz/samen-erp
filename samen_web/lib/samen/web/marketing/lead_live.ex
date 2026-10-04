defmodule Samen.Web.Marketing.LeadLive do
  @moduledoc """
  Framework Marketing / Lead detail (`/marketing/leads/:id`) — the read-only record
  page behind the leads lens (ADR-011 §8). A lead IS a CRM `Person` (Tier-1
  `custom["lifecycle_stage"]` in `lead → mql → sql`), so this page is the lens's
  DETAIL TWIN: facts over `Samen.Web.CRM.Reads.get_contact/3` (PII plane-resolved:
  tenant clear / operator ••••) + an "Open in CRM" jump to the full CRM contact page
  where the CRUD lives.

  ## Read-only by design

  The Marketing leads lens has ALWAYS been read-only — "leads ARE CRM people; their
  CRUD lives on the CRM surfaces" — and this detail page keeps that doctrine: NO
  edit modal, NO delete interlock, NO create form. Its only affordances are
  navigation (Back to leads / Open in CRM).

  ## MASKING INVARIANT

  Names/emails/phones render whatever `PiiResolution` resolved: tenant clear,
  operator `%Masked{}` → `••••`. This LiveView NEVER calls `Samen.Vault.reveal/3`,
  NEVER unwraps a `%Masked{}`, and has NO "show plaintext" branch. The masking
  helpers are copied in posture from `Samen.Web.CRM.ContactLive`.

  ## Cross-domain read

  The mount is Marketing-kind; the person lives on the CRM domain. The page derives
  its CRM-kind mount through the SAME `Samen.Web.Marketing.Live.crm_mount/1` seam
  the lens uses (same repo + plane → identical PII resolution). No `:crm_namespace`
  label → the page is inert (honest not-found), never a crash.
  """
  use Phoenix.LiveView

  import Samen.UI

  import Samen.Web.Marketing.Live,
    only: [assign_mount: 2, marketing_sidebar: 1, marketing_path: 1, marketing_plane_note: 1, crm_mount: 1]

  import Samen.Web.CurrentOrg, only: [acting_as_banner: 1, no_org_card: 1, return_path: 1]

  alias Samen.Web.Crumbs
  alias Samen.Web.CurrentOrg
  alias Samen.Web.Mount

  alias Samen.Web.CRM.Reads

  @impl true
  def mount(params, session, socket) do
    socket = assign_mount(socket, session)
    org_id = CurrentOrg.resolve(socket.assigns[:samen_mount], params, session)
    lead_id = Map.get(params, "id")

    {:ok,
     load(
       assign(socket, org_id: org_id, lead_id: lead_id, return_to: nil),
       org_id,
       lead_id
     )}
  end

  @impl true
  def handle_params(params, uri, socket) do
    org_id = Samen.Web.CurrentOrg.reresolve(socket, params)
    lead_id = Map.get(params, "id") || socket.assigns.lead_id

    {:noreply,
     load(
       assign(socket, org_id: org_id, lead_id: lead_id, return_to: return_path(uri)),
       org_id,
       lead_id
     )}
  end

  @doc false
  def load(socket, nil, _lead_id) do
    socket
    |> ensure_return_to()
    |> assign(
      no_org: CurrentOrg.no_org?(socket.assigns[:samen_mount], nil),
      org_id: nil,
      lead_id: nil,
      lead: nil,
      company_name: nil
    )
  end

  def load(socket, org_id, lead_id) do
    mount = socket.assigns.samen_mount

    {lead, company_name} =
      case crm_mount(mount) do
        nil ->
          {nil, nil}

        crm ->
          scope = Mount.scope(crm, org_id)

          lead =
            if lead_id do
              case Reads.get_contact(crm, scope, lead_id) do
                {:ok, person} -> person
                :error -> nil
              end
            end

          name = lead && lead.company_id && company_name(crm, scope, lead.company_id)
          {lead, name}
      end

    socket
    |> ensure_return_to()
    |> assign(
      no_org: false,
      org_id: org_id,
      lead_id: lead_id,
      lead: lead,
      company_name: company_name
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="mkt-lead">
      <.app_shell>
        <:sidebar>
          <.marketing_sidebar mount={@samen_mount} org_id={@org_id} active={:marketing_leads} return_to={@return_to} />
        </:sidebar>

        <.topbar title={lead_title(@lead)} crumbs={crumbs(@samen_mount, @org_id, lead_title(@lead))}>
          <:actions>
            <a href={leads_path(@samen_mount, @org_id)} class="btn" style="text-decoration:none">
              <span class="i">
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
                  <path d="M19 12H5M12 5l-7 7 7 7" />
                </svg>
              </span>
              Back to leads
            </a>
            <a
              :if={@lead != nil}
              href={crm_contact_path(@samen_mount, @org_id, @lead_id)}
              class="btn"
              id="open-in-crm"
              style="text-decoration:none"
            >
              Open in CRM
            </a>
          </:actions>
        </.topbar>

        <.acting_as_banner mount={@samen_mount} org_id={@org_id} acting_as={@samen_acting_as} />

        <%= if @no_org do %>
          <.no_org_card mount={@samen_mount} />
        <% else %>
          <span id="org-banner" style="display:none">Marketing org: {@org_id}</span>

          <%= if @lead == nil do %>
            <div class="wrap">
              <div class="card" style="padding:22px 20px;color:var(--muted)">Lead not found.</div>
            </div>
          <% else %>
            <div class="wrap" style="margin-bottom:0">
              <div class="card" id="lead-header" style="padding:18px 20px;display:flex;align-items:center;gap:14px;flex-wrap:wrap">
                <div class="av" style="width:46px;height:46px;border-radius:8px;background:#F5F3FF;color:#7C3AED;font-size:15px;font-weight:700;display:flex;align-items:center;justify-content:center;flex-shrink:0">
                  {initials(@lead)}
                </div>
                <div style="flex:1;min-width:0">
                  <h1 style="font-weight:600;font-size:18px;color:#2a2b35;margin:0 0 4px">{lead_display_name(@lead)}</h1>
                  <div style="display:flex;gap:8px;flex-wrap:wrap;align-items:center">
                    <.lifecycle_pill stage={lifecycle_stage(@lead)} />
                    <span style="font-size:12px;color:var(--muted)">· CRM person · read-only lens · {marketing_plane_note(@samen_mount)}</span>
                  </div>
                </div>
              </div>
            </div>

            <div class="wrap" style="margin-bottom:0;padding-top:10px">
              <div class="card" id="lead-facts" style="padding:16px 18px">
                <dl style="display:grid;grid-template-columns:minmax(140px,220px) 1fr;gap:8px 16px;margin:0">
                  <div style="display:contents">
                    <dt style="font-size:12px;font-weight:600;color:var(--muted)">Name</dt>
                    <dd style="margin:0;font-size:13px">{render_full_name(@lead.full_name, @lead.display_name)}</dd>
                  </div>
                  <div style="display:contents">
                    <dt style="font-size:12px;font-weight:600;color:var(--muted)">Email</dt>
                    <dd style="margin:0;font-size:13px">{render_email(@lead.emails)}</dd>
                  </div>
                  <div style="display:contents">
                    <dt style="font-size:12px;font-weight:600;color:var(--muted)">Phone</dt>
                    <dd style="margin:0;font-size:13px">{render_phone(@lead.phones)}</dd>
                  </div>
                  <div style="display:contents">
                    <dt style="font-size:12px;font-weight:600;color:var(--muted)">Title</dt>
                    <dd style="margin:0;font-size:13px">{@lead.job_title || "—"}</dd>
                  </div>
                  <div style="display:contents">
                    <dt style="font-size:12px;font-weight:600;color:var(--muted)">Company</dt>
                    <dd style="margin:0;font-size:13px">{@company_name || "—"}</dd>
                  </div>
                  <div style="display:contents">
                    <dt style="font-size:12px;font-weight:600;color:var(--muted)">Lifecycle stage</dt>
                    <dd style="margin:0;font-size:13px">
                      <.lifecycle_pill stage={lifecycle_stage(@lead)} />
                      <span :if={lifecycle_stage(@lead) == nil} style="color:var(--muted)">—</span>
                    </dd>
                  </div>
                </dl>
              </div>

              <div class="card" id="lead-note" style="padding:14px 18px;margin-top:10px;font-size:12px;color:var(--muted)">
                Leads are CRM people — this lens is read-only by design. Edit the contact, its company, and its lifecycle stage on the CRM surface ("Open in CRM").
              </div>
            </div>
          <% end %>
        <% end %>
      </.app_shell>
    </div>
    """
  end

  # -- helpers -----------------------------------------------------------------

  defp crumbs(mount, org_id, leaf),
    do: [Crumbs.org(mount, org_id), Crumbs.section(mount, org_id, :marketing), {"Leads", leads_path(mount, org_id)}, leaf]

  defp leads_path(mount, org_id), do: "#{marketing_path(mount)}/leads?org=#{org_id}"

  defp company_name(mount, scope, company_id) do
    case Reads.get_company(mount, scope, company_id) do
      {:ok, company} -> company.name
      :error -> nil
    end
  end

  # The CRM contact page behind the "Open in CRM" jump (the CRUD surface for leads).
  defp crm_contact_path(mount, org_id, id), do: "#{Mount.label(mount, :crm_path, "/crm")}/contacts/#{id}?org=#{org_id}"

  defp lead_title(nil), do: "Lead"
  defp lead_title(lead), do: lead |> lead_display_name() |> to_title()

  # The topbar title is a plain string; a masked name collapses to a neutral label there
  # (the header H1 carries the real masked sentinel).
  defp to_title(%Samen.Masked{}), do: "Lead"
  defp to_title(str) when is_binary(str), do: str
  defp to_title(_), do: "Lead"

  defp lead_display_name(lead), do: render_full_name(lead.full_name, lead.display_name)

  defp lifecycle_stage(%{custom: custom}) when is_map(custom), do: Map.get(custom, "lifecycle_stage")
  defp lifecycle_stage(_), do: nil

  defp initials(lead) do
    lead
    |> lead_display_name()
    |> initials_of()
  end

  defp initials_of(%Samen.Masked{}), do: "··"

  defp initials_of(label) when is_binary(label) do
    label
    |> String.split(~r/\s+/, trim: true)
    |> Enum.take(2)
    |> Enum.map_join("", &String.slice(&1, 0, 1))
    |> String.upcase()
  end

  defp initials_of(_), do: "??"

  # PII renderers — copied in posture from ContactLive (render %Masked{} as-is).

  defp render_full_name(%Samen.Masked{} = masked, _display_name), do: masked

  defp render_full_name(name, _display_name) when is_binary(name) do
    case Jason.decode(name) do
      {:ok, %{"first" => first, "last" => last}} -> String.trim("#{first} #{last}")
      _ -> name
    end
  end

  defp render_full_name(nil, display_name) when is_binary(display_name), do: display_name
  defp render_full_name(nil, _display_name), do: "—"
  defp render_full_name(other, _display_name), do: other

  defp render_email(%Samen.Masked{} = masked), do: masked
  defp render_email(%Samen.Type.Emails{entries: entries}), do: render_email(entries)

  defp render_email(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, list} when is_list(list) -> render_email(list)
      _ -> "—"
    end
  end

  defp render_email(emails) when is_list(emails) do
    case List.first(emails) do
      %{"address" => addr} -> addr
      %{address: addr} -> addr
      _ -> "—"
    end
  end

  defp render_email(_), do: "—"

  defp render_phone(%Samen.Masked{} = masked), do: masked
  defp render_phone(%Samen.Type.Phones{entries: entries}), do: render_phone(entries)

  defp render_phone(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, list} when is_list(list) -> render_phone(list)
      _ -> "—"
    end
  end

  defp render_phone(phones) when is_list(phones) do
    case List.first(phones) do
      %{"number" => num} -> num
      %{number: num} -> num
      _ -> "—"
    end
  end

  defp render_phone(_), do: "—"

  defp ensure_return_to(socket) do
    if Map.has_key?(socket.assigns, :return_to),
      do: socket,
      else: assign(socket, return_to: nil)
  end
end
